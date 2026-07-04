#!/usr/bin/env node
// install-statusline.js — 軽量ステータスライン(statusline.mjs)を Claude 全体設定
// (~/.claude/settings.json) に登録/解除する。claude と d-claude の両方に効く(user source)。
// 既存設定は壊さず statusLine キーだけ差し替え、書込前にバックアップを取る。
//
// Usage:
//   node install-statusline.js install --target <settings.json> --script <abs statusline.mjs> --os macos|windows [--dry-run]
//   node install-statusline.js uninstall --target <settings.json> [--dry-run]
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

function fail(m) { console.error('install-statusline: ' + m); process.exit(2); }
const argv = process.argv.slice(2);
const mode = argv[0];
const opts = {};
for (let i = 1; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--dry-run') { opts.dryRun = true; continue; }
  if (a.startsWith('--')) { opts[a.slice(2)] = argv[++i]; }
}
if (mode !== 'install' && mode !== 'uninstall') fail('mode must be install|uninstall');
const target = opts.target;
if (!target) fail('--target required');

function readJson(p) {
  if (!fs.existsSync(p)) return {};
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (e) { fail('cannot parse target JSON (壊れた設定は上書きしない): ' + p + ' — ' + e.message); }
}
function backup(p) {
  if (!fs.existsSync(p)) return null;
  const d = new Date();
  const z = (n) => String(n).padStart(2, '0');
  const stamp = '' + d.getFullYear() + z(d.getMonth() + 1) + z(d.getDate()) + '-' + z(d.getHours()) + z(d.getMinutes()) + z(d.getSeconds());
  const dir = path.join(os.homedir(), '.ai-safety', 'backups', 'statusline-' + stamp);
  fs.mkdirSync(dir, { recursive: true });
  fs.copyFileSync(p, path.join(dir, 'settings.json'));
  return path.join(dir, 'settings.json');
}
function write(p, obj) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(obj, null, 2) + '\n', 'utf8');
}

function statusLineFor(scriptAbs, osName) {
  if (osName === 'windows') {
    // シンプルに node に絶対パスを渡すだけ。powershell ラッパーや $p/{}/| を使わないので、
    // Claude Code がどのシェル経由で実行しても入れ子クォートで壊れない。node が PATH に
    // 無ければ何も出ない（statusLine は失敗しても空表示になるだけで安全）。
    const cmd = 'node "' + scriptAbs + '"';
    return { type: 'command', command: cmd, padding: 0, refreshInterval: 10 };
  }
  // macos / unix: login shell(-l) で PATH を読み込んでから node を探す。
  const cmd = "/bin/bash -lc 'p=\"" + scriptAbs.replace(/"/g, '\\"') + '"; '
    + '[ -f "$p" ] && command -v node >/dev/null 2>&1 && node "$p"\'';
  return { type: 'command', command: cmd, padding: 0, refreshInterval: 5 };
}

const tgt = readJson(target);
if (typeof tgt !== 'object' || tgt === null || Array.isArray(tgt)) fail('target is not a JSON object');

if (mode === 'install') {
  const script = opts.script;
  const osName = opts.os === 'windows' ? 'windows' : 'macos';
  if (!script) fail('--script (abs path to statusline.mjs) required');
  tgt.statusLine = statusLineFor(script, osName);
  console.log('statusLine → ' + script + ' (' + osName + ')');
} else {
  if (Object.prototype.hasOwnProperty.call(tgt, 'statusLine')) { delete tgt.statusLine; console.log('statusLine を削除しました'); }
  else console.log('statusLine は設定されていません（何もしません）');
}

if (opts.dryRun) { console.log('[dry-run] no file written'); process.exit(0); }
const bak = backup(target);
if (bak) console.log('backup: ' + bak);
write(target, tgt);
console.log('written: ' + target);
