#!/usr/bin/env node
// apply-global-deny.js — パッケージの permissions.deny を、グローバル settings.json に
// union マージする（A案・宣言的 deny のみ）。既存の hooks / env / allow / ask など
// permissions.deny 以外のキーは一切変更しない。書き込み前に必ずバックアップを取る。
//
// Usage:
//   node apply-global-deny.js <source-settings.json> <target-settings.json> [--dry-run]
//     source = パッケージの configs/claude/settings.{mac,windows}.json（deny の SSOT）
//     target = 反映先（通常は ~/.claude/settings.json）
//
// 設計判断:
//   - deny は「既存 → パッケージ分の新規」の順で union（既存の並びを保ち、重複は足さない）。
//   - target が無ければ {} から作る（permissions.deny だけを持つ最小 settings を書く）。
//   - target のパースに失敗したら中断（壊れた設定を上書きしない）。
'use strict';
const fs = require('fs');
const path = require('path');

function fail(msg) { console.error('apply-global-deny: ' + msg); process.exit(2); }

const argv = process.argv.slice(2);
const dryRun = argv.includes('--dry-run');
const positional = argv.filter((a) => a !== '--dry-run');
const srcPath = positional[0];
const tgtPath = positional[1];
if (!srcPath || !tgtPath) {
  fail('Usage: node apply-global-deny.js <source-settings.json> <target-settings.json> [--dry-run]');
}

function readJson(p, fallback) {
  if (!fs.existsSync(p)) {
    if (fallback !== undefined) return fallback;
    fail('file not found: ' + p);
  }
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (e) {
    if (fallback !== undefined) return fallback;
    fail('cannot parse JSON: ' + p + ' — ' + e.message);
  }
}

const src = readJson(srcPath);
const srcDeny = (src.permissions && Array.isArray(src.permissions.deny)) ? src.permissions.deny : [];
if (srcDeny.length === 0) fail('source has no permissions.deny: ' + srcPath);

// target は「存在すれば読む・壊れていれば中断」。存在しなければ空 {} から。
const tgt = fs.existsSync(tgtPath) ? readJson(tgtPath) : {};
if (typeof tgt !== 'object' || tgt === null || Array.isArray(tgt)) fail('target is not a JSON object: ' + tgtPath);

const existingDeny = (tgt.permissions && Array.isArray(tgt.permissions.deny)) ? tgt.permissions.deny : [];
const seen = new Set(existingDeny);
const added = [];
for (const d of srcDeny) { if (!seen.has(d)) { seen.add(d); added.push(d); } }
const mergedDeny = existingDeny.concat(added);

if (!tgt.permissions || typeof tgt.permissions !== 'object' || Array.isArray(tgt.permissions)) tgt.permissions = {};
tgt.permissions.deny = mergedDeny;

console.log('target        : ' + tgtPath);
console.log('existing deny : ' + existingDeny.length);
console.log('package deny  : ' + srcDeny.length);
console.log('newly added   : ' + added.length);
if (added.length) console.log('added:\n  ' + added.join('\n  '));

if (dryRun) { console.log('[dry-run] no file written'); process.exit(0); }

// バックアップ（既存 target があるときだけ）
if (fs.existsSync(tgtPath)) {
  const d = new Date();
  const p2 = (n) => String(n).padStart(2, '0');
  const stamp = '' + d.getFullYear() + p2(d.getMonth() + 1) + p2(d.getDate()) + '-' + p2(d.getHours()) + p2(d.getMinutes()) + p2(d.getSeconds());
  const home = process.env.HOME || process.env.USERPROFILE || '.';
  const bakDir = path.join(home, '.ai-safety', 'backups', 'global-claude-' + stamp);
  fs.mkdirSync(bakDir, { recursive: true });
  fs.copyFileSync(tgtPath, path.join(bakDir, 'settings.json'));
  console.log('backup        : ' + path.join(bakDir, 'settings.json'));
}

fs.mkdirSync(path.dirname(tgtPath), { recursive: true });
fs.writeFileSync(tgtPath, JSON.stringify(tgt, null, 2) + '\n', 'utf8');
console.log('written       : ' + tgtPath + ' (deny total ' + mergedDeny.length + ')');
