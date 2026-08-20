// secret-store.js — OS 標準の金庫（macOS キーチェーン / Windows DPAPI）への最小ラッパ。
//
// 設計方針（secrets-encryption-design.md 第3版 B-0 に準拠）:
//   - 参照 URI 体系（secret:// 等）は作らない。バックエンド抽象化レイヤも作らない。
//     ここにあるのは get / set / remove / exists の4関数と、process.platform の分岐だけ。
//   - 項目名は下の ITEMS 固定表だけ。動的にバックエンドを増やせる作りにはしない。
//   - 読み取りの優先順位は全箇所で「環境変数 → 金庫 → 旧平文」に統一する。
//     この順序を14箇所に複製しないために resolve() を1つだけ置く（分岐ではなく順序の SSOT）。
//     第1段の環境変数があるおかげで、1Password の `op run` 利用者には
//     パッケージ側の分岐がゼロで対応できる。これが 1Password 対応の実体。
//
// 保存形式（両 OS 共通）:
//   金庫に入れる文字列は "v1:" + base64(UTF-8) の封筒に包む。
//   理由: macOS の `security find-generic-password -w` は、データが非 ASCII を含むと
//   16進文字列で出力する。生値のまま入れると「16進で出た値」と「たまたま16進に見える値」
//   （64桁 hex のトークン等）を区別できない。"v1:" 前置きで必ず非16進にして曖昧さを消す。
//   シェル / PowerShell 側の登録スクリプトも同じ封筒を使う。
'use strict';

const { execFileSync, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// 金庫の項目名は固定表。ここに無い名前は受け付けない（タイプミスで別項目を作らせない）。
//   name          : このパッケージ内での呼び名
//   service       : macOS キーチェーンの service 名（接頭辞 + name）
//   winFile       : Windows の DPAPI ファイル名
//   env           : 読み取り時に先に見る環境変数（先頭優先）
//   legacyFile    : 旧平文ファイル（ホームからの相対パス）
const ITEMS = {
  gemini: {
    winFile: 'gemini.dpapi',
    env: ['GEMINI_API_KEY', 'GOOGLE_API_KEY'],
    legacyFiles: [['.ai-safety', 'gemini-api-key.txt']],
  },
  buffer: {
    winFile: 'buffer.dpapi',
    env: ['BUFFER_ACCESS_TOKEN'],
    legacyFiles: [['.ai-safety', 'buffer-api-key.txt']],
  },
  deepseek: {
    winFile: 'deepseek.dpapi',
    env: ['DEEPSEEK_API_KEY'],
    legacyFiles: [['.deepseek-claude', 'auth']],
  },
  // 有料 Gemini キー。パッケージ内から読む箇所は無いが、644 で実在するため移行対象に含める
  // （移行しても平文は消さない。パッケージ外の利用者がいる可能性があるため）。
  'gemini-paid': {
    winFile: 'gemini-paid.dpapi',
    env: [],
    legacyFiles: [['.ai-safety', 'gemini-api-key-paid.txt']],
  },
  // マスキングツールの対応表を開ける鍵（32 バイト乱数の base64）。
  // 対応表そのものは AES-256-GCM で暗号化して隣のファイルに置く（clipboard-mask.js の封筒方式）。
  maskmap: {
    winFile: 'maskmap.dpapi',
    env: [],
    legacyFiles: [],
  },
};

const ENVELOPE_PREFIX = 'v1:';

// キーチェーンの service 接頭辞。既定 "ai-safety."。
// テストが本物のキーチェーンを別名で使うためだけの上書き口で、保存方式は一切変えない。
function servicePrefix() {
  const p = process.env.AI_SAFE_KEYCHAIN_PREFIX;
  return (p && p.trim()) ? p.trim() : 'ai-safety.';
}

// Windows の DPAPI ファイル置き場。既定 %USERPROFILE%\.ai-safety
function secretDir() {
  const d = process.env.AI_SAFE_SECRET_DIR;
  return (d && d.trim()) ? d.trim() : path.join(os.homedir(), '.ai-safety');
}

function itemOrThrow(name) {
  const item = ITEMS[name];
  if (!item) throw new Error(`secret-store: unknown secret name: ${name}`);
  return item;
}

function wrap(value) {
  return ENVELOPE_PREFIX + Buffer.from(String(value), 'utf8').toString('base64');
}

function unwrap(stored) {
  const s = String(stored == null ? '' : stored).replace(/[\r\n]+$/, '');
  if (!s) return '';
  if (s.startsWith(ENVELOPE_PREFIX)) {
    try { return Buffer.from(s.slice(ENVELOPE_PREFIX.length), 'base64').toString('utf8'); } catch { return ''; }
  }
  // 封筒なしで入っていた場合（手作業で入れた等）は生値として扱う。
  return s;
}

// ---- macOS: キーチェーン -------------------------------------------------
// 値はコマンドライン引数に置かない（ps で他ユーザーに見える）。`-w` を値なしで
// 末尾に置くと対話プロンプトになるので、標準入力から2回（本文 + 確認）流し込む。
// macOS の `security ... -w`（対話プロンプト）は 128 文字で切り捨てる（実測）。
// 黙って切られると「入れたのに違う値が返る」事故になるので、越えたら必ず失敗させる。
// API キーはどれも余裕で収まる。長い秘密（マスキングの対応表）は clipboard-mask.js 側で
// 「鍵だけを金庫に入れ、本体は暗号化して置く」封筒方式にしてある。
const MAC_KEYCHAIN_MAX = 128;

// 金庫の呼び出しには必ず制限時間を付ける。`security ... -w` は値を対話プロンプトで読むため、
// キーチェーンが開けない環境（ロック中・ログインキーチェーンが無い等）では入力待ちのまま
// 永遠に止まる。導入スクリプトはこの中で自動移行を走らせるので、止まると導入自体が固まる。
// 時間切れは「金庫が使えなかった」として扱い、呼び出し側は旧平文のまま動き続ける。
const KEYCHAIN_TIMEOUT_MS = 15000;
const RUN_OPTS = { encoding: 'utf8', timeout: KEYCHAIN_TIMEOUT_MS, killSignal: 'SIGKILL' };

function macSet(name, value) {
  const envelope = wrap(value);
  if (envelope.length > MAC_KEYCHAIN_MAX) {
    throw new Error(`secret-store: value too long for the macOS keychain prompt (${envelope.length} > ${MAC_KEYCHAIN_MAX})`);
  }
  const r = spawnSync('/usr/bin/security',
    ['add-generic-password', '-U', '-a', process.env.USER || os.userInfo().username,
      '-s', servicePrefix() + name, '-w'],
    Object.assign({ input: `${envelope}\n${envelope}\n` }, RUN_OPTS));
  if (r.status !== 0) throw new Error(`secret-store: keychain write failed for ${name}`);
  return true;
}

function macGet(name) {
  const r = spawnSync('/usr/bin/security',
    ['find-generic-password', '-a', process.env.USER || os.userInfo().username,
      '-s', servicePrefix() + name, '-w'],
    RUN_OPTS);
  if (r.status !== 0) return null;
  const v = unwrap(r.stdout);
  return v || null;
}

function macRemove(name) {
  const r = spawnSync('/usr/bin/security',
    ['delete-generic-password', '-a', process.env.USER || os.userInfo().username,
      '-s', servicePrefix() + name],
    RUN_OPTS);
  return r.status === 0;
}

// ---- Windows: DPAPI ------------------------------------------------------
// ConvertFrom-SecureString はキー未指定なら DPAPI で暗号化する（暗号化した Windows
// ユーザー + 同じマシンでしか復号できない）。復号は PowerShell 5.1 で動く Marshal 経由。
// `ConvertFrom-SecureString -AsPlainText` は PowerShell 7.0 以降なので使わない。
function winFile(name) {
  return path.join(secretDir(), itemOrThrow(name).winFile);
}

// ファイルパスはコマンド文字列に埋めず環境変数で渡す（バックスラッシュのエスケープ事故と
// 引用符インジェクションの両方を避ける）。
function runPowerShell(script, { input, file } = {}) {
  const env = Object.assign({}, process.env);
  if (file) env.AI_SAFE_DPAPI_FILE = file;
  return spawnSync('powershell',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
    Object.assign({ input: input === undefined ? '' : input, env }, RUN_OPTS));
}

function winSet(name, value) {
  const file = winFile(name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const script =
    '$ErrorActionPreference="Stop";' +
    '$p=[Console]::In.ReadToEnd().Trim();' +
    '(ConvertTo-SecureString $p -AsPlainText -Force | ConvertFrom-SecureString) | ' +
    'Set-Content -LiteralPath $env:AI_SAFE_DPAPI_FILE -Encoding ascii -NoNewline';
  const r = runPowerShell(script, { input: wrap(value) + '\n', file });
  if (r.status !== 0) throw new Error(`secret-store: DPAPI write failed for ${name}`);
  return true;
}

function winGet(name) {
  const file = winFile(name);
  if (!fs.existsSync(file)) return null;
  const script =
    '$ErrorActionPreference="Stop";' +
    '$e=(Get-Content -LiteralPath $env:AI_SAFE_DPAPI_FILE -Raw).Trim();' +
    '$s=ConvertTo-SecureString $e;' +
    '[Runtime.InteropServices.Marshal]::PtrToStringBSTR(' +
    '[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))';
  const r = runPowerShell(script, { file });
  if (r.status !== 0) return null;
  const v = unwrap(r.stdout);
  return v || null;
}

function winRemove(name) {
  const file = winFile(name);
  try { fs.rmSync(file, { force: true }); return true; } catch { return false; }
}

// ---- 4 関数（process.platform の分岐はここだけ） -------------------------

// 金庫が使える環境かどうか。使えなければ呼び出し側は旧平文にフォールバックする。
function available() {
  if (process.platform === 'darwin') {
    try {
      if (!fs.existsSync('/usr/bin/security')) return false;
      // 書き込み先のログインキーチェーンが本当に在るかを先に確かめる。
      // ここを飛ばすと、キーチェーンが無い環境（$HOME が差し替えられている等）で
      // `add-generic-password -w` が対話プロンプトのまま止まる。実測で確認した挙動:
      //   ・キーチェーンが無い → `security login-keychain` が非ゼロで即座に返る
      //   ・`find-generic-password` は「見つからない」を返すだけなので判定には使えない
      const r = spawnSync('/usr/bin/security', ['login-keychain'], RUN_OPTS);
      return r.status === 0 && !!String(r.stdout || '').trim();
    } catch { return false; }
  }
  if (process.platform === 'win32') {
    const r = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.Major'], RUN_OPTS);
    return r.status === 0;
  }
  return false;
}

function set(name, value) {
  itemOrThrow(name);
  const v = String(value == null ? '' : value);
  if (!v) throw new Error('secret-store: refusing to store an empty value');
  if (process.platform === 'darwin') return macSet(name, v);
  if (process.platform === 'win32') return winSet(name, v);
  throw new Error('secret-store: no OS keystore on this platform');
}

function get(name) {
  itemOrThrow(name);
  try {
    if (process.platform === 'darwin') return macGet(name);
    if (process.platform === 'win32') return winGet(name);
  } catch { /* 金庫が壊れている / 権限拒否 → null（呼び出し側が旧平文へ落ちる） */ }
  return null;
}

function remove(name) {
  itemOrThrow(name);
  try {
    if (process.platform === 'darwin') return macRemove(name);
    if (process.platform === 'win32') return winRemove(name);
  } catch { /* ignore */ }
  return false;
}

function exists(name) {
  return get(name) !== null;
}

// ---- 読み取り順序の SSOT: 環境変数 → 金庫 → 旧平文 -----------------------
// 返り値: { value, source: 'env'|'vault'|'legacy'|null, legacyPath }
// value が null なら未登録。source==='legacy' のときは呼び出し側が黄色い警告を出す。
function legacyPaths(name, homeDir = os.homedir()) {
  return itemOrThrow(name).legacyFiles.map((rel) => path.join(homeDir, ...rel));
}

function readLegacy(name, homeDir = os.homedir()) {
  for (const p of legacyPaths(name, homeDir)) {
    try {
      const v = fs.readFileSync(p, 'utf8').trim();
      if (v) return { value: v, legacyPath: p };
    } catch { /* 次の候補へ */ }
  }
  return null;
}

function resolve(name, { env = process.env, homeDir = os.homedir() } = {}) {
  const item = itemOrThrow(name);
  for (const key of item.env) {
    const v = env[key];
    if (v && String(v).trim()) return { value: String(v).trim(), source: 'env', legacyPath: null };
  }
  const vault = get(name);
  if (vault) return { value: vault, source: 'vault', legacyPath: null };
  const legacy = readLegacy(name, homeDir);
  if (legacy) return { value: legacy.value, source: 'legacy', legacyPath: legacy.legacyPath };
  return { value: null, source: null, legacyPath: null };
}

// 値そのものは要らず「登録されているか」だけ知りたい箇所用（設定に値を書き出さない設計を維持）。
function resolvedExists(name, opts) {
  return resolve(name, opts).value !== null;
}

module.exports = {
  get, set, remove, exists,
  resolve, resolvedExists, available,
  legacyPaths, ITEMS, ENVELOPE_PREFIX,
};

// ---- 最小の CLI -----------------------------------------------------------
// シェル / PowerShell の起動スクリプトが「鍵が登録されているか」だけを聞くための口。
//   node secret-store.js --has <name>   → 標準出力に yes / no、終了コード 0 / 1
// 値そのものは絶対に出力しない（秘密を標準出力・プロセス一覧に載せない設計を守る）。
// 判定は resolve()（環境変数 → 金庫 → 旧平文）そのものなので、起動条件が
// 「旧平文ファイルの実在」に戻ることはない。
if (require.main === module) {
  const argv = process.argv.slice(2);
  const i = argv.indexOf('--has');
  if (i === -1 || !argv[i + 1]) {
    process.stderr.write('usage: secret-store.js --has <name>\n');
    process.exit(2);
  }
  let ok = false;
  try { ok = resolvedExists(argv[i + 1]); } catch (e) {
    process.stderr.write(String((e && e.message) || e) + '\n');
    process.exit(2);
  }
  process.stdout.write(ok ? 'yes\n' : 'no\n');
  process.exit(ok ? 0 : 1);
}
