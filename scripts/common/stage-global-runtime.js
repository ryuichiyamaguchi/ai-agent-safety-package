#!/usr/bin/env node
'use strict';
// stage-global-runtime.js — 「PC 全体の安全設定」が使う安全ガードの本体を、作業フォルダの外の
// 動かない場所 (~/.ai-safety/global/、Windows は %USERPROFILE%\.ai-safety\global\) へ複製する。
//
// なぜ要るのか:
//   PC 全体の設定 (~/.claude/settings.json / ~/.codex/hooks.json / ~/.gemini/settings.json) の hook は
//   guard スクリプトを「絶対パス」で呼び、スクリプトが見つからないときは安全側に倒して
//   exit 2 (= 実行を止める) する。以前はその絶対パスが作業フォルダの中
//   (<ws>/.ai-safety/hooks/macos/guard-*.sh) を指していたため、受講者が作業フォルダを
//   移動・名前変更した（あるいは iCloud が書類フォルダを退避した）瞬間に、この PC の
//   すべての Claude セッションが止まっていた。作業フォルダの移動はポリシーでも止めていない。
//   hook の参照先を作業フォルダから切り離すため、ガード一式をホーム直下の固定の場所へ置く。
//
// 置く中身（ガードが「自分の置き場所からの相対パス」で読むものだけ。作業フォルダと同じ並び）:
//   global/hooks/<os>/guard-*.{sh|ps1}   … ガード本体
//   global/hooks/<os>/lib/               … safety_policy / explainer（SafetyPolicy.ps1 / Explainer.ps1）
//   global/hooks/common/                 … command-judge.js / plutil-p.js / answer-snapshot.js など
//                                          （test/ と assets/ は不要なので持ち込まない）
//   global/policy/safety-policy.json     … ガードは <hooks/os>/../../policy を同梱ポリシーとして読む
//   global/cards/                        … 承認解説カード（explainer が <lib>/../../../cards を読む）
//
// 入れ替えは「一時フォルダへ全部コピー → 中身を確かめる → 名前の付け替え 2 回」で行う。
// コピー途中の半端な状態が global/ に見えることは無い。確かめに失敗したら今ある global/ は
// そのまま残す（古くても完全な一式なので、hook は動き続ける）。
//
// ~/.ai-safety は決定的 deny 床の保護パスなので、AI はここに書き込めない（人とインストーラーだけ）。
//
// Usage:
//   node stage-global-runtime.js --os macos|windows --guard-src <guard-*.{sh,ps1} があるフォルダ>
//                                [--dest <置き場。既定 ~/.ai-safety/global>]
// 終了コード:
//   0 = 置き場に完全な一式がある（今回更新した / 更新できなかったが前回の一式が残っている）
//   1 = 使える一式が置き場に無い（呼び出し側は hook をここへ向けてはいけない）
//   2 = 引数の誤り
// 出力は ASCII のみ（Windows PowerShell 5.1 のコンソールで node の UTF-8 出力が化けるため）。
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function usage(msg) {
  console.error('stage-global-runtime: ' + msg);
  process.exit(2);
}

const argv = process.argv.slice(2);
const opts = {};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a.startsWith('--')) { opts[a.slice(2)] = argv[++i]; continue; }
  usage('unexpected argument: ' + a);
}
const osName = opts.os;
if (osName !== 'macos' && osName !== 'windows') usage('--os must be macos or windows');
if (!opts['guard-src']) usage('--guard-src is required');

function homeDir() { return process.env.HOME || process.env.USERPROFILE || '.'; }

const ext = osName === 'windows' ? 'ps1' : 'sh';
const guardSrc = path.resolve(opts['guard-src']);
const base = path.resolve(guardSrc, '..', '..');
const commonSrc = path.resolve(guardSrc, '..', 'common');
const policySrc = path.join(base, 'policy', 'safety-policy.json');
// 作業フォルダの並び (<ws>/.ai-safety/cards) と、配布物の並び (<pkg>/configs/safety/cards) の両方に対応。
const cardsSrc = [path.join(base, 'cards'), path.join(base, 'configs', 'safety', 'cards')]
  .find((p) => isDir(p)) || null;
const dest = path.resolve(opts.dest || path.join(homeDir(), '.ai-safety', 'global'));

// hook が呼ぶガード（apply-global-{guard,codex,agy}.js が参照する名前と一致させる）と、
// ガードが相対パスで読み込むライブラリ。どれか 1 つでも欠けた一式は置き場に出さない。
const REQUIRED = [
  ...['guard-prompt', 'guard-bash', 'guard-write', 'guard-webfetch', 'guard-post-output']
    .map((g) => path.join('hooks', osName, g + '.' + ext)),
  ...(osName === 'windows'
    ? [path.join('hooks', 'windows', 'lib', 'SafetyPolicy.ps1'), path.join('hooks', 'windows', 'lib', 'Explainer.ps1')]
    : [path.join('hooks', 'macos', 'lib', 'safety_policy.sh'), path.join('hooks', 'macos', 'lib', 'explainer.sh'),
      path.join('hooks', 'common', 'plutil-p.js')]),
  path.join('hooks', 'common', 'command-judge.js'),
  path.join('hooks', 'common', 'answer-snapshot.js'),
  path.join('policy', 'safety-policy.json'),
];

function isDir(p) { try { return fs.statSync(p).isDirectory(); } catch (_) { return false; } }
function isFile(p) { try { return fs.statSync(p).isFile(); } catch (_) { return false; } }
function sha256(p) { return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex'); }

function sleepMs(ms) {
  try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch (_) { /* busy wait は避ける */ }
}

// Windows はウイルス対策ソフトやエクスプローラーが一瞬ファイルを掴んでいると rename が
// EPERM / EACCES / EBUSY で失敗する。短い間隔で数回やり直す。
function renameWithRetry(from, to) {
  let lastErr = null;
  for (let i = 0; i < 10; i++) {
    try { fs.renameSync(from, to); return; } catch (e) {
      lastErr = e;
      if (!['EPERM', 'EACCES', 'EBUSY', 'ENOTEMPTY', 'EEXIST'].includes(e.code)) break;
      sleepMs(100);
    }
  }
  throw lastErr;
}

function rmQuiet(p) {
  try { fs.rmSync(p, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 }); } catch (_) {}
}

// シンボリックリンクは辿らず、持ち込まない（置き場の外を指す仕掛けを作らせない）。
function copyTree(src, dst, skipDirs) {
  fs.mkdirSync(dst, { recursive: true });
  for (const ent of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, ent.name);
    const d = path.join(dst, ent.name);
    if (ent.isSymbolicLink()) continue;
    if (ent.isDirectory()) {
      if (skipDirs && skipDirs.has(ent.name)) continue;
      copyTree(s, d, skipDirs);
    } else if (ent.isFile()) {
      fs.copyFileSync(s, d);
    }
  }
}

function listFiles(root) {
  const out = [];
  const stack = [root];
  while (stack.length) {
    const cur = stack.pop();
    for (const ent of fs.readdirSync(cur, { withFileTypes: true })) {
      const full = path.join(cur, ent.name);
      if (ent.isDirectory()) stack.push(full);
      else if (ent.isFile()) out.push(full);
    }
  }
  return out;
}

function missingIn(root) {
  return REQUIRED.filter((rel) => !isFile(path.join(root, rel)));
}

function packageVersion(policyPath) {
  try { return String(JSON.parse(fs.readFileSync(policyPath, 'utf8')).packageVersion || ''); } catch (_) { return ''; }
}

// 置き場そのもの（またはその中）から呼ばれたら、作り直す元が無い。今ある一式を確かめるだけ。
function isInside(child, parent) {
  const rel = path.relative(parent, child);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

function keepExisting(reason) {
  const missing = isDir(dest) ? missingIn(dest) : REQUIRED.slice();
  if (missing.length === 0) {
    console.error('stage-global-runtime: WARN could not refresh (' + reason + '); keeping the previous complete runtime: ' + dest);
    process.exit(0);
  }
  console.error('stage-global-runtime: ERROR ' + reason + '; no usable runtime at ' + dest);
  process.exit(1);
}

function main() {
  if (isInside(guardSrc, dest)) {
    const missing = missingIn(dest);
    if (missing.length) { console.error('stage-global-runtime: ERROR runtime incomplete: ' + missing.join(', ')); process.exit(1); }
    console.log('runtime       : ' + dest + ' (already the source; nothing to refresh)');
    return;
  }
  if (!isDir(guardSrc)) keepExisting('guard source not found: ' + guardSrc);
  if (!isDir(path.join(guardSrc, 'lib'))) keepExisting('guard lib not found: ' + path.join(guardSrc, 'lib'));
  if (!isDir(commonSrc)) keepExisting('common scripts not found: ' + commonSrc);
  if (!isFile(policySrc)) keepExisting('policy not found: ' + policySrc);

  const parent = path.dirname(dest);
  const leaf = path.basename(dest);
  fs.mkdirSync(parent, { recursive: true });

  // 前回の実行が途中で止まったときの残骸（一時フォルダ・退避フォルダ）を片付ける。
  for (const name of fs.readdirSync(parent)) {
    if (name.startsWith(leaf + '.staging-') || name.startsWith(leaf + '.old-')) rmQuiet(path.join(parent, name));
  }

  const tag = process.pid + '-' + Date.now();
  const tmp = path.join(parent, leaf + '.staging-' + tag);
  try {
    // 1) ガード本体（guard-*.<ext>）と lib/ だけを持ち込む。ランチャーや診断は持ち込まない
    //    （ここは hook 専用の置き場。作業フォルダの場所を前提にするスクリプトを置かない）。
    const hooksDst = path.join(tmp, 'hooks', osName);
    fs.mkdirSync(hooksDst, { recursive: true });
    const guardRe = new RegExp('^guard-[A-Za-z0-9_-]+\\.' + ext + '$');
    for (const ent of fs.readdirSync(guardSrc, { withFileTypes: true })) {
      if (ent.isFile() && guardRe.test(ent.name)) fs.copyFileSync(path.join(guardSrc, ent.name), path.join(hooksDst, ent.name));
    }
    copyTree(path.join(guardSrc, 'lib'), path.join(hooksDst, 'lib'), new Set(['test']));
    // 2) 共通の Node 部品。テストと画像素材（見守りモニター用）は要らない。
    copyTree(commonSrc, path.join(tmp, 'hooks', 'common'), new Set(['test', 'assets', 'node_modules']));
    // 3) 同梱ポリシーと解説カード
    fs.mkdirSync(path.join(tmp, 'policy'), { recursive: true });
    fs.copyFileSync(policySrc, path.join(tmp, 'policy', 'safety-policy.json'));
    if (cardsSrc) copyTree(cardsSrc, path.join(tmp, 'cards'), null);

    // 4) mac はガードとライブラリに実行権が要る（hook は [ -x ] で存在を確かめる）。
    if (osName === 'macos') {
      for (const f of listFiles(path.join(tmp, 'hooks', 'macos'))) {
        if (f.endsWith('.sh')) fs.chmodSync(f, 0o755);
      }
    }

    // 5) 見つけた人向けの説明と、どの版から作ったかの記録。
    fs.writeFileSync(path.join(tmp, 'README.txt'), [
      'This folder is the safety guard runtime used by the PC-wide safety settings',
      '(~/.claude/settings.json, ~/.codex/hooks.json, ~/.gemini/settings.json).',
      'It is rebuilt every time the AI Safety package is installed or updated.',
      'Do not edit or delete it. To turn the PC-wide settings off, run',
      'Start > キーと金庫 > 13_PC全体の安全設定を解除.',
      '',
      'このフォルダは「PC 全体の安全設定」が使う安全ガードの本体です。',
      '安全パッケージを導入・更新するたびに作り直されます。中身を変えたり消したりしないでください。',
      'PC 全体の安全設定をやめたいときは、スタートの「キーと金庫/13_PC全体の安全設定を解除」を使ってください。',
      '',
    ].join('\n'), 'utf8');
    fs.writeFileSync(path.join(tmp, 'runtime.json'), JSON.stringify({
      packageVersion: packageVersion(policySrc),
      os: osName,
      stagedAt: new Date().toISOString(),
      source: guardSrc,
    }, null, 2) + '\n', 'utf8');

    // 6) 確かめる: 必要なファイルがそろっていて、ガード・ライブラリ・ポリシーが元と同じバイト列か。
    const missing = missingIn(tmp);
    if (missing.length) throw new Error('staged runtime is incomplete: ' + missing.join(', '));
    const pairs = [[policySrc, path.join(tmp, 'policy', 'safety-policy.json')]];
    for (const f of listFiles(hooksDst)) {
      const rel = path.relative(hooksDst, f);
      pairs.push([path.join(guardSrc, rel), f]);
    }
    for (const [s, d] of pairs) {
      if (sha256(s) !== sha256(d)) throw new Error('copy mismatch: ' + path.relative(tmp, d));
    }
  } catch (e) {
    rmQuiet(tmp);
    keepExisting(e.message);
  }

  // 7) 入れ替え。旧一式を退避 → 新一式を正式名へ。2 回目が失敗したら旧一式を戻す。
  let old = null;
  try {
    if (fs.existsSync(dest)) {
      old = path.join(parent, leaf + '.old-' + tag);
      renameWithRetry(dest, old);
    }
    renameWithRetry(tmp, dest);
  } catch (e) {
    if (old && !fs.existsSync(dest)) {
      try { renameWithRetry(old, dest); old = null; } catch (_) {}
    }
    rmQuiet(tmp);
    keepExisting('could not swap in the new runtime (' + (e.code || e.message) + ')');
  }
  if (old) rmQuiet(old);

  console.log('runtime       : ' + dest + ' (refreshed from ' + guardSrc + ')');
}

main();
