#!/usr/bin/env node
'use strict';
// apply-global-guard.js — この PC の Claude 全体設定 (~/.claude/settings.json) に、
//   (a) パッケージの permissions.deny を union し、さらに
//   (b) guard スクリプトの「絶対パス」を指す hooks ブロック
//       (UserPromptSubmit→guard-prompt / PreToolUse: Bash→guard-bash, Write系→guard-write,
//        WebFetch→guard-webfetch) を追加する。
// 目的: どのフォルダから claude を起動しても、強化した guard(rm -r / cat .env / curl|sh …)が
//       確実に発火する。guard は自分の絶対位置からポリシー(<ws>/.ai-safety/policy/…)を自己解決するため、
//       グローバル hook でも cwd に依存せず効く。
//
// 既存の env / allow / ask / 既存 hooks は壊さない(union / 追記のみ)。書込前に必ずバックアップし、
// 何を足したかを状態ファイルに記録する(取り消しで確実に元へ戻すため)。
//
// Usage:
//   node apply-global-guard.js apply --source <settings.json> --target <settings.json>
//                                    --os macos|windows --guard-dir <abs guard dir> [--state <path>] [--dry-run]
//   node apply-global-guard.js uninstall --target <settings.json> [--state <path>] [--dry-run]
const fs = require('fs');
const path = require('path');
const state = require('./global-guard-state.js');

function fail(msg) { console.error('apply-global-guard: ' + msg); process.exit(2); }

// ---- args ----------------------------------------------------------------
const argv = process.argv.slice(2);
const mode = argv[0];
if (mode !== 'apply' && mode !== 'uninstall') {
  fail('first arg must be "apply" or "uninstall"');
}
const opts = {};
for (let i = 1; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--dry-run') { opts.dryRun = true; continue; }
  if (a.startsWith('--')) { opts[a.slice(2)] = argv[++i]; continue; }
}
const statePath = opts.state || state.defaultStatePath();

// ---- helpers -------------------------------------------------------------
function readJson(p, fallback) {
  if (!fs.existsSync(p)) return fallback;
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (e) { fail('cannot parse JSON: ' + p + ' — ' + e.message); }
}

// 本パッケージが足した guard hook の署名。global settings に現れる guard-*.{sh,ps1} 参照は
// すべて本パッケージ由来(プロジェクト設定は別ファイル)なので、これで idempotent 除去できる。
const GUARD_SIG = /guard-(prompt|bash|write|webfetch|observe|post-output)\.(sh|ps1)/;

// 指定 event 群から「本パッケージの guard を参照する hook グループ」を取り除く。
function stripOurHooks(tgt) {
  if (!tgt.hooks || typeof tgt.hooks !== 'object') return;
  for (const ev of Object.keys(tgt.hooks)) {
    const groups = tgt.hooks[ev];
    if (!Array.isArray(groups)) continue;
    const kept = groups.filter((g) => !GUARD_SIG.test(JSON.stringify(g)));
    if (kept.length) tgt.hooks[ev] = kept;
    else delete tgt.hooks[ev];
  }
  if (Object.keys(tgt.hooks).length === 0) delete tgt.hooks;
}

function macHook(guardDir, script) {
  const p = path.posix.join(guardDir, script);
  return {
    type: 'command',
    command: '/bin/bash',
    args: ['-lc', 'p="' + p + '"; if [ ! -x "$p" ]; then echo "AI Safety hook missing: $p" >&2; exit 2; fi; "$p"'],
  };
}

function winHook(guardDir, script) {
  // guardDir は Windows 絶対パス(バックスラッシュ)。PowerShell 単一引用符内は ' を '' でエスケープ。
  const p = (guardDir.replace(/\//g, '\\').replace(/\\+$/, '')) + '\\' + script;
  const pEsc = p.replace(/'/g, "''");
  const cmd = "try { $p = '" + pEsc + "'; if (!(Test-Path -LiteralPath $p)) { throw ('AI Safety hook missing: ' + $p) }; & $p; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }";
  return {
    type: 'command',
    command: 'powershell.exe',
    args: ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', cmd],
  };
}

// os 別に、絶対パス guard を指す hooks ブロックを組み立てる。
function buildHooks(os, guardDir) {
  const isWin = os === 'windows';
  const mk = isWin ? winHook : macHook;
  const ext = isWin ? 'ps1' : 'sh';
  return {
    UserPromptSubmit: [{ hooks: [mk(guardDir, 'guard-prompt.' + ext)] }],
    PreToolUse: [
      { matcher: 'Bash|PowerShell', hooks: [mk(guardDir, 'guard-bash.' + ext)] },
      { matcher: 'Write|Edit|MultiEdit|NotebookEdit', hooks: [mk(guardDir, 'guard-write.' + ext)] },
      { matcher: 'WebFetch', hooks: [mk(guardDir, 'guard-webfetch.' + ext)] },
    ],
  };
}

function mergeHooks(tgt, blocks) {
  if (!tgt.hooks || typeof tgt.hooks !== 'object' || Array.isArray(tgt.hooks)) tgt.hooks = {};
  for (const ev of Object.keys(blocks)) {
    if (!Array.isArray(tgt.hooks[ev])) tgt.hooks[ev] = [];
    tgt.hooks[ev] = tgt.hooks[ev].concat(blocks[ev]);
  }
}

// ---- apply ---------------------------------------------------------------
function doApply() {
  const src = opts.source, tgtPath = opts.target, os = opts.os, guardDir = opts['guard-dir'];
  if (!src || !tgtPath || !os || !guardDir) {
    fail('apply requires --source --target --os --guard-dir');
  }
  if (os !== 'macos' && os !== 'windows') fail('--os must be macos or windows');

  const srcObj = readJson(src, null);
  if (!srcObj) fail('source not found or unreadable: ' + src);
  const srcDeny = (srcObj.permissions && Array.isArray(srcObj.permissions.deny)) ? srcObj.permissions.deny : [];
  if (srcDeny.length === 0) fail('source has no permissions.deny: ' + src);

  const targetExistedBefore = fs.existsSync(tgtPath);
  const tgt = readJson(tgtPath, {});
  if (typeof tgt !== 'object' || tgt === null || Array.isArray(tgt)) fail('target is not a JSON object: ' + tgtPath);

  // 既存 deny を先に把握(状態記録は初回のみ = 真のオリジナルを保持)
  const preDeny = (tgt.permissions && Array.isArray(tgt.permissions.deny)) ? tgt.permissions.deny.slice() : [];
  const preSet = new Set(preDeny);
  const addedDeny = srcDeny.filter((d) => !preSet.has(d));

  // 1) idempotent: 既存の本パッケージ hook を除去してから足し直す
  stripOurHooks(tgt);

  // 2) deny union
  const mergedDeny = preDeny.concat(addedDeny);
  if (!tgt.permissions || typeof tgt.permissions !== 'object' || Array.isArray(tgt.permissions)) tgt.permissions = {};
  tgt.permissions.deny = mergedDeny;

  // 3) 絶対パス hooks を追加
  mergeHooks(tgt, buildHooks(os, guardDir));

  console.log('target        : ' + tgtPath);
  console.log('deny total    : ' + mergedDeny.length + ' (newly added ' + addedDeny.length + ')');
  console.log('hooks         : UserPromptSubmit / PreToolUse(Bash,Write,WebFetch) → ' + guardDir);

  if (opts.dryRun) { console.log('[dry-run] no file written'); return; }

  // バックアップ + 状態記録(初回のみオリジナルを保持)
  const st = state.loadState(statePath);
  let originalBackup = st.claude && st.claude.originalBackup !== undefined ? st.claude.originalBackup : undefined;
  let existedBefore = st.claude && st.claude.targetExistedBefore !== undefined ? st.claude.targetExistedBefore : undefined;
  let firstAddedDeny = st.claude && Array.isArray(st.claude.addedDeny) ? st.claude.addedDeny : undefined;
  if (originalBackup === undefined) {
    // 初回適用: 真のオリジナルをバックアップ
    originalBackup = targetExistedBefore ? state.backupFile(tgtPath, 'global-claude') : null;
    existedBefore = targetExistedBefore;
    firstAddedDeny = addedDeny;
  }

  fs.mkdirSync(path.dirname(tgtPath), { recursive: true });
  fs.writeFileSync(tgtPath, JSON.stringify(tgt, null, 2) + '\n', 'utf8');

  st.claude = {
    appliedAt: new Date().toISOString(),
    target: tgtPath,
    guardDir: guardDir,
    os: os,
    originalBackup: originalBackup,
    targetExistedBefore: existedBefore,
    addedDeny: firstAddedDeny,
  };
  state.saveState(statePath, st);
  console.log('backup        : ' + (originalBackup || '(none — target did not exist)'));
  console.log('state         : ' + statePath);
  console.log('written       : ' + tgtPath);
}

// ---- uninstall -----------------------------------------------------------
function doUninstall() {
  const st = state.loadState(statePath);
  const entry = st.claude;
  const tgtPath = opts.target || (entry && entry.target);
  if (!entry) {
    console.log('Claude グローバル適用の記録がありません(既に解除済み or 未適用)。');
    return;
  }
  if (!tgtPath) fail('uninstall requires --target or a recorded target in state');

  if (opts.dryRun) {
    console.log('[dry-run] would restore: ' + (entry.originalBackup || '(delete — target did not exist before)'));
    return;
  }

  // 解除自体も可逆に: 現状を退避
  if (fs.existsSync(tgtPath)) state.backupFile(tgtPath, 'global-claude-preundo');

  if (entry.originalBackup && fs.existsSync(entry.originalBackup)) {
    fs.copyFileSync(entry.originalBackup, tgtPath);
    console.log('restored      : ' + tgtPath + ' ← ' + entry.originalBackup);
  } else if (entry.targetExistedBefore === false) {
    if (fs.existsSync(tgtPath)) fs.unlinkSync(tgtPath);
    console.log('removed       : ' + tgtPath + ' (適用前は存在しなかったため削除)');
  } else {
    // バックアップが失われた場合の外科的フォールバック: 足した hook / deny だけ取り除く
    const tgt = readJson(tgtPath, {});
    stripOurHooks(tgt);
    if (tgt.permissions && Array.isArray(tgt.permissions.deny) && Array.isArray(entry.addedDeny)) {
      const rm = new Set(entry.addedDeny);
      tgt.permissions.deny = tgt.permissions.deny.filter((d) => !rm.has(d));
    }
    fs.writeFileSync(tgtPath, JSON.stringify(tgt, null, 2) + '\n', 'utf8');
    console.log('surgically reverted (backup missing): ' + tgtPath);
  }

  delete st.claude;
  state.saveState(statePath, st);
  console.log('state         : ' + statePath + ' (claude entry removed)');
}

if (mode === 'apply') doApply(); else doUninstall();
