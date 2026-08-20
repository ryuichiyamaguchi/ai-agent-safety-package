#!/usr/bin/env node
// clipboard-mask.js — コピーした文章から秘密を伏せる / 伏せた文章を元に戻す。
//
// なぜ作り直したか:
//   旧 clipboard-safe-paste.{sh,ps1} はボタンが無く、ターミナルで長いパスを打つ必要があり、
//   しかもそのコマンド文字列に「.ai-safety」が含まれるため保護パス判定に自分で引っかかっていた。
//   スタートフォルダのボタン2つ（伏せる / 元に戻す）から呼ぶ形に作り直す。
//
// 復元が成立する仕組み:
//   - 伏せるときは、可逆カテゴリ（メールアドレス・電話番号・郵便番号・自分で登録した語）を
//     安定したトークン __SECRET_1__ … に置き換え、「トークン ↔ 原文」の対応表を保存する。
//   - 元に戻すときは、クリップボード（＝AI の返答）の中のトークンを原文に戻す。
//   - 対応表には本物の秘密が入るので平文ファイルには置かない。
//     OS 標準の金庫（macOS キーチェーン / Windows DPAPI）に入れる（secret-store.js）。
//   - 対応表は既定 60 分で自動的に破棄する（AI_SAFE_MASK_TTL_MIN で変更可）。
//     期限切れの対応表は復元時に「期限切れです」と案内して捨てる。
//
// API キー等のハードな秘密は「復元できないマスク」[MASKED:...] にする。
//   AI の返答に本物の API キーが戻ってくる必要は無く、戻せる仕組みにする方が危ないため。
//
// 使い方:
//   node clipboard-mask.js --mask      クリップボードを伏せて書き戻す
//   node clipboard-mask.js --restore   クリップボードのトークンを原文に戻して書き戻す
//   node clipboard-mask.js --clear     対応表を今すぐ捨てる
'use strict';

const { spawnSync } = require('node:child_process');
const store = require('./secret-store.js');
const { maskText } = require('./secret-patterns.js');
const { loadDenylist } = require('./denylist.js');

const TOKEN_RE = /__SECRET_(\d+)__/g;
const DEFAULT_TTL_MIN = 60;

// 「知っているパターンしか伏せられない」ことは必ず毎回1行出す（実行時出力の必須要件）。
const LIMIT_LINE =
  '※ このツールは「知っている形」しか伏せられません。伏せられたから安全、ではありません。' +
  '貼り付ける前に、自分の目で本文を必ず読み直してください。';

function ttlMs() {
  const m = Number(process.env.AI_SAFE_MASK_TTL_MIN);
  return (Number.isFinite(m) && m > 0 ? m : DEFAULT_TTL_MIN) * 60 * 1000;
}

// ---- クリップボード -------------------------------------------------------
function clipboardRead() {
  if (process.platform === 'darwin') {
    const r = spawnSync('/usr/bin/pbpaste', [], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
    return r.status === 0 ? r.stdout : null;
  }
  if (process.platform === 'win32') {
    const r = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', 'Get-Clipboard -Raw'],
      { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
    return r.status === 0 ? r.stdout.replace(/\r\n$/, '') : null;
  }
  return null;
}

function clipboardWrite(text) {
  if (process.platform === 'darwin') {
    return spawnSync('/usr/bin/pbcopy', [], { input: text, encoding: 'utf8' }).status === 0;
  }
  if (process.platform === 'win32') {
    // 値をコマンド文字列に埋めない（長文・引用符・改行で壊れるため標準入力から渡す）。
    const script = '$t=[Console]::In.ReadToEnd(); Set-Clipboard -Value $t';
    return spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', script],
      { input: text, encoding: 'utf8' }).status === 0;
  }
  return false;
}

// ---- 対応表（有効期限つき） ------------------------------------------------
//
// 保管方式は「封筒方式」:
//   ・対応表そのものは AES-256-GCM で暗号化して ~/.ai-safety/mask-map.enc（権限 600）に置く
//   ・それを開ける鍵（32 バイトの乱数）だけを OS の金庫に入れる（項目名 ai-safety.maskmap）
//   ・金庫の項目を消せば、残ったファイルはただの読めない塊になる
//
// なぜ対応表そのものを金庫に入れないか（実測に基づく）:
//   macOS の `security add-generic-password ... -w` は対話プロンプト経由で値を読むため、
//   128 文字で黙って切り捨てられる。対応表は数 KB になるので必ず壊れる。鍵をコマンドライン
//   引数に書く（-w <値>）のは ps で他ユーザーに見えるので採らない。よって「短い鍵だけを金庫に、
//   本体は暗号化して隣に」という形にした。平文でディスクに置かないという要件は満たしている。
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function mapFile() {
  const dir = process.env.AI_SAFE_SECRET_DIR || path.join(os.homedir(), '.ai-safety');
  return path.join(dir, 'mask-map.enc');
}

function mapKey({ create = false } = {}) {
  let b64 = null;
  try { b64 = store.get('maskmap'); } catch { b64 = null; }
  if (b64) {
    try {
      const key = Buffer.from(b64, 'base64');
      if (key.length === 32) return key;
    } catch { /* 壊れていたら作り直す */ }
  }
  if (!create) return null;
  const key = crypto.randomBytes(32);
  store.set('maskmap', key.toString('base64'));
  return key;
}

function loadMap() {
  const file = mapFile();
  if (!fs.existsSync(file)) return null;
  const key = mapKey();
  if (!key) return null;
  let data;
  try {
    const blob = fs.readFileSync(file);
    const iv = blob.subarray(0, 12);
    const tag = blob.subarray(12, 28);
    const body = blob.subarray(28);
    const d = crypto.createDecipheriv('aes-256-gcm', key, iv);
    d.setAuthTag(tag);
    data = JSON.parse(Buffer.concat([d.update(body), d.final()]).toString('utf8'));
  } catch { return null; }
  if (!data || typeof data !== 'object' || !data.entries) return null;
  if (!(Number(data.expiresAt) > Date.now())) return { expired: true };
  return { seq: Number(data.seq) || 0, entries: data.entries };
}

function saveMap(map) {
  const key = mapKey({ create: true });
  const payload = JSON.stringify({
    v: 1,
    seq: map.seq,
    savedAt: Date.now(),
    expiresAt: Date.now() + ttlMs(),
    entries: map.entries,
  });
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', key, iv);
  const body = Buffer.concat([c.update(payload, 'utf8'), c.final()]);
  const file = mapFile();
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, Buffer.concat([iv, c.getAuthTag(), body]), { mode: 0o600 });
  try { fs.chmodSync(file, 0o600); } catch { /* best effort */ }
}

function clearMap() {
  let ok = false;
  try { ok = store.remove('maskmap'); } catch { ok = false; }
  try { fs.rmSync(mapFile(), { force: true }); } catch { /* best effort */ }
  return ok;
}

// ---- マスク ---------------------------------------------------------------
function doMask() {
  const raw = clipboardRead();
  if (raw === null) { console.error('クリップボードを読めませんでした。'); return 2; }
  if (!raw.trim()) { console.error('クリップボードが空です。先に文章をコピーしてください。'); return 1; }

  if (!store.available()) {
    console.error('この PC では OS の金庫を使えないため、元に戻すための対応表を安全に保管できません。');
    console.error('対応表を平文ファイルに書くことはしません（秘密がそのまま残るため）。マスキングを中止します。');
    return 2;
  }

  // 期限内の対応表があれば引き継ぐ（同じ原文には同じトークンを割り当てる）。
  const prev = loadMap();
  const carried = (prev && !prev.expired) ? prev : { seq: 0, entries: {} };
  const byValue = new Map(Object.entries(carried.entries).map(([tok, val]) => [val, tok]));
  let seq = carried.seq;
  const entries = Object.assign({}, carried.entries);

  const alloc = (value) => {
    const v = String(value);
    if (byValue.has(v)) return byValue.get(v);
    seq += 1;
    const token = `__SECRET_${seq}__`;
    byValue.set(v, token);
    entries[token] = v;
    return token;
  };

  const { masked, counts } = maskText(raw, {
    alloc,
    denylistTerms: loadDenylist(),
    pii: 'strict',
  });

  if (!clipboardWrite(masked)) { console.error('クリップボードに書き戻せませんでした。'); return 2; }

  const reversible = seq - carried.seq;
  const irreversible = counts.total - reversible;
  saveMap({ seq, entries });

  console.log('');
  console.log(` 伏せました。クリップボードは伏せ字入りの文章に置き換わっています（そのまま貼り付けてください）。`);
  console.log(`   ・元に戻せる伏せ字（__SECRET_1__ の形）: ${reversible} 件`);
  console.log(`   ・元に戻さない伏せ字（[MASKED:…] の形、API キー等）: ${irreversible >= 0 ? irreversible : 0} 件`);
  console.log(`   ・対応表は OS の金庫に入れました。${Math.round(ttlMs() / 60000)} 分で自動的に捨てます。`);
  console.log(` AI の返答をコピーしてから「伏せた文章を元に戻す」を押すと、__SECRET_… が元の文字に戻ります。`);
  console.log('');
  console.log(LIMIT_LINE);
  return 0;
}

// ---- 復元 -----------------------------------------------------------------
function doRestore() {
  const raw = clipboardRead();
  if (raw === null) { console.error('クリップボードを読めませんでした。'); return 2; }
  if (!raw.trim()) { console.error('クリップボードが空です。先に AI の返答をコピーしてください。'); return 1; }

  const map = loadMap();
  if (map && map.expired) {
    clearMap();
    console.log('');
    console.log(' 対応表は期限切れです（作業のあとに残さないよう、時間で自動的に捨てています）。');
    console.log(' もう一度「コピーした文章から秘密を伏せる」からやり直してください。');
    console.log('');
    console.log(LIMIT_LINE);
    return 1;
  }
  if (!map) {
    console.log('');
    console.log(' 対応表が見つかりませんでした。先に「コピーした文章から秘密を伏せる」を実行してください。');
    console.log('');
    console.log(LIMIT_LINE);
    return 1;
  }

  let restored = 0;
  let unknown = 0;
  TOKEN_RE.lastIndex = 0;
  const out = raw.replace(TOKEN_RE, (m) => {
    if (Object.prototype.hasOwnProperty.call(map.entries, m)) { restored += 1; return map.entries[m]; }
    unknown += 1;
    return m;
  });

  if (!clipboardWrite(out)) { console.error('クリップボードに書き戻せませんでした。'); return 2; }

  console.log('');
  console.log(` 元に戻しました。クリップボードは復元済みの文章に置き換わっています。`);
  console.log(`   ・戻した伏せ字: ${restored} 件`);
  if (unknown) console.log(`   ・対応表に無い伏せ字（戻せませんでした）: ${unknown} 件`);
  if (!restored && !unknown) console.log('   ・伏せ字は見つかりませんでした（__SECRET_… を含む文章をコピーしてください）。');
  console.log('');
  console.log(LIMIT_LINE);
  return 0;
}

module.exports = { doMask, doRestore, clearMap, loadMap, saveMap, TOKEN_RE, LIMIT_LINE, ttlMs };

if (require.main === module) {
  const args = process.argv.slice(2);
  let code = 0;
  if (args.includes('--restore')) code = doRestore();
  else if (args.includes('--clear')) { clearMap(); console.log(' 対応表を捨てました。'); }
  else code = doMask();
  process.exit(code);
}
