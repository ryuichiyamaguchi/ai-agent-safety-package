#!/usr/bin/env node
'use strict';
// apply-global-agy.js — この PC の agy (Gemini CLI) 全体設定 (~/.gemini/settings.json) に、
// guard スクリプトの「絶対パス」を指す hooks を配線する。
//
// 目的: 素の `agy` / `gemini` をホームディレクトリなど作業フォルダの外で起動しても、
//       rm -r / cat .env / curl|sh / 外部送信 が guard 層で止まるようにする。
//       パッケージの configs/gemini/settings.mac.json と同じ hook 構成だが、
//       あちらはワークスペース相対パス（.ai-safety/hooks/...）なので、そのまま
//       グローバルへ置くと「起動した cwd の直下」を見に行って発火しない。ここでは
//       絶対パスへ差し替える（guard 自身は自分の絶対位置からポリシーを自己解決する）。
//
//   入れる内容（グローバルに置いて害のないものだけ）:
//     hooksConfig.enabled = true
//     hooks.BeforeAgent            → guard-prompt
//     hooks.BeforeTool
//        run_shell_command         → guard-bash
//        write_file / replace      → guard-write
//        web_fetch                 → guard-webfetch
//     hooks.AfterModel/AfterAgent  → guard-post-output（出力側の秘密マスク）
//
//   入れないもの: モデル選択・テーマ・認証・MCP 等、受講者の好みや契約に属する設定。
//                 「安全に無関係な既存の好み」は 1 つも変えない。
//
// 既存の ~/.gemini/settings.json は壊さない（本パッケージ由来の hook を張り替えるだけ。
// 他のキーには一切触れない）。書込前に必ずバックアップし、取り消しは記録から復元する。
//
// Usage:
//   node apply-global-agy.js apply --target <settings.json> --os macos|windows
//                                  --guard-dir <abs guard dir> [--state <path>] [--dry-run]
//   node apply-global-agy.js uninstall --target <settings.json> [--state <path>] [--dry-run]
const fs = require('fs');
const path = require('path');
const state = require('./global-guard-state.js');

function fail(msg) { console.error('apply-global-agy: ' + msg); process.exit(2); }

const argv = process.argv.slice(2);
const mode = argv[0];
if (mode !== 'apply' && mode !== 'uninstall') fail('first arg must be "apply" or "uninstall"');
const opts = {};
for (let i = 1; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--dry-run') { opts.dryRun = true; continue; }
  if (a.startsWith('--')) { opts[a.slice(2)] = argv[++i]; continue; }
}
const statePath = opts.state || state.defaultStatePath();

// 本パッケージが足した hook の署名。~/.gemini/settings.json に現れる guard-*.{sh,ps1} 参照は
// すべて本パッケージ由来なので、これで idempotent に張り替えできる。
const GUARD_SIG = /guard-(prompt|bash|write|webfetch|observe|post-output)\.(sh|ps1)/;

// agy の hook は「1 本のコマンド文字列」。mac は絶対パスをそのまま、Windows は
// powershell.exe 経由で叩く。パスに空白があっても壊れないよう必ず引用する。
function hookCmd(os, guardDir, script) {
  if (os === 'windows') {
    const p = (guardDir.replace(/\//g, '\\').replace(/\\+$/, '')) + '\\' + script;
    return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + p + '"';
  }
  return '"' + path.posix.join(guardDir, script) + '"';
}

function buildAgyHooks(os, guardDir) {
  const ext = os === 'windows' ? 'ps1' : 'sh';
  const c = (script) => hookCmd(os, guardDir, script + '.' + ext);
  return {
    BeforeAgent: [{ command: c('guard-prompt') }],
    BeforeTool: [
      { toolName: 'run_shell_command', command: c('guard-bash') },
      { toolName: 'write_file', command: c('guard-write') },
      { toolName: 'replace', command: c('guard-write') },
      { toolName: 'web_fetch', command: c('guard-webfetch') },
    ],
    AfterModel: [{ command: c('guard-post-output') }],
    AfterAgent: [{ command: c('guard-post-output') }],
  };
}

function stripOurHooks(obj) {
  if (!obj.hooks || typeof obj.hooks !== 'object' || Array.isArray(obj.hooks)) return;
  for (const ev of Object.keys(obj.hooks)) {
    const entries = obj.hooks[ev];
    if (!Array.isArray(entries)) continue;
    const kept = entries.filter((e) => !GUARD_SIG.test(JSON.stringify(e)));
    if (kept.length) obj.hooks[ev] = kept; else delete obj.hooks[ev];
  }
  if (Object.keys(obj.hooks).length === 0) delete obj.hooks;
}

function doApply() {
  const tgtPath = opts.target, os = opts.os, guardDir = opts['guard-dir'];
  if (!tgtPath || !os || !guardDir) fail('apply requires --target --os --guard-dir');
  if (os !== 'macos' && os !== 'windows') fail('--os must be macos or windows');

  const existedBefore = fs.existsSync(tgtPath);
  let tgt = {};
  if (existedBefore) {
    const raw = fs.readFileSync(tgtPath, 'utf8');
    if (raw.trim().length) {
      try { tgt = JSON.parse(raw); }
      catch (e) {
        // 壊れた設定は触らない（上書きすると受講者の設定を失う）。案内して 3 で抜ける。
        console.error('既存の ' + tgtPath + ' が JSON として読めません（' + e.message + '）。');
        console.error('安全のため触らずにスキップしました。中身を直してから再実行してください。');
        process.exit(3);
      }
    }
  }
  if (typeof tgt !== 'object' || tgt === null || Array.isArray(tgt)) {
    console.error('既存の ' + tgtPath + ' が JSON オブジェクトではありません。触らずにスキップしました。');
    process.exit(3);
  }

  stripOurHooks(tgt);
  if (!tgt.hooksConfig || typeof tgt.hooksConfig !== 'object' || Array.isArray(tgt.hooksConfig)) tgt.hooksConfig = {};
  tgt.hooksConfig.enabled = true;
  if (!tgt.hooks || typeof tgt.hooks !== 'object' || Array.isArray(tgt.hooks)) tgt.hooks = {};
  const blocks = buildAgyHooks(os, guardDir);
  for (const ev of Object.keys(blocks)) {
    if (!Array.isArray(tgt.hooks[ev])) tgt.hooks[ev] = [];
    tgt.hooks[ev] = tgt.hooks[ev].concat(blocks[ev]);
  }

  console.log('target        : ' + tgtPath + (existedBefore ? '' : ' (new)'));
  console.log('hooks         : BeforeAgent / BeforeTool(run_shell_command,write_file,replace,web_fetch) / AfterModel / AfterAgent → ' + guardDir);

  if (opts.dryRun) { console.log('[dry-run] no file written'); return; }

  const st = state.loadState(statePath);
  if (!st.agy) {
    st.agy = {
      appliedAt: new Date().toISOString(), target: tgtPath, guardDir: guardDir, os: os,
      originalBackup: existedBefore ? state.backupFile(tgtPath, 'global-agy') : null,
      targetExistedBefore: existedBefore,
    };
  } else {
    st.agy.appliedAt = new Date().toISOString();
    st.agy.target = tgtPath;
    st.agy.guardDir = guardDir;
    st.agy.os = os;
  }

  fs.mkdirSync(path.dirname(tgtPath), { recursive: true });
  fs.writeFileSync(tgtPath, JSON.stringify(tgt, null, 2) + '\n', 'utf8');
  state.saveState(statePath, st);
  console.log('backup        : ' + (st.agy.originalBackup || '(none — target did not exist)'));
  console.log('written       : ' + tgtPath);
  console.log('state         : ' + statePath);
}

function doUninstall() {
  const st = state.loadState(statePath);
  const entry = st.agy;
  if (!entry) { console.log('agy グローバル適用の記録がありません(既に解除済み or 未適用)。'); return; }
  const tgtPath = opts.target || entry.target;
  if (!tgtPath) fail('uninstall requires --target or a recorded target in state');

  if (opts.dryRun) {
    console.log('[dry-run] would restore: ' + (entry.originalBackup || '(delete — target did not exist before)'));
    return;
  }
  if (fs.existsSync(tgtPath)) state.backupFile(tgtPath, 'global-agy-preundo');

  if (entry.originalBackup && fs.existsSync(entry.originalBackup)) {
    fs.copyFileSync(entry.originalBackup, tgtPath);
    console.log('restored      : ' + tgtPath + ' ← ' + entry.originalBackup);
  } else if (entry.targetExistedBefore === false) {
    if (fs.existsSync(tgtPath)) fs.unlinkSync(tgtPath);
    console.log('removed       : ' + tgtPath + ' (適用前は存在しなかったため削除)');
  } else {
    // バックアップが失われた場合の外科的フォールバック: 足した hook だけ取り除く。
    let tgt = {};
    try { tgt = JSON.parse(fs.readFileSync(tgtPath, 'utf8')); } catch (_) { tgt = {}; }
    stripOurHooks(tgt);
    fs.writeFileSync(tgtPath, JSON.stringify(tgt, null, 2) + '\n', 'utf8');
    console.log('surgically reverted (backup missing): ' + tgtPath);
  }

  delete st.agy;
  state.saveState(statePath, st);
  console.log('state         : ' + statePath + ' (agy entry removed)');
}

if (mode === 'apply') doApply(); else doUninstall();
