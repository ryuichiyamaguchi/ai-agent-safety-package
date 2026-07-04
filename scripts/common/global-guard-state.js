'use strict';
// global-guard-state.js — グローバル安全適用 (apply-global-guard / apply-global-codex) 共通の
// 状態ファイル + バックアップ + アトミック書込ヘルパ。
//
// 状態ファイル (~/.ai-safety/global-guard-state.json) は「本パッケージが ~/.claude/settings.json や
// ~/.codex/config.toml に何をしたか」を記録し、取り消し(uninstall)で確実に元へ戻すための SSOT。
// 形式:
//   {
//     "claude":       { "appliedAt": "...", "target": "...", "guardDir": "...",
//                       "originalBackup": "<abs>|null", "targetExistedBefore": true,
//                       "addedDeny": ["..."] },
//     "codexConfig":  { "appliedAt": "...", "target": "...", "originalBackup": "<abs>|null",
//                       "targetExistedBefore": true },
//     "codexHooks":   { ...同上... }
//   }
const fs = require('fs');
const path = require('path');

function homeDir() { return process.env.HOME || process.env.USERPROFILE || '.'; }

function defaultStatePath() {
  return path.join(homeDir(), '.ai-safety', 'global-guard-state.json');
}

function loadState(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (_) { return {}; }
}

function saveState(p, obj) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const prevUmask = process.umask(0o077);
  try {
    const tmp = p + '.tmp.' + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n', 'utf8');
    fs.renameSync(tmp, p);
    try { fs.chmodSync(p, 0o600); } catch (_) {}
  } finally {
    process.umask(prevUmask);
  }
}

function stamp() {
  const d = new Date();
  const p2 = (n) => String(n).padStart(2, '0');
  return '' + d.getFullYear() + p2(d.getMonth() + 1) + p2(d.getDate()) + '-' +
    p2(d.getHours()) + p2(d.getMinutes()) + p2(d.getSeconds());
}

// srcPath を ~/.ai-safety/backups/<label>-<stamp>/<basename> にコピーして絶対パスを返す。
// srcPath が無い場合は null。
function backupFile(srcPath, label) {
  if (!fs.existsSync(srcPath)) return null;
  const dir = path.join(homeDir(), '.ai-safety', 'backups', label + '-' + stamp());
  fs.mkdirSync(dir, { recursive: true });
  const dest = path.join(dir, path.basename(srcPath));
  fs.copyFileSync(srcPath, dest);
  try { fs.chmodSync(dest, 0o600); } catch (_) {}
  return dest;
}

module.exports = { homeDir, defaultStatePath, loadState, saveState, stamp, backupFile };
