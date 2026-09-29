// workspace-snapshot.js — 作業フォルダの「控え」を取り、あとから元に戻す（やられた後に戻す）。
//
// ねらい:
//   このパッケージの守りはすべて「実行前に止める」側にある。止める対象に入っていない操作
//   （作業フォルダの中のファイルの書き換え・削除）で AI が作品を壊したとき、元に戻す手段が
//   無かった。AI を起動する直前に作業フォルダの控えを自動で取り、ボタン 1 つで戻せるようにする。
//
// 設計方針:
//   - git に頼らない（Windows の受講生の PC には git が無いことがある）。Node だけで動かす。
//   - 置き場は <作業フォルダ>/.ai-safety/snapshots/。.ai-safety は安全ポリシーで AI の
//     読み書きが止まる場所なので、AI が控えを消したり書き換えたり覗いたりできない。
//   - 中身は「内容の SHA-256 を名前にした保存（content-addressed）」。同じ中身は 1 回しか
//     置かないので、控えを何回取っても増えるのは変わったファイルの分だけ。
//       objects/<先頭2文字>/<sha256>   … ファイルの中身
//       manifests/<id>.json            … その時点の一覧
//         { id, createdAt, reason, workspace, files:[{path, sha256, size, mtimeMs, mode}],
//           skipped:[{path, why}] }
//   - 前回の控えと「大きさ・更新時刻」が同じファイルは読み直さず、前回のハッシュを使う（速い道）。
//   - 利用者のファイルは絶対に消さない。元に戻すときは
//       ・控えのあとで変わった／消えたファイル → 控えの中身を書き戻す
//       ・控えのあとで新しくできたファイル     → 消さずに snapshots/set-aside/<日時>/ へ移す
//     書き戻しの直前に「元に戻す直前」の控えを自動で取るので、元に戻したこと自体も元に戻せる。
//   - 書き戻しは疑ってかかる: 一覧のパスは相対・正規化済み・".." 無し・絶対パス/ドライブ無し・
//     作業フォルダの外へ出ないこと、.ai-safety の中へは書かないこと、中身は書く前に
//     SHA-256 を照合すること、シンボリックリンクはたどらないこと。
//   - 同時に 2 つ走らないよう lock ファイルを置く（10 分以上古い lock は持ち主が死んだものとして引き継ぐ）。
//   - ここで失敗しても AI の起動は止めない（起動側が警告 1 行を出して続ける）。控えは
//     「おまけの安全網」であって、起動の条件ではない。
//
// 使い方（コマンド）:
//   node workspace-snapshot.js take    --workspace <dir> [--reason <text>] [--quiet] [--launcher]
//     --launcher: 起動スクリプト用。成功しても失敗しても日本語 1 行を標準出力へ出し、終了コードは
//                 常に 0（起動側は出力を取り込まず、結果も見ない。Windows で出力を取り込むと
//                 [Console]::OutputEncoding を触る必要があり、chcp 932 の画面で逆に化けるため）。
//   node workspace-snapshot.js list    --workspace <dir> [--json]
//   node workspace-snapshot.js diff    --workspace <dir> --id <id|番号>
//   node workspace-snapshot.js restore --workspace <dir> --id <id|番号> [--yes] [--dry-run]
//   node workspace-snapshot.js prune   --workspace <dir> [--keep N]
//   node workspace-snapshot.js wizard  --workspace <dir>   # スタートの「元に戻す」ボタン用の対話画面
//   終了コード: 0 = 成功 / 2 = 使い方の誤り・失敗
//
// 環境変数:
//   AI_SAFE_SNAPSHOT_MAX_MB       … これより大きいファイルは控えに入れない（既定 50）
//   AI_SAFE_SNAPSHOT_KEEP         … 自動の整理で残す控えの数（既定 30。--keep が優先）
//   AI_SAFE_SNAPSHOT_TIMEOUT_SEC  … take の時間の上限（既定 120 秒。起動を待たせすぎないため）
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// どの深さにあっても控えに入れない名前（小文字で比較する）。
// .ai-safety は控えの置き場そのものなので、ここを外すと自分自身を控えに入れてしまう。
const EXCLUDE_NAMES = new Set([
  '.ai-safety', '.git', 'node_modules', '.venv', 'venv', '__pycache__',
  '.next', '.nuxt', '.cache', '.turbo', '.ds_store', 'thumbs.db',
]);
// 作業フォルダ直下にだけある「パッケージが管理する場所」。インストーラーが配る安全設定と
// スタートのボタンで、更新のたびに入れ替わる。これを控えに入れると、更新のあとで古い控えに
// 戻したときに安全設定やボタンまで古い版へ巻き戻ってしまうので、控え・書き戻しの対象外にする
// （中身はインストーラー側が自分の控え ~/.ai-safety/backups に残している）。
const TOP_EXCLUDES = new Set(['.claude', '.codex', '.gemini', 'スタート']);
const PROTECTED_SEGMENT = '.ai-safety';

const DEFAULT_MAX_MB = 50;
const DEFAULT_KEEP = 30;
const DEFAULT_TIMEOUT_SEC = 120;
const LOCK_STALE_MS = 10 * 60 * 1000;
const LOCK_WAIT_MS = 30 * 1000;
const LOCK_TOUCH_MS = 5 * 1000;
const CHUNK = 1024 * 1024;
const MIN_FREE_BYTES = 1024 * 1024 * 1024; // 控えのせいで空き容量を 1 GB 未満にしない
const ID_RE = /^\d{8}-\d{6}-\d{3}-[0-9a-f]{4}$/;
const SHA_RE = /^[0-9a-f]{64}$/;
const IS_WIN = process.platform === 'win32';
const WIN_RESERVED_RE = /^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$/i;

// 利用者に見せる失敗。メッセージは日本語 1 行にする（起動側がそのまま警告に使う）。
class SnapshotError extends Error {
  constructor(message, code) {
    super(message);
    this.name = 'SnapshotError';
    this.code = code || 'snapshot';
  }
}

// ---- 小さな道具 --------------------------------------------------------------

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function randHex(bytes) {
  return crypto.randomBytes(bytes).toString('hex');
}

function pad(n, w) {
  return String(n).padStart(w, '0');
}

// 3 桁ごとのカンマ（Intl に頼らない。先読みの正規表現も使わない）。
function fmtNum(n) {
  const s = String(n);
  let out = '';
  for (let i = 0; i < s.length; i += 1) {
    if (i > 0 && (s.length - i) % 3 === 0) out += ',';
    out += s[i];
  }
  return out;
}

function fmtLocalTime(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '(日時不明)';
  return `${d.getFullYear()}/${pad(d.getMonth() + 1, 2)}/${pad(d.getDate(), 2)} `
    + `${pad(d.getHours(), 2)}:${pad(d.getMinutes(), 2)}`;
}

function fmtBytes(n) {
  if (n >= 1024 * 1024 * 1024) return (n / (1024 * 1024 * 1024)).toFixed(1) + ' GB';
  if (n >= 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + ' MB';
  if (n >= 1024) return (n / 1024).toFixed(1) + ' KB';
  return n + ' B';
}

// 控えの id。UTC の日時なので文字列の並び順＝時間の順になる。末尾は同じミリ秒の衝突よけ。
function newId(now) {
  const d = now || new Date();
  return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1, 2)}${pad(d.getUTCDate(), 2)}-`
    + `${pad(d.getUTCHours(), 2)}${pad(d.getUTCMinutes(), 2)}${pad(d.getUTCSeconds(), 2)}-`
    + `${pad(d.getUTCMilliseconds(), 3)}-${randHex(2)}`;
}

// id の日時部分を読み戻す（同じミリ秒に 2 つ取ったとき、新しいほうを必ず後ろに並べるため）。
function idTimeMs(id) {
  const m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-(\d{3})-/.exec(String(id));
  if (!m) return NaN;
  return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]), Number(m[7]));
}

// いちばん新しい控えより必ず後ろに並ぶ id を作る（末尾の乱数で順番が入れ替わらないように）。
function nextId(ctx) {
  const newest = listIds(ctx)[0];
  const id = newId();
  if (!newest || id.slice(0, 19) > newest.slice(0, 19)) return id;
  const t = idTimeMs(newest);
  return Number.isNaN(t) ? id : newId(new Date(t + 1));
}

function localStamp(d) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1, 2)}-${pad(d.getDate(), 2)}_`
    + `${pad(d.getHours(), 2)}-${pad(d.getMinutes(), 2)}-${pad(d.getSeconds(), 2)}`;
}

function lstatOrNull(p) {
  try { return fs.lstatSync(p); } catch (e) {
    if (e && (e.code === 'ENOENT' || e.code === 'ENOTDIR')) return null;
    throw e;
  }
}

function isInside(child, parent) {
  const rel = path.relative(parent, child);
  return rel === '' || (!!rel && !rel.startsWith('..') && !path.isAbsolute(rel));
}

function sanitizeReason(reason) {
  const s = String(reason == null ? '' : reason).replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
  return (s || 'manual').slice(0, 80);
}

function envNumber(name, fallback, { min, integer } = {}) {
  const raw = process.env[name];
  if (raw == null || String(raw).trim() === '') return fallback;
  const n = Number(raw);
  if (!Number.isFinite(n)) return fallback;
  if (integer && !Number.isInteger(n)) return fallback;
  if (min != null && n < min) return fallback;
  return n;
}

const AGENT_LABELS = {
  codex: 'Codex',
  claude: 'Claude Code',
  'claude-assisted': 'Claude（AI補助）',
  opencode: 'OpenCode',
  'd-claude': 'DeepSeek-Claude',
  agy: 'AntiGravity',
};

function reasonLabel(reason) {
  const r = String(reason || '');
  if (r === 'before-restore') return '元に戻す直前';
  if (r === 'before-longrun') return '長時間おまかせの起動前';
  let m = /^before-longrun-(.+)$/.exec(r);
  if (m) return `長時間おまかせ（${AGENT_LABELS[m[1]] || m[1]}）の起動前`;
  m = /^before-(.+)$/.exec(r);
  if (m) return `${AGENT_LABELS[m[1]] || m[1]} の起動前`;
  if (!r || r === 'manual') return '手動で取った控え';
  return r;
}

const SKIP_LABELS = {
  'too-large': '大きすぎるため',
  symlink: 'リンクのため',
  'not-a-file': '普通のファイルではないため',
  unreadable: '読み取れなかったため',
  'unreadable-folder': 'フォルダを開けなかったため',
  'unsupported-name': '名前に使えない文字があるため',
};

// ---- 置き場と対象の決まり -------------------------------------------------------

// 作業フォルダを実体のパスに解決する。PC 全体やホーム丸ごとの控えは取らない（巨大になり、
// 起動が止まったように見えるため）。
function resolveWorkspace(dir) {
  if (!dir || typeof dir !== 'string') throw new SnapshotError('作業フォルダが指定されていません（--workspace）。', 'usage');
  const abs = path.resolve(dir);
  let st;
  try { st = fs.statSync(abs); } catch {
    throw new SnapshotError(`作業フォルダが見つかりません: ${abs}`, 'usage');
  }
  if (!st.isDirectory()) throw new SnapshotError(`作業フォルダではありません: ${abs}`, 'usage');
  const real = fs.realpathSync.native(abs);
  if (path.parse(real).root === real) {
    throw new SnapshotError(`ドライブ全体の控えは取れません: ${real}`, 'usage');
  }
  let home = '';
  try { home = fs.realpathSync.native(os.homedir()); } catch { home = ''; }
  if (home && path.relative(real, home) === '') {
    throw new SnapshotError(`ホームフォルダ全体の控えは取れません: ${real}`, 'usage');
  }
  return real;
}

function storePaths(ws) {
  const aiSafety = path.join(ws, '.ai-safety');
  const root = path.join(aiSafety, 'snapshots');
  return {
    aiSafety,
    root,
    objects: path.join(root, 'objects'),
    manifests: path.join(root, 'manifests'),
    setAside: path.join(root, 'set-aside'),
    tmp: path.join(root, 'tmp'),
    lock: path.join(root, 'lock'),
  };
}

// 置き場の途中がリンクだったら使わない（作業フォルダの外へ控えを書き出さないため）。
function ensureStore(sp) {
  for (const dir of [sp.aiSafety, sp.root]) {
    const st = lstatOrNull(dir);
    if (st && !st.isDirectory()) {
      throw new SnapshotError(`控えの置き場が普通のフォルダではないため中止しました: ${dir}`);
    }
  }
  for (const dir of [sp.aiSafety, sp.root, sp.objects, sp.manifests, sp.tmp]) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const st = fs.lstatSync(dir);
    if (!st.isDirectory()) throw new SnapshotError(`控えの置き場が普通のフォルダではないため中止しました: ${dir}`);
  }
  if (!IS_WIN) {
    try { fs.chmodSync(sp.root, 0o700); } catch { /* 所有者でない等。控え自体は取れる */ }
  }
}

function readPackageDocs(ws) {
  const out = new Set();
  let text = '';
  try { text = fs.readFileSync(path.join(ws, '.ai-safety', 'docs-manifest.txt'), 'utf8'); } catch { return out; }
  for (const line of text.split(/\r?\n/)) {
    const rel = line.trim().replace(/\\/g, '/');
    if (!rel) continue;
    out.add(('docs/' + rel).normalize('NFC').toLowerCase());
  }
  return out;
}

// 1 回の操作ぶんの文脈（作業フォルダ・置き場・除外の決まり・大文字小文字の扱い）。
function openContext(workspaceArg) {
  const ws = resolveWorkspace(workspaceArg);
  const sp = storePaths(ws);
  ensureStore(sp);
  // この作業フォルダのファイルシステムが大文字小文字を区別するかを実測する
  // （mac の APFS / Windows の NTFS は通常区別しない。区別しないのに区別して比べると、
  //  名前の大文字小文字だけ変わったファイルを「新しいファイル」と誤認して片付けてしまう）。
  const caseInsensitive = fs.existsSync(path.join(ws, '.AI-SAFETY', 'SNAPSHOTS'));
  let aiSafetyReal = sp.aiSafety;
  try { aiSafetyReal = fs.realpathSync.native(sp.aiSafety); } catch { /* 直前に作ったので通常は解決できる */ }
  const packageDocs = readPackageDocs(ws);
  const keyOf = (rel) => {
    const n = String(rel).normalize('NFC');
    return caseInsensitive ? n.toLowerCase() : n;
  };
  const isExcludedRel = (rel) => {
    const segs = String(rel).split('/');
    for (let i = 0; i < segs.length; i += 1) {
      const low = segs[i].normalize('NFC').toLowerCase();
      if (EXCLUDE_NAMES.has(low)) return true;
      if (i === 0 && TOP_EXCLUDES.has(low)) return true;
    }
    return packageDocs.has(String(rel).normalize('NFC').toLowerCase());
  };
  return { ws, sp, caseInsensitive, aiSafetyReal, keyOf, isExcludedRel };
}

// 控えの一覧に書かれたパスが「作業フォルダの中の、普通の相対パス」かどうか。
// 一覧は AI が触れない場所にあるが、壊れていたり書き換えられていたりしても
// 作業フォルダの外や .ai-safety の中へ書き出さないよう、ここで必ず弾く。
function isSafeRelPath(p) {
  if (typeof p !== 'string' || p.length === 0 || p.length > 4096) return false;
  if (p.includes('\0') || p.includes('\\')) return false;
  if (p.startsWith('/') || /^[A-Za-z]:/.test(p)) return false;
  if (IS_WIN && p.includes(':')) return false;
  if (path.posix.normalize(p) !== p) return false;
  const segs = p.split('/');
  for (const seg of segs) {
    if (seg === '' || seg === '.' || seg === '..') return false;
    if (seg.normalize('NFC').toLowerCase() === PROTECTED_SEGMENT) return false;
    if (IS_WIN) {
      // Windows は名前の末尾の "." と空白を黙って落とす（".ai-safety." が .ai-safety になる）。
      if (/[. ]$/.test(seg)) return false;
      if (WIN_RESERVED_RE.test(seg)) return false;
      if (/[<>"|?*\u0000-\u001f]/.test(seg)) return false;
    }
  }
  return true;
}

// ---- 走査 ----------------------------------------------------------------------

// 作業フォルダを走査する。リンクはたどらない（記録だけする）。除外の名前は中へ入らない。
function scanTree(ctx, { onFile, onSkip, onTick }) {
  const stack = [''];
  while (stack.length) {
    const relDir = stack.pop();
    const absDir = relDir ? path.join(ctx.ws, ...relDir.split('/')) : ctx.ws;
    let names;
    try {
      names = fs.readdirSync(absDir);
    } catch (e) {
      if (!relDir) throw new SnapshotError(`作業フォルダを読み取れません: ${ctx.ws}`);
      onSkip(relDir, 'unreadable-folder');
      continue;
    }
    names.sort();
    const subdirs = [];
    for (const name of names) {
      if (onTick) onTick();
      const rel = relDir ? `${relDir}/${name}` : name;
      if (ctx.isExcludedRel(rel)) continue;
      if (name.includes('\\') || (IS_WIN && name.includes(':')) || !isSafeRelPath(rel)) {
        onSkip(rel, 'unsupported-name');
        continue;
      }
      const abs = path.join(absDir, name);
      let st;
      try { st = fs.lstatSync(abs); } catch {
        onSkip(rel, 'unreadable');
        continue;
      }
      if (st.isSymbolicLink()) { onSkip(rel, 'symlink'); continue; }
      if (st.isDirectory()) { subdirs.push(rel); continue; }
      if (st.isFile()) { onFile(rel, abs, st); continue; }
      onSkip(rel, 'not-a-file');
    }
    // 名前順に処理されるよう、逆順に積む。
    for (let i = subdirs.length - 1; i >= 0; i -= 1) stack.push(subdirs[i]);
  }
}

// ---- 中身の読み書き（大きなファイルでもメモリに載せない） ---------------------------

function hashFile(abs) {
  const h = crypto.createHash('sha256');
  const buf = Buffer.allocUnsafe(CHUNK);
  const fd = fs.openSync(abs, 'r');
  try {
    for (;;) {
      const n = fs.readSync(fd, buf, 0, CHUNK, null);
      if (n <= 0) break;
      h.update(buf.subarray(0, n));
    }
  } finally {
    fs.closeSync(fd);
  }
  return h.digest('hex');
}

// src を dest へ写しながらハッシュを取る。dest は新規作成（既にあれば失敗）。
function copyWithHash(src, dest) {
  const h = crypto.createHash('sha256');
  const buf = Buffer.allocUnsafe(CHUNK);
  let bytes = 0;
  const fdIn = fs.openSync(src, 'r');
  let fdOut = null;
  try {
    fdOut = fs.openSync(dest, 'wx', 0o600);
    for (;;) {
      const n = fs.readSync(fdIn, buf, 0, CHUNK, null);
      if (n <= 0) break;
      h.update(buf.subarray(0, n));
      let off = 0;
      while (off < n) off += fs.writeSync(fdOut, buf, off, n - off);
      bytes += n;
    }
  } finally {
    fs.closeSync(fdIn);
    if (fdOut != null) fs.closeSync(fdOut);
  }
  return { sha256: h.digest('hex'), size: bytes };
}

function objectPath(ctx, sha) {
  return path.join(ctx.sp.objects, sha.slice(0, 2), sha);
}

function objectExists(ctx, sha) {
  if (!SHA_RE.test(String(sha || ''))) return false;
  const st = lstatOrNull(objectPath(ctx, sha));
  return !!st && st.isFile();
}

// ファイルを控えに入れ、実際に写した中身のハッシュを返す。先に読んでハッシュを取り、
// 同じ中身が既にあれば写さない（2 回目以降の控えが速い）。読んでいる最中に書き換わった
// 場合も、置き場のファイル名＝写した中身のハッシュ、が必ず一致するように写した側を正とする。
function storeFile(ctx, abs) {
  const first = hashFile(abs);
  if (objectExists(ctx, first)) {
    return { sha256: first, size: fs.statSync(abs).size };
  }
  const tmp = path.join(ctx.sp.tmp, `obj-${process.pid}-${randHex(6)}`);
  let copied;
  try {
    copied = copyWithHash(abs, tmp);
    const dest = objectPath(ctx, copied.sha256);
    fs.mkdirSync(path.dirname(dest), { recursive: true, mode: 0o700 });
    if (objectExists(ctx, copied.sha256)) {
      fs.unlinkSync(tmp);
    } else {
      fs.renameSync(tmp, dest);
    }
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch { /* 無ければよい */ }
    throw e;
  }
  return copied;
}

// 控えの中身が名前（SHA-256）どおりかを確かめる。壊れていたら書き戻しに使わない。
function verifyObject(ctx, sha) {
  if (!objectExists(ctx, sha)) return false;
  try { return hashFile(objectPath(ctx, sha)) === sha; } catch { return false; }
}

// ---- lock ------------------------------------------------------------------------

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return true;
  if (pid === process.pid) return true;
  try { process.kill(pid, 0); return true; } catch (e) { return !(e && e.code === 'ESRCH'); }
}

function acquireLock(ctx, waitMs) {
  const lockPath = ctx.sp.lock;
  const token = `${process.pid}-${Date.now()}-${randHex(4)}`;
  const deadline = Date.now() + (waitMs == null ? LOCK_WAIT_MS : waitMs);
  for (;;) {
    try {
      const fd = fs.openSync(lockPath, 'wx', 0o600);
      try {
        fs.writeSync(fd, JSON.stringify({ pid: process.pid, token, at: new Date().toISOString() }));
      } finally {
        fs.closeSync(fd);
      }
      break;
    } catch (e) {
      if (!e || e.code !== 'EEXIST') throw e;
      const st = lstatOrNull(lockPath);
      if (!st) continue;
      let holder = null;
      try { holder = JSON.parse(fs.readFileSync(lockPath, 'utf8')); } catch { holder = null; }
      const stale = (Date.now() - st.mtimeMs > LOCK_STALE_MS)
        || (holder && Number.isInteger(holder.pid) && !pidAlive(holder.pid));
      if (stale) {
        // 見てから消すまでの間に別の誰かが取り直していないか、もう一度だけ確かめる。
        const again = lstatOrNull(lockPath);
        if (again && again.ino === st.ino && again.mtimeMs === st.mtimeMs) {
          try { fs.unlinkSync(lockPath); } catch { /* 先を越された */ }
        }
        continue;
      }
      if (Date.now() >= deadline) {
        throw new SnapshotError('ほかの画面で控えの作業をしている最中です。少し待ってからやり直してください', 'locked');
      }
      sleepMs(200);
    }
  }
  let lastTouch = Date.now();
  return {
    touch() {
      const now = Date.now();
      if (now - lastTouch < LOCK_TOUCH_MS) return;
      lastTouch = now;
      try { fs.utimesSync(lockPath, new Date(now), new Date(now)); } catch { /* 次で取り返す */ }
    },
    release() {
      try {
        const held = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
        if (held && held.token === token) fs.unlinkSync(lockPath);
      } catch { /* 既に無い */ }
    },
  };
}

// ---- 控えの一覧 -------------------------------------------------------------------

function listIds(ctx) {
  let names = [];
  try { names = fs.readdirSync(ctx.sp.manifests); } catch { return []; }
  return names
    .filter((n) => n.endsWith('.json') && ID_RE.test(n.slice(0, -5)))
    .map((n) => n.slice(0, -5))
    .sort()
    .reverse();
}

function manifestPath(ctx, id) {
  return path.join(ctx.sp.manifests, `${id}.json`);
}

function readManifestRaw(ctx, id) {
  if (!ID_RE.test(String(id))) throw new SnapshotError(`控えの番号が正しくありません: ${id}`, 'usage');
  let data;
  try {
    data = JSON.parse(fs.readFileSync(manifestPath(ctx, id), 'utf8'));
  } catch {
    throw new SnapshotError(`控えの記録を読めませんでした（壊れているようです）: ${id}`);
  }
  if (!data || typeof data !== 'object' || data.id !== id || !Array.isArray(data.files)) {
    throw new SnapshotError(`控えの記録が壊れています: ${id}`);
  }
  if (!Array.isArray(data.skipped)) data.skipped = [];
  return data;
}

// 書き戻しに使う前の厳密な検査。1 件でもおかしければ、その控えは丸ごと使わない。
function loadManifestStrict(ctx, id) {
  const m = readManifestRaw(ctx, id);
  const seen = new Set();
  for (const f of m.files) {
    if (!f || typeof f !== 'object' || !isSafeRelPath(f.path)) {
      throw new SnapshotError(`控えの記録に危ないパスが含まれているため、使わずに中止しました: ${f && f.path}`, 'tampered');
    }
    if (!SHA_RE.test(String(f.sha256)) || !Number.isFinite(f.size) || f.size < 0) {
      throw new SnapshotError(`控えの記録が壊れているため、使わずに中止しました: ${f.path}`, 'tampered');
    }
    const k = ctx.keyOf(f.path);
    if (seen.has(k)) throw new SnapshotError(`控えの記録に同じパスが 2 回あります: ${f.path}`, 'tampered');
    seen.add(k);
  }
  // 「a」がファイルで「a/b」もある、のような矛盾した一覧も弾く。
  for (const f of m.files) {
    const segs = f.path.split('/');
    for (let i = 1; i < segs.length; i += 1) {
      if (seen.has(ctx.keyOf(segs.slice(0, i).join('/')))) {
        throw new SnapshotError(`控えの記録が矛盾しています: ${f.path}`, 'tampered');
      }
    }
  }
  return m;
}

function summarizeManifest(ctx, id, number) {
  let m = null;
  try { m = readManifestRaw(ctx, id); } catch { m = null; }
  return {
    number,
    id,
    createdAt: m ? m.createdAt : null,
    reason: m ? m.reason : '(読めない控え)',
    reasonLabel: m ? reasonLabel(m.reason) : '(読めない控え)',
    files: m ? m.files.length : 0,
    skipped: m ? m.skipped.length : 0,
    broken: !m,
  };
}

function list(workspaceArg) {
  const ctx = openContext(workspaceArg);
  return listIds(ctx).map((id, i) => summarizeManifest(ctx, id, i + 1));
}

// "3" のような番号（1 = いちばん新しい）か、控えの id そのものを受け付ける。
function resolveId(ctx, idArg) {
  const s = String(idArg == null ? '' : idArg).trim();
  if (!s) throw new SnapshotError('どの控えかを指定してください（--id）。', 'usage');
  const ids = listIds(ctx);
  if (/^[0-9]{1,6}$/.test(s)) {
    const n = Number(s);
    if (n < 1 || n > ids.length) {
      throw new SnapshotError(ids.length === 0
        ? 'まだ控えがありません。'
        : `その番号の控えはありません（1〜${ids.length} から選んでください）。`, 'usage');
    }
    return ids[n - 1];
  }
  if (ID_RE.test(s) && ids.includes(s)) return s;
  throw new SnapshotError(`その控えは見つかりません: ${s}`, 'usage');
}

// ---- 控えを取る -------------------------------------------------------------------

function sameContent(prev, files, skipped) {
  if (!prev || prev.files.length !== files.length || prev.skipped.length !== skipped.length) return false;
  const map = new Map(prev.files.map((f) => [f.path, f]));
  for (const f of files) {
    const p = map.get(f.path);
    if (!p || p.sha256 !== f.sha256 || p.mode !== f.mode) return false;
  }
  const sk = new Set(prev.skipped.map((s) => `${s.path}\0${s.why}`));
  for (const s of skipped) if (!sk.has(`${s.path}\0${s.why}`)) return false;
  return true;
}

function newestManifest(ctx) {
  for (const id of listIds(ctx)) {
    try { return readManifestRaw(ctx, id); } catch { /* 壊れた控えは速い道に使わない */ }
  }
  return null;
}

function freeBytes(dir) {
  if (typeof fs.statfsSync !== 'function') return null;
  try {
    const s = fs.statfsSync(dir);
    return Number(s.bavail) * Number(s.bsize);
  } catch { return null; }
}

// lock を持った状態で控えを取る。restore の中からも呼ぶ。
//   opts.reason / opts.noFastPath（全ファイルを読み直す）/ opts.deadlineMs / opts.progress
function takeLocked(ctx, lock, opts = {}) {
  const t0 = Date.now();
  const maxBytes = envNumber('AI_SAFE_SNAPSHOT_MAX_MB', DEFAULT_MAX_MB, { min: 0.001 }) * 1024 * 1024;
  const prev = newestManifest(ctx);
  const prevMap = new Map(prev ? prev.files.map((f) => [f.path, f]) : []);
  const candidates = [];
  const skipped = [];
  const progress = opts.progress || (() => {});

  scanTree(ctx, {
    onFile(rel, abs, st) {
      if (st.size > maxBytes) { skipped.push({ path: rel, why: 'too-large', size: st.size }); return; }
      candidates.push({ rel, abs, size: st.size, mtimeMs: st.mtimeMs, mode: st.mode & 0o777 });
    },
    onSkip(rel, why) { skipped.push({ path: rel, why }); },
    onTick() { lock.touch(); },
  });

  const fastOk = (c) => {
    if (opts.noFastPath) return null;
    const p = prevMap.get(c.rel);
    if (p && p.size === c.size && p.mtimeMs === c.mtimeMs && objectExists(ctx, p.sha256)) return p;
    return null;
  };

  // 空き容量の確認（新しく写す可能性のある分の上限で見積もる）。
  let need = 0;
  for (const c of candidates) if (!fastOk(c)) need += c.size;
  const free = freeBytes(ctx.sp.root);
  if (free != null && free - need < MIN_FREE_BYTES) {
    throw new SnapshotError(`空き容量が足りないため控えを取りませんでした（必要 ${fmtBytes(need)}・空き ${fmtBytes(free)}）`, 'nospace');
  }

  const files = [];
  let done = 0;
  for (const c of candidates) {
    if (opts.deadlineMs && Date.now() > opts.deadlineMs) {
      throw new SnapshotError('作業フォルダが大きく時間がかかりすぎたため、今回の控えは途中でやめました（次回の起動で続きから進めます）', 'timeout');
    }
    lock.touch();
    done += 1;
    progress(done, candidates.length);
    const p = fastOk(c);
    if (p) {
      files.push({ path: c.rel, sha256: p.sha256, size: c.size, mtimeMs: c.mtimeMs, mode: c.mode });
      continue;
    }
    let stored;
    try { stored = storeFile(ctx, c.abs); } catch {
      skipped.push({ path: c.rel, why: 'unreadable' });
      continue;
    }
    files.push({ path: c.rel, sha256: stored.sha256, size: stored.size, mtimeMs: c.mtimeMs, mode: c.mode });
  }

  const seconds = (Date.now() - t0) / 1000;
  if (prev && sameContent(prev, files, skipped)) {
    // 前回と中身が同じなら新しい控えは作らない（同じ控えが並んで古い控えが押し出されるのを防ぐ）。
    return { id: prev.id, reused: true, manifest: prev, fileCount: files.length, skippedCount: skipped.length, seconds };
  }
  const manifest = {
    version: 1,
    id: nextId(ctx),
    createdAt: new Date().toISOString(),
    reason: sanitizeReason(opts.reason),
    workspace: ctx.ws,
    files,
    skipped,
  };
  if (opts.restoreTarget) manifest.restoreTarget = opts.restoreTarget;
  const tmp = path.join(ctx.sp.tmp, `manifest-${process.pid}-${randHex(6)}.json`);
  fs.writeFileSync(tmp, JSON.stringify(manifest), { mode: 0o600 });
  fs.renameSync(tmp, manifestPath(ctx, manifest.id));
  return { id: manifest.id, reused: false, manifest, fileCount: files.length, skippedCount: skipped.length, seconds };
}

function take(workspaceArg, opts = {}) {
  const ctx = openContext(workspaceArg);
  const lock = acquireLock(ctx, opts.lockWaitMs);
  try {
    const timeoutSec = opts.timeoutSec != null
      ? opts.timeoutSec
      : envNumber('AI_SAFE_SNAPSHOT_TIMEOUT_SEC', DEFAULT_TIMEOUT_SEC, { min: 1 });
    const result = takeLocked(ctx, lock, {
      reason: opts.reason,
      deadlineMs: timeoutSec > 0 ? Date.now() + timeoutSec * 1000 : 0,
      progress: opts.progress,
    });
    if (opts.prune !== false) {
      const keep = opts.keep != null ? opts.keep : envNumber('AI_SAFE_SNAPSHOT_KEEP', DEFAULT_KEEP, { min: 1, integer: true });
      try { result.pruned = pruneLocked(ctx, lock, keep); } catch { result.pruned = null; }
    }
    return result;
  } finally {
    lock.release();
  }
}

// ---- 整理（古い控えの削除と、どこからも使われなくなった中身の片付け） -----------------

function pruneLocked(ctx, lock, keep) {
  if (!Number.isInteger(keep) || keep < 1) throw new SnapshotError('--keep には 1 以上の整数を指定してください。', 'usage');
  const ids = listIds(ctx);
  const removeIds = ids.slice(keep);
  let removedManifests = 0;
  for (const id of removeIds) {
    try { fs.unlinkSync(manifestPath(ctx, id)); removedManifests += 1; } catch { /* 次回 */ }
  }
  // 残す控えが 1 つでも読めないときは、中身の片付けをしない（必要な中身を消さないため）。
  const refs = new Set();
  for (const id of ids.slice(0, keep)) {
    let m;
    try { m = readManifestRaw(ctx, id); } catch {
      return { removedManifests, removedObjects: 0, gcSkipped: true };
    }
    for (const f of m.files) if (SHA_RE.test(String(f.sha256))) refs.add(f.sha256);
  }
  let removedObjects = 0;
  let prefixes = [];
  try { prefixes = fs.readdirSync(ctx.sp.objects); } catch { prefixes = []; }
  for (const pre of prefixes) {
    if (!/^[0-9a-f]{2}$/.test(pre)) continue;
    const dir = path.join(ctx.sp.objects, pre);
    let names = [];
    try { names = fs.readdirSync(dir); } catch { continue; }
    for (const name of names) {
      lock.touch();
      if (!SHA_RE.test(name)) continue; // 知らない名前には触らない
      if (refs.has(name)) continue;
      try { fs.unlinkSync(path.join(dir, name)); removedObjects += 1; } catch { /* 次回 */ }
    }
    try { fs.rmdirSync(dir); } catch { /* 空でなければ残る */ }
  }
  // 途中で止まった書き出しの残り（1 時間より古いもの）を片付ける。
  let tmpNames = [];
  try { tmpNames = fs.readdirSync(ctx.sp.tmp); } catch { tmpNames = []; }
  for (const name of tmpNames) {
    if (!/^(obj|manifest)-/.test(name)) continue;
    const p = path.join(ctx.sp.tmp, name);
    const st = lstatOrNull(p);
    if (st && st.isFile() && Date.now() - st.mtimeMs > 60 * 60 * 1000) {
      try { fs.unlinkSync(p); } catch { /* 次回 */ }
    }
  }
  return { removedManifests, removedObjects, gcSkipped: false };
}

function prune(workspaceArg, opts = {}) {
  const ctx = openContext(workspaceArg);
  const lock = acquireLock(ctx, opts.lockWaitMs);
  try {
    const keep = opts.keep != null ? opts.keep : envNumber('AI_SAFE_SNAPSHOT_KEEP', DEFAULT_KEEP, { min: 1, integer: true });
    return pruneLocked(ctx, lock, keep);
  } finally {
    lock.release();
  }
}

// ---- 差分（元に戻すと何が起きるか） -------------------------------------------------

// rel の各段を lstat でたどり、いまそこに何があるかを調べる（途中のリンクはたどらない）。
function inspectPath(ctx, rel) {
  const segs = rel.split('/');
  let cur = ctx.ws;
  for (let i = 0; i < segs.length; i += 1) {
    cur = path.join(cur, segs[i]);
    const st = lstatOrNull(cur);
    if (!st) return 'missing';
    const last = i === segs.length - 1;
    if (st.isSymbolicLink()) return last ? 'link' : 'blocked-by-link';
    if (!last) {
      if (st.isDirectory()) continue;
      return st.isFile() ? 'blocked-by-file' : 'other';
    }
    if (st.isFile()) return 'file';
    if (st.isDirectory()) return 'dir';
    return 'other';
  }
  return 'missing';
}

function planRestore(ctx, manifest) {
  const snapFiles = manifest.files.filter((f) => !ctx.isExcludedRel(f.path));
  const snapKeys = new Map(snapFiles.map((f) => [ctx.keyOf(f.path), f]));
  const snapSkipped = new Map();
  for (const s of manifest.skipped) {
    if (s && typeof s.path === 'string') snapSkipped.set(ctx.keyOf(s.path), s);
  }
  const current = new Map();
  scanTree(ctx, {
    onFile(rel, abs, st) { current.set(ctx.keyOf(rel), { rel, abs, st }); },
    onSkip() { /* いまあるリンク等は触らない（書き戻しの邪魔になるときだけ片付ける） */ },
  });

  const restore = [];
  const notCovered = [];
  let unchanged = 0;
  for (const f of snapFiles) {
    const cur = current.get(ctx.keyOf(f.path));
    if (!cur) {
      const state = inspectPath(ctx, f.path);
      const kind = (state === 'missing' || state === 'blocked-by-file') ? 'deleted' : 'changed';
      restore.push({ ...f, kind, obstacle: state });
      continue;
    }
    if (cur.st.size !== f.size) { restore.push({ ...f, kind: 'changed', obstacle: 'file' }); continue; }
    let sha = null;
    try { sha = hashFile(cur.abs); } catch { sha = null; }
    if (sha === f.sha256) unchanged += 1;
    else restore.push({ ...f, kind: 'changed', obstacle: 'file' });
  }
  const setAside = [];
  for (const [k, cur] of current) {
    if (snapKeys.has(k)) continue;
    const s = snapSkipped.get(k);
    if (s) { notCovered.push({ path: cur.rel, why: s.why }); continue; }
    setAside.push(cur.rel);
  }
  setAside.sort();
  return { manifest, restore, setAside, unchanged, notCovered };
}

function diff(workspaceArg, idArg) {
  const ctx = openContext(workspaceArg);
  const id = resolveId(ctx, idArg);
  const manifest = loadManifestStrict(ctx, id);
  return planRestore(ctx, manifest);
}

// ---- 元に戻す ---------------------------------------------------------------------

function removeEmptyDirs(dir) {
  let names;
  try { names = fs.readdirSync(dir); } catch { return; }
  for (const name of names) {
    const p = path.join(dir, name);
    const st = lstatOrNull(p);
    if (st && st.isDirectory() && !st.isSymbolicLink()) removeEmptyDirs(p);
  }
  try { fs.rmdirSync(dir); } catch { /* 空でなければ残る（ファイルは消さない） */ }
}

function restoreLocked(ctx, lock, idArg, opts = {}) {
  const id = resolveId(ctx, idArg);
  const target = loadManifestStrict(ctx, id);
  const plan = planRestore(ctx, target);

  // 書き戻しに使う中身を、何かを変える前に全部確かめる（1 つでも壊れていたら何もしない）。
  const broken = [];
  const checked = new Set();
  for (const r of plan.restore) {
    lock.touch();
    if (checked.has(r.sha256)) continue;
    checked.add(r.sha256);
    if (!verifyObject(ctx, r.sha256)) broken.push(r.path);
  }
  if (broken.length) {
    throw new SnapshotError(`控えの中身が壊れているため、元に戻すのを中止しました（何も変えていません）: ${broken.slice(0, 5).join(', ')}${broken.length > 5 ? ' ほか' : ''}`, 'corrupt');
  }
  const result = { id, plan, before: null, setAsideDir: null, restored: [], movedAside: [], failed: [] };
  if (opts.dryRun || (plan.restore.length === 0 && plan.setAside.length === 0)) return result;

  // 元に戻したこと自体を元に戻せるよう、先に今の状態の控えを取る。全ファイルを読み直して
  // 正確に取る（速い道は使わない）。取れなければ何も変えずに中止する。
  const before = takeLocked(ctx, lock, { reason: 'before-restore', restoreTarget: id, noFastPath: true });
  result.before = { id: before.id, reused: before.reused };
  const beforeKeys = new Set(before.manifest.files.map((f) => ctx.keyOf(f.path)));

  let setAsideDir = null;
  const ensureSetAsideDir = () => {
    if (setAsideDir) return setAsideDir;
    fs.mkdirSync(ctx.sp.setAside, { recursive: true, mode: 0o700 });
    const base = localStamp(new Date());
    let candidate = path.join(ctx.sp.setAside, base);
    for (let i = 2; fs.existsSync(candidate); i += 1) candidate = path.join(ctx.sp.setAside, `${base}_${i}`);
    fs.mkdirSync(candidate, { recursive: true, mode: 0o700 });
    setAsideDir = candidate;
    result.setAsideDir = candidate;
    return candidate;
  };
  // 消さずに脇へ移す。同じ名前があれば番号を付ける。別ドライブなら写してから元を片付ける。
  const moveAside = (rel, kind) => {
    const src = path.join(ctx.ws, ...rel.split('/'));
    let dest = path.join(ensureSetAsideDir(), ...rel.split('/'));
    fs.mkdirSync(path.dirname(dest), { recursive: true, mode: 0o700 });
    if (lstatOrNull(dest)) {
      let i = 1;
      while (lstatOrNull(`${dest}.${i}`)) i += 1;
      dest = `${dest}.${i}`;
    }
    try {
      fs.renameSync(src, dest);
    } catch (e) {
      if (!e || e.code !== 'EXDEV') throw e;
      const st = fs.lstatSync(src);
      if (!st.isFile()) throw e;
      fs.copyFileSync(src, dest, fs.constants.COPYFILE_EXCL);
      if (fs.statSync(dest).size !== st.size) throw new SnapshotError(`脇へ移せませんでした: ${rel}`);
      fs.unlinkSync(src);
    }
    result.movedAside.push({ path: rel, kind: kind || 'file', to: dest });
  };

  const restoreOne = (r) => {
    const segs = r.path.split('/');
    let dirAbs = ctx.ws;
    for (let i = 0; i < segs.length - 1; i += 1) {
      dirAbs = path.join(dirAbs, segs[i]);
      const relSoFar = segs.slice(0, i + 1).join('/');
      let st = lstatOrNull(dirAbs);
      if (st && st.isSymbolicLink()) { moveAside(relSoFar, 'link'); st = null; }
      else if (st && st.isFile()) { moveAside(relSoFar, 'file'); st = null; }
      else if (st && !st.isDirectory()) throw new SnapshotError('フォルダの位置に別のものがあります');
      if (!st) fs.mkdirSync(dirAbs);
    }
    // 実体のパスでもう一度確かめる（短い名前・大文字小文字・リンクの抜け道を塞ぐ）。
    const realParent = fs.realpathSync.native(dirAbs);
    if (!isInside(realParent, ctx.ws)) throw new SnapshotError('作業フォルダの外を指しているため書き戻しません');
    if (isInside(realParent, ctx.aiSafetyReal)) throw new SnapshotError('.ai-safety の中には書き戻しません');
    const targetAbs = path.join(dirAbs, segs[segs.length - 1]);
    const st = lstatOrNull(targetAbs);
    if (st && st.isSymbolicLink()) moveAside(r.path, 'link');
    else if (st && st.isDirectory()) {
      removeEmptyDirs(targetAbs);
      if (lstatOrNull(targetAbs)) throw new SnapshotError('同じ名前のフォルダがあり、中にファイルが残っているため書き戻せません');
    } else if (st && st.isFile()) {
      // いまの中身が「元に戻す直前」の控えに入っていないとき（大きすぎる等）は、
      // 上書きで失わないよう脇へ移してから書き戻す。
      if (!beforeKeys.has(ctx.keyOf(r.path))) moveAside(r.path, 'file');
    } else if (st) {
      throw new SnapshotError('普通のファイルではないものがあるため書き戻せません');
    }
    const tmp = path.join(dirAbs, `.ai-safe-restore-${randHex(6)}.tmp`);
    try {
      const written = copyWithHash(objectPath(ctx, r.sha256), tmp);
      if (written.sha256 !== r.sha256) throw new SnapshotError('控えの中身が壊れています');
      if (!IS_WIN && Number.isInteger(r.mode)) fs.chmodSync(tmp, r.mode & 0o777);
      try {
        fs.renameSync(tmp, targetAbs);
      } catch (e) {
        // Windows の「読み取り専用」属性が付いたファイルは置き換えられないので外してから。
        if (IS_WIN && e && (e.code === 'EPERM' || e.code === 'EACCES') && lstatOrNull(targetAbs)) {
          fs.chmodSync(targetAbs, 0o666);
          fs.renameSync(tmp, targetAbs);
        } else {
          throw e;
        }
      }
    } catch (e) {
      try { fs.unlinkSync(tmp); } catch { /* 無ければよい */ }
      throw e;
    }
    if (Number.isFinite(r.mtimeMs)) {
      try { fs.utimesSync(targetAbs, new Date(), new Date(r.mtimeMs)); } catch { /* 時刻だけなので続ける */ }
    }
  };

  const errMsg = (e) => (e && e.message ? String(e.message) : String(e));
  for (const rel of plan.setAside) {
    lock.touch();
    try { moveAside(rel, 'file'); } catch (e) { result.failed.push({ path: rel, action: 'set-aside', why: errMsg(e) }); }
  }
  for (const r of plan.restore) {
    lock.touch();
    try { restoreOne(r); result.restored.push({ path: r.path, kind: r.kind }); } catch (e) {
      result.failed.push({ path: r.path, action: 'restore', why: errMsg(e) });
    }
  }
  return result;
}

function restore(workspaceArg, idArg, opts = {}) {
  const ctx = openContext(workspaceArg);
  const lock = acquireLock(ctx, opts.lockWaitMs);
  try {
    return restoreLocked(ctx, lock, idArg, opts);
  } finally {
    lock.release();
  }
}

// ---- 画面に出す文 -------------------------------------------------------------------

function formatList(items, { showId = true } = {}) {
  if (!items.length) return ['まだ控えがありません。AI をスタートのボタンから起動すると、起動の直前に自動で控えを取ります。'];
  const out = ['作業フォルダの控え（新しい順）:'];
  for (const it of items) {
    const n = String(it.number).padStart(3, ' ');
    const idText = showId ? `  [${it.id}]` : '';
    if (it.broken) { out.push(`${n}) (読めない控え)${idText}`); continue; }
    out.push(`${n}) ${fmtLocalTime(it.createdAt)}  ${it.reasonLabel}  ${fmtNum(it.files)} ファイル${idText}`);
  }
  return out;
}

function formatPlan(plan, limit) {
  const max = limit || 200;
  const out = [];
  const m = plan.manifest;
  out.push(`控え: ${fmtLocalTime(m.createdAt)}  ${reasonLabel(m.reason)}（${fmtNum(m.files.length)} ファイル）`);
  const changed = plan.restore.filter((r) => r.kind === 'changed');
  const deleted = plan.restore.filter((r) => r.kind === 'deleted');
  if (!plan.restore.length && !plan.setAside.length) {
    out.push('この控えのあとで変わったファイルはありません。元に戻す必要はありません。');
  } else {
    out.push(`■ 控えの中身に戻すファイル: ${fmtNum(plan.restore.length)} 件（書き換えられた ${fmtNum(changed.length)}・消された ${fmtNum(deleted.length)}）`);
    plan.restore.slice(0, max).forEach((r) => out.push(`    ${r.kind === 'deleted' ? '消された  ' : '書き換え  '} ${r.path}`));
    if (plan.restore.length > max) out.push(`    …ほか ${fmtNum(plan.restore.length - max)} 件`);
    out.push(`■ 脇へ片付けるファイル（控えのあとで新しくできたもの）: ${fmtNum(plan.setAside.length)} 件`);
    plan.setAside.slice(0, max).forEach((p) => out.push(`    ${p}`));
    if (plan.setAside.length > max) out.push(`    …ほか ${fmtNum(plan.setAside.length - max)} 件`);
    if (plan.setAside.length) out.push('    → 消しません。.ai-safety/snapshots/set-aside/<日時>/ へ移します。');
  }
  if (plan.notCovered.length) {
    out.push(`■ 控えに入っていないため、そのまま残すファイル: ${fmtNum(plan.notCovered.length)} 件`);
    plan.notCovered.slice(0, max).forEach((s) => out.push(`    ${s.path}（${SKIP_LABELS[s.why] || s.why}）`));
    if (plan.notCovered.length > max) out.push(`    …ほか ${fmtNum(plan.notCovered.length - max)} 件`);
  }
  return out;
}

function formatRestoreResult(res) {
  const out = [];
  out.push(`元に戻しました（戻したファイル ${fmtNum(res.restored.length)} 件・脇へ片付けたファイル ${fmtNum(res.movedAside.length)} 件）。`);
  if (res.setAsideDir && res.movedAside.length) {
    out.push('片付けたファイルは消していません。ここにあります:');
    out.push(`  ${res.setAsideDir}`);
  }
  if (res.failed.length) {
    out.push(`⚠ うまくいかなかったファイルが ${fmtNum(res.failed.length)} 件あります（開いているアプリを閉じてから、もう一度やり直してください）:`);
    res.failed.slice(0, 50).forEach((f) => out.push(`    ${f.path}（${f.why}）`));
  }
  if (res.before) {
    out.push('元に戻す直前の状態も控えに取ってあります。やっぱり戻したくないときは、');
    out.push('もう一度「作業フォルダを元に戻す」を使い、「元に戻す直前」の控えを選んでください。');
  }
  return out;
}

function formatTakeResult(r) {
  const extra = r.skippedCount ? `・対象外 ${fmtNum(r.skippedCount)} 件` : '';
  const head = r.reused ? '作業フォルダの控えを確認しました（前回から変更なし・' : '作業フォルダの控えを取りました（';
  return `${head}${fmtNum(r.fileCount)} ファイル${extra}・${r.seconds.toFixed(1)} 秒）`;
}

function print(lines) {
  process.stdout.write(lines.join('\n') + '\n');
}

// ---- 対話（スタートのボタン用） -------------------------------------------------------

// 1 行ずつ読む。パイプで一度に流し込まれても取りこぼさないよう、自前で行を溜めておく。
function makeLineReader() {
  const readline = require('node:readline');
  const rl = readline.createInterface({ input: process.stdin, terminal: false });
  const lines = [];
  const waiters = [];
  let closed = false;
  rl.on('line', (line) => {
    if (waiters.length) waiters.shift()(line);
    else lines.push(line);
  });
  rl.on('close', () => {
    closed = true;
    while (waiters.length) waiters.shift()(null);
  });
  return {
    ask(prompt) {
      process.stdout.write(prompt);
      if (lines.length) return Promise.resolve(lines.shift());
      if (closed) return Promise.resolve(null);
      return new Promise((resolve) => waiters.push(resolve));
    },
    close() {
      rl.close();
      try { process.stdin.pause(); } catch { /* 既に閉じている */ }
    },
  };
}

function openFolder(dir) {
  const { spawn } = require('node:child_process');
  try {
    const cmd = IS_WIN ? 'explorer.exe' : (process.platform === 'darwin' ? 'open' : 'xdg-open');
    const child = spawn(cmd, [dir], { detached: true, stdio: 'ignore' });
    child.on('error', () => {});
    child.unref();
  } catch { /* 開けなくても場所は表示済み */ }
}

async function wizard(workspaceArg) {
  const io = makeLineReader();
  try {
    print(['', ' ■ 作業フォルダを元に戻す', '']);
    const ctx = openContext(workspaceArg);
    print([` 対象の作業フォルダ: ${ctx.ws}`, '']);
    // Codex デスクトップアプリや AGI Cockpit など、ボタンを通らずに AI を使う人向けに、
    // ここで「いまの状態の控え」を手で取れるようにしておく。
    const takeNow = () => {
      const r = take(ctx.ws, { reason: 'manual' });
      print(['', ' ' + formatTakeResult(r)]);
      return 0;
    };
    const items = listIds(ctx).map((id, i) => summarizeManifest(ctx, id, i + 1));
    if (!items.length) {
      print([
        ' まだ控えがありません。',
        ' 「4_AIを起動する」などのボタンから AI を起動すると、起動の直前に自動で控えを取ります。',
        '',
      ]);
      const ans = ((await io.ask('いまの状態の控えを取っておくなら s を入力して Enter（やめるなら Enter だけ）: ')) || '').trim();
      if (ans === 's' || ans === 'S') return takeNow();
      return 0;
    }
    print(formatList(items, { showId: false }).map((l) => ' ' + l));
    print(['']);
    const pick = ((await io.ask('どの時点に戻しますか。番号を入れて Enter（いまの状態の控えを取るなら s、やめるなら Enter だけ）: ')) || '').trim();
    if (!pick) { print(['やめました。何も変えていません。']); return 0; }
    if (pick === 's' || pick === 'S') return takeNow();
    if (!/^[0-9]+$/.test(pick) || Number(pick) < 1 || Number(pick) > items.length) {
      print([`1〜${items.length} の番号を入れてください。何も変えていません。`]);
      return 2;
    }
    const id = items[Number(pick) - 1].id; // ここで id に固定する（途中で控えが増えても番号がずれない）
    print(['', ' 調べています…', '']);
    const manifest = loadManifestStrict(ctx, id);
    const plan = planRestore(ctx, manifest);
    print(formatPlan(plan, 20).map((l) => ' ' + l));
    print(['']);
    if (!plan.restore.length && !plan.setAside.length) return 0;
    const yes = ((await io.ask('元に戻してよければ y を入力して Enter（やめるなら Enter だけ）: ')) || '').trim();
    if (yes !== 'y' && yes !== 'Y') { print(['やめました。何も変えていません。']); return 0; }
    print(['', ' 元に戻しています…（終わるまでこの画面を閉じないでください）', '']);
    const onSigint = () => process.stdout.write('\n 終わるまでお待ちください…\n');
    process.on('SIGINT', onSigint);
    let res;
    try {
      res = restore(ctx.ws, id);
    } finally {
      process.removeListener('SIGINT', onSigint);
    }
    print(formatRestoreResult(res).map((l) => ' ' + l));
    if (res.setAsideDir && res.movedAside.length) {
      print(['']);
      const open = ((await io.ask('片付けたファイルの場所を開きますか？（開くなら y を入力して Enter）: ')) || '').trim();
      if (open === 'y' || open === 'Y') openFolder(res.setAsideDir);
    }
    return res.failed.length ? 2 : 0;
  } finally {
    io.close();
  }
}

// ---- CLI -----------------------------------------------------------------------------

function usage() {
  return [
    'usage:',
    '  workspace-snapshot.js take    --workspace <dir> [--reason <text>] [--quiet] [--launcher]',
    '  workspace-snapshot.js list    --workspace <dir> [--json]',
    '  workspace-snapshot.js diff    --workspace <dir> --id <id|番号>',
    '  workspace-snapshot.js restore --workspace <dir> --id <id|番号> [--yes] [--dry-run]',
    '  workspace-snapshot.js prune   --workspace <dir> [--keep N]',
    '  workspace-snapshot.js wizard  --workspace <dir>',
    '',
  ].join('\n');
}

function parseArgs(argv) {
  const opts = { cmd: argv[0] || '' };
  const valued = { '--workspace': 'workspace', '--reason': 'reason', '--id': 'id', '--keep': 'keep' };
  const flags = { '--quiet': 'quiet', '--json': 'json', '--yes': 'yes', '--dry-run': 'dryRun', '--launcher': 'launcher' };
  for (let i = 1; i < argv.length; i += 1) {
    const a = argv[i];
    if (Object.prototype.hasOwnProperty.call(valued, a)) {
      if (i + 1 >= argv.length) throw new SnapshotError(`${a} のあとに値が必要です。`, 'usage');
      opts[valued[a]] = argv[i + 1];
      i += 1;
    } else if (Object.prototype.hasOwnProperty.call(flags, a)) {
      opts[flags[a]] = true;
    } else {
      throw new SnapshotError(`知らない指定です: ${a}`, 'usage');
    }
  }
  if (opts.keep != null) {
    const k = Number(opts.keep);
    if (!Number.isInteger(k) || k < 1) throw new SnapshotError('--keep には 1 以上の整数を指定してください。', 'usage');
    opts.keep = k;
  }
  return opts;
}

function makeProgress() {
  if (!process.stdout.isTTY) return undefined;
  const t0 = Date.now();
  let last = 0;
  let shown = false;
  const fn = (done, total) => {
    const now = Date.now();
    if (now - t0 < 1500 || now - last < 500) return;
    last = now;
    shown = true;
    process.stdout.write(`\r作業フォルダの控えを取っています… ${fmtNum(done)} / ${fmtNum(total)} ファイル`);
  };
  fn.clear = () => { if (shown) process.stdout.write('\r\x1b[K'); };
  return fn;
}

async function main(argv) {
  const o = parseArgs(argv);
  switch (o.cmd) {
    case 'take': {
      const progress = o.quiet ? undefined : makeProgress();
      let r;
      try {
        r = take(o.workspace, { reason: o.reason, progress });
      } catch (e) {
        if (!o.launcher) throw e;
        const why = e instanceof SnapshotError ? e.message : `思わぬエラー: ${(e && e.message) || e}`;
        print([`※ 元に戻す用の控えを取れませんでした（${why}）。そのまま起動します。`]);
        return 0;
      } finally {
        if (progress) progress.clear();
      }
      if (!o.quiet) print([formatTakeResult(r)]);
      return 0;
    }
    case 'list': {
      const items = list(o.workspace);
      if (o.json) print([JSON.stringify(items, null, 2)]);
      else print(formatList(items));
      return 0;
    }
    case 'diff': {
      const plan = diff(o.workspace, o.id);
      print(formatPlan(plan));
      return 0;
    }
    case 'restore': {
      if (o.dryRun) {
        const res = restore(o.workspace, o.id, { dryRun: true });
        print(formatPlan(res.plan));
        print(['（--dry-run なので何も変えていません）']);
        return 0;
      }
      if (!o.yes) {
        const ctx = openContext(o.workspace);
        const id = resolveId(ctx, o.id);
        const plan = planRestore(ctx, loadManifestStrict(ctx, id));
        print(formatPlan(plan));
        if (!plan.restore.length && !plan.setAside.length) return 0;
        if (!process.stdin.isTTY) throw new SnapshotError('確認のため --yes を付けて実行してください（何も変えていません）。', 'usage');
        const io = makeLineReader();
        let ans;
        try { ans = ((await io.ask('元に戻してよければ y を入力して Enter: ')) || '').trim(); } finally { io.close(); }
        if (ans !== 'y' && ans !== 'Y') { print(['やめました。何も変えていません。']); return 0; }
        const res = restore(ctx.ws, id);
        print(formatRestoreResult(res));
        return res.failed.length ? 2 : 0;
      }
      const res = restore(o.workspace, o.id);
      if (!res.plan.restore.length && !res.plan.setAside.length) {
        print(formatPlan(res.plan));
        return 0;
      }
      print(formatRestoreResult(res));
      return res.failed.length ? 2 : 0;
    }
    case 'prune': {
      const r = prune(o.workspace, { keep: o.keep });
      print([`古い控えを整理しました（控え ${fmtNum(r.removedManifests)} 件・使われなくなった中身 ${fmtNum(r.removedObjects)} 件）${r.gcSkipped ? '。読めない控えがあったため中身の片付けは見送りました' : ''}`]);
      return 0;
    }
    case 'wizard':
      return wizard(o.workspace);
    case '-h':
    case '--help':
      process.stdout.write(usage());
      return 0;
    default:
      process.stderr.write(usage());
      return 2;
  }
}

module.exports = {
  take, list, diff, restore, prune,
  isSafeRelPath, reasonLabel,
  EXCLUDE_NAMES, TOP_EXCLUDES,
  SnapshotError,
  _internal: { openContext, planRestore, loadManifestStrict, listIds, objectPath, acquireLock, manifestPath },
};

if (require.main === module) {
  main(process.argv.slice(2)).then(
    (code) => { process.exitCode = code; },
    (e) => {
      const msg = e instanceof SnapshotError ? e.message : `思わぬエラーで中止しました: ${(e && e.message) || e}`;
      process.stderr.write(msg + '\n');
      process.exitCode = 2;
    },
  );
}
