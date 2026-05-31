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

function loadDenylist(file = defaultDenylistPath()) {
  let raw;
  try { raw = fs.readFileSync(file, 'utf8'); } catch (_) { return []; }
  return raw.split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#'));
}
module.exports = { loadDenylist, defaultDenylistPath };
