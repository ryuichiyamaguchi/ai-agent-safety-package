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

// ---- 解除（uninstall）で「適用後の変更」を消さないための道具 -------------------------
// PC 全体の安全設定は導入・更新のたびに自動で入る（v1.19.x〜）。入れてから解除するまでに
// 何か月も空くことがあり、そのあいだに Claude Code / Codex / Gemini 自身や利用者が同じ
// 設定ファイルへ書き足す（Codex のフォルダ信頼・モデル選択・MCP サーバーなど）。
// 解除でバックアップを丸ごと書き戻すと、それらが消えてしまう。
// そこで apply は「最後に自分が書いた中身」の SHA-256 を記録し、uninstall は
//   - 中身がそのまま → 従来どおりバックアップから完全に戻す（バイト単位で元どおり）
//   - 変わっている   → このパッケージが足した分だけを取り除く（他の変更は残す）
// と使い分ける。記録が無い古い状態ファイルは従来どおり（バックアップから戻す）。
const crypto = require('crypto');

function sha256Text(text) {
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex');
}

function sha256File(p) {
  try { return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex'); }
  catch (_) { return null; }
}

// 記録した「最後に書いた中身」から変わっていれば true。記録が無い・ファイルが無いときは false。
function changedSinceApply(p, writtenSha256) {
  if (!writtenSha256 || !fs.existsSync(p)) return false;
  return sha256File(p) !== writtenSha256;
}

function readJsonOrNull(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (_) { return null; }
}

function isPlainObject(v) { return !!v && typeof v === 'object' && !Array.isArray(v); }

module.exports = {
  homeDir, defaultStatePath, loadState, saveState, stamp, backupFile,
  sha256Text, sha256File, changedSinceApply, readJsonOrNull, isPlainObject,
};
