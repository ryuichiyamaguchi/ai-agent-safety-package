// denylist.js — ユーザー個別マスク語の読み込み（1行1語・# コメント・空行無視）
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function defaultDenylistPath() {
  const dir = process.env.AI_SAFE_LOG_DIR
    ? path.dirname(process.env.AI_SAFE_LOG_DIR) // logs の親 = .ai-safety
    : path.join(os.homedir(), '.ai-safety');
  return path.join(dir, 'denylist.txt');
}

function parseTerms(raw) {
  return raw.split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#'));
}

// 後方互換: 読めなければ常に []（secret-patterns 等の従来呼び出し用）。
// fail-closed 判定が必要な gateway 経路では loadDenylistResult を使うこと。
function loadDenylist(file = defaultDenylistPath()) {
  let raw;
  try { raw = fs.readFileSync(file, 'utf8'); } catch (_) { return []; }
  return parseTerms(raw);
}

// F-4: 「denylist が設定されている（パス指定あり）のに読めない」= fail-closed、
// 「未設定（そもそも無い）」= [] 正常、の 2 状態を区別する。
//   configured=true もしくは DENYLIST_PATH が設定されている → 読めなければ fail-closed sentinel を返す。
//   未設定 かつ デフォルトパスが存在しない（ENOENT） → [] を返す（正常）。
// 返り値: 語句配列 string[] | { failClosed: true, reason: string }
function loadDenylistResult(file, opts = {}) {
  const envPath = process.env.DENYLIST_PATH;
  const configured = opts.configured === true || (file !== undefined) || (envPath !== undefined && envPath !== '');
  const target = file !== undefined ? file : (envPath || defaultDenylistPath());
  let raw;
  try {
    raw = fs.readFileSync(target, 'utf8');
  } catch (e) {
    // 「設定なし」かつ「ファイルが存在しない」だけが正常な [] 扱い。
    if (!configured && e && e.code === 'ENOENT') return [];
    return { failClosed: true, reason: `denylist configured but unreadable: ${e && e.message ? e.message : e}` };
  }
  return parseTerms(raw);
}

module.exports = { loadDenylist, loadDenylistResult, defaultDenylistPath };
