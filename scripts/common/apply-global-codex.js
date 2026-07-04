#!/usr/bin/env node
'use strict';
// apply-global-codex.js — この PC の Codex 全体設定 (~/.codex/config.toml + ~/.codex/hooks.json) に、
// 素の `codex` をどのフォルダから起動しても効く「決定的な」保護を反映する。
//
//   config.toml (決定的・常時有効 = グローバル保護の本体):
//     approval_policy    = "on-request"     # モデルが承認要と判断した時に確認
//     approvals_reviewer = "auto_review"    # 承認要求を破壊/流出/認証情報の観点で二次レビュー
//     sandbox_mode       = "workspace-write"# OS 隔離: 作業フォルダ外への書込/削除を遮断
//     [sandbox_workspace_write] network_access=true / exclude_tmpdir_env_var=true / exclude_slash_tmp=true
//     [shell_environment_policy] inherit="all" / exclude=[APIキー群]  # 鍵を子プロセス環境から除外
//     [features] hooks = true
//     ([windows] sandbox="unelevated" は Windows のみ)
//
//   hooks.json (guard 絶対パス配線・任意):
//     UserPromptSubmit→guard-prompt / PreToolUse: Bash→guard-bash, Write系→guard-write, WebFetch→guard-webfetch
//     ※ codex 0.135+ は「信頼していないフックを黙ってスキップ」する。配線は用意するが、guard 層の発火には
//        一度だけ codex の /hooks で信頼する操作が要る(信頼ハッシュは codex 内部生成で外から確定できない)。
//        常時有効な保護は上記 config.toml 側(sandbox/approval/env 除外)が決定的に担う。
//
// 既存の ~/.codex/config.toml は壊さない: 管理キー以外の行は 1 行も失わない(失う編集になるなら中断)。
// 書込前に必ずバックアップし、取り消し(uninstall)はバックアップからの復元で確実に元へ戻す。
//
// Usage:
//   node apply-global-codex.js apply --config-target <config.toml> --hooks-target <hooks.json>
//                                    --os macos|windows --guard-dir <abs guard dir> [--state <path>] [--dry-run]
//   node apply-global-codex.js uninstall --config-target <config.toml> --hooks-target <hooks.json> [--state <path>] [--dry-run]
const fs = require('fs');
const path = require('path');
const state = require('./global-guard-state.js');

function fail(msg) { console.error('apply-global-codex: ' + msg); process.exit(2); }

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

const EXCLUDE_KEYS = [
  'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY',
  'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'GITHUB_TOKEN', 'NPM_TOKEN', 'SLACK_BOT_TOKEN',
];

// ==========================================================================
// 保守的 TOML ラインエディタ: 管理キー以外の行を 1 行も失わない。失う編集になるなら中断。
// ==========================================================================

// 文字列/コメントを避けて 1 行の括弧収支([ の数 - ] の数)を返す。
function bracketDelta(line) {
  let d = 0, i = 0, inStr = null;
  while (i < line.length) {
    const c = line[i];
    if (inStr) {
      if (c === '\\' && inStr === '"') { i += 2; continue; }
      if (c === inStr) inStr = null;
    } else {
      if (c === '#') break;
      else if (c === '"' || c === "'") inStr = c;
      else if (c === '[') d++;
      else if (c === ']') d--;
    }
    i++;
  }
  return d;
}

function stripComment(s) { return s.replace(/\s*#.*$/, '').trim(); }
function isHeaderLine(line, depth) {
  if (depth !== 0) return false;
  const t = line.trim();
  if (!t.startsWith('[')) return false;
  return /^\[\[?[^\[\]]+\]\]?$/.test(stripComment(t));
}

// text → [{header:string|null, lines:[]}] (root は header:null で先頭)
function sectionize(lines) {
  const sections = [{ header: null, lines: [] }];
  let depth = 0;
  for (const raw of lines) {
    if (isHeaderLine(raw, depth)) {
      sections.push({ header: raw, lines: [] });
    } else {
      sections[sections.length - 1].lines.push(raw);
      depth += bracketDelta(raw);
      if (depth < 0) depth = 0;
    }
  }
  return sections;
}

function sectionName(section) {
  return section.header === null ? null : stripComment(section.header).replace(/^\[+|\]+$/g, '').trim();
}

// section.lines 内で「key = …」の全スパン(単一行 or 複数行配列)を newLines に置換。
// 置換したら {replaced:true, removed:[...]} を返す。見つからなければ {replaced:false}。
function replaceKeySpan(lines, key, newLines) {
  const keyRe = new RegExp('^\\s*' + key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*=');
  let depth = 0;
  for (let i = 0; i < lines.length; i++) {
    const atZero = depth === 0;
    if (atZero && keyRe.test(lines[i])) {
      // スパン終端: この行から括弧収支が 0 に戻るまで
      let j = i, run = 0;
      do { run += bracketDelta(lines[j]); j++; } while (j < lines.length && run > 0);
      const removed = lines.slice(i, j);
      lines.splice(i, j - i, ...newLines);
      return { replaced: true, removed: removed };
    }
    depth += bracketDelta(lines[i]);
    if (depth < 0) depth = 0;
  }
  return { replaced: false, removed: [] };
}

function tomlStr(v) { return '"' + String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'; }

// 管理キーを反映した TOML を返す。ORIGINAL 行のうち管理キースパン以外が消える編集は中断(null 返し)。
function editCodexConfig(originalText, os) {
  const nl = originalText.includes('\r\n') ? '\r\n' : '\n';
  const originalLines = originalText.length ? originalText.split(/\r?\n/) : [];
  const sections = sectionize(originalLines.slice());
  const removed = []; // 置換で消えた ORIGINAL 行(消えてよい行)

  function root() { return sections[0]; }
  function ensureSection(name) {
    for (const s of sections) { if (sectionName(s) === name) return s; }
    const s = { header: '[' + name + ']', lines: [], created: true };
    sections.push(s);
    return s;
  }
  function setScalar(section, key, valueToml) {
    const r = replaceKeySpan(section.lines, key, [key + ' = ' + valueToml]);
    if (r.replaced) { removed.push.apply(removed, r.removed); }
    else { section.lines.push(key + ' = ' + valueToml); }
  }
  function setArray(section, key, values) {
    const arr = [key + ' = ['];
    for (const v of values) arr.push('  ' + tomlStr(v) + ',');
    arr.push(']');
    const r = replaceKeySpan(section.lines, key, arr);
    if (r.replaced) { removed.push.apply(removed, r.removed); }
    else { section.lines.push.apply(section.lines, arr); }
  }

  // root scalars
  setScalar(root(), 'approval_policy', tomlStr('on-request'));
  setScalar(root(), 'approvals_reviewer', tomlStr('auto_review'));
  setScalar(root(), 'sandbox_mode', tomlStr('workspace-write'));
  // tables
  setScalar(ensureSection('features'), 'hooks', 'true');
  const sww = ensureSection('sandbox_workspace_write');
  setScalar(sww, 'network_access', 'true');
  setScalar(sww, 'exclude_tmpdir_env_var', 'true');
  setScalar(sww, 'exclude_slash_tmp', 'true');
  if (os === 'windows') setScalar(ensureSection('windows'), 'sandbox', tomlStr('unelevated'));
  const sep = ensureSection('shell_environment_policy');
  setScalar(sep, 'inherit', tomlStr('all'));
  setArray(sep, 'exclude', EXCLUDE_KEYS);

  // 直列化
  const out = [];
  for (const s of sections) {
    if (s.header !== null) {
      if (s.created && out.length && out[out.length - 1].trim() !== '') out.push('');
      out.push(s.header);
    }
    out.push.apply(out, s.lines);
  }
  let outText = out.join(nl).replace(/(\r?\n)+$/, '') + nl;

  // ---- データ喪失インバリアント: 管理スパン以外の ORIGINAL 行はすべて出力に残ること ----
  const outLines = outText.split(/\r?\n/);
  const outCount = new Map();
  for (const l of outLines) { const k = l.trim(); if (!k) continue; outCount.set(k, (outCount.get(k) || 0) + 1); }
  const removedCount = new Map();
  for (const l of removed) { const k = l.trim(); if (!k) continue; removedCount.set(k, (removedCount.get(k) || 0) + 1); }
  for (const raw of originalLines) {
    const k = raw.trim();
    if (!k) continue;
    const rc = removedCount.get(k) || 0;
    if (rc > 0) { removedCount.set(k, rc - 1); continue; } // 管理スパンで消えた行は OK
    const oc = outCount.get(k) || 0;
    if (oc <= 0) {
      return { ok: false, missing: k };
    }
    outCount.set(k, oc - 1);
  }
  return { ok: true, text: outText };
}

// ==========================================================================
// codex hooks.json (絶対パス配線)
// ==========================================================================
const GUARD_SIG = /guard-(prompt|bash|write|webfetch)\.(sh|ps1)/;

function macCodexHookCmd(guardDir, script) {
  const p = path.posix.join(guardDir, script);
  return '/bin/bash -lc \'p="' + p + '"; if [ ! -x "$p" ]; then echo "AI Safety hook missing: $p" >&2; exit 2; fi; "$p"\'';
}
function winCodexHookCmd(guardDir, script) {
  const p = (guardDir.replace(/\//g, '\\').replace(/\\+$/, '')) + '\\' + script;
  return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + p + '"';
}

function buildCodexHooks(os, guardDir) {
  const isWin = os === 'windows';
  const mk = isWin ? winCodexHookCmd : macCodexHookCmd;
  const ext = isWin ? 'ps1' : 'sh';
  const g = (script) => ({ hooks: [{ type: 'command', command: mk(guardDir, script) }] });
  const gm = (matcher, script) => ({ matcher: matcher, hooks: [{ type: 'command', command: mk(guardDir, script) }] });
  return {
    UserPromptSubmit: [g('guard-prompt.' + ext)],
    PreToolUse: [
      gm('Bash', 'guard-bash.' + ext),
      gm('Write|Edit|MultiEdit|apply_patch', 'guard-write.' + ext),
      gm('WebFetch|web_fetch', 'guard-webfetch.' + ext),
    ],
  };
}

function stripOurCodexHooks(obj) {
  if (!obj.hooks || typeof obj.hooks !== 'object') return;
  for (const ev of Object.keys(obj.hooks)) {
    const groups = obj.hooks[ev];
    if (!Array.isArray(groups)) continue;
    const kept = groups.filter((gr) => !GUARD_SIG.test(JSON.stringify(gr)));
    if (kept.length) obj.hooks[ev] = kept; else delete obj.hooks[ev];
  }
}

function mergeCodexHooks(existingText, os, guardDir) {
  let obj = {};
  if (existingText) { try { obj = JSON.parse(existingText); } catch (e) { fail('existing hooks.json is invalid JSON: ' + e.message); } }
  if (typeof obj !== 'object' || obj === null || Array.isArray(obj)) fail('hooks.json is not a JSON object');
  stripOurCodexHooks(obj);
  if (!obj.hooks || typeof obj.hooks !== 'object' || Array.isArray(obj.hooks)) obj.hooks = {};
  const blocks = buildCodexHooks(os, guardDir);
  for (const ev of Object.keys(blocks)) {
    if (!Array.isArray(obj.hooks[ev])) obj.hooks[ev] = [];
    obj.hooks[ev] = obj.hooks[ev].concat(blocks[ev]);
  }
  return JSON.stringify(obj, null, 2) + '\n';
}

// ==========================================================================
function doApply() {
  const cfgPath = opts['config-target'], hooksPath = opts['hooks-target'], os = opts.os, guardDir = opts['guard-dir'];
  if (!cfgPath || !hooksPath || !os || !guardDir) fail('apply requires --config-target --hooks-target --os --guard-dir');
  if (os !== 'macos' && os !== 'windows') fail('--os must be macos or windows');

  const cfgExisted = fs.existsSync(cfgPath);
  const hooksExisted = fs.existsSync(hooksPath);
  const cfgText = cfgExisted ? fs.readFileSync(cfgPath, 'utf8') : '';
  const hooksText = hooksExisted ? fs.readFileSync(hooksPath, 'utf8') : '';

  const edited = editCodexConfig(cfgText, os);
  if (!edited.ok) {
    fail('既存 config.toml を安全に編集できません(管理キー以外の行が失われる恐れ): "' + edited.missing + '"。中断しました。手動で確認してください: ' + cfgPath);
  }
  const newCfg = edited.text;
  const newHooks = mergeCodexHooks(hooksText, os, guardDir);

  console.log('config-target : ' + cfgPath + (cfgExisted ? '' : ' (new)'));
  console.log('hooks-target  : ' + hooksPath + (hooksExisted ? '' : ' (new)'));
  console.log('guard-dir     : ' + guardDir);

  if (opts.dryRun) { console.log('[dry-run] no file written'); return; }

  const st = state.loadState(statePath);
  // 初回のみオリジナルをバックアップ(真のオリジナルを保持)
  if (!st.codexConfig) {
    st.codexConfig = {
      appliedAt: new Date().toISOString(), target: cfgPath,
      originalBackup: cfgExisted ? state.backupFile(cfgPath, 'global-codex-config') : null,
      targetExistedBefore: cfgExisted,
    };
  } else { st.codexConfig.appliedAt = new Date().toISOString(); st.codexConfig.target = cfgPath; }
  if (!st.codexHooks) {
    st.codexHooks = {
      appliedAt: new Date().toISOString(), target: hooksPath,
      originalBackup: hooksExisted ? state.backupFile(hooksPath, 'global-codex-hooks') : null,
      targetExistedBefore: hooksExisted,
    };
  } else { st.codexHooks.appliedAt = new Date().toISOString(); st.codexHooks.target = hooksPath; }

  fs.mkdirSync(path.dirname(cfgPath), { recursive: true });
  fs.writeFileSync(cfgPath, newCfg, 'utf8');
  fs.mkdirSync(path.dirname(hooksPath), { recursive: true });
  fs.writeFileSync(hooksPath, newHooks, 'utf8');
  state.saveState(statePath, st);

  console.log('backup(config): ' + (st.codexConfig.originalBackup || '(none — did not exist)'));
  console.log('backup(hooks) : ' + (st.codexHooks.originalBackup || '(none — did not exist)'));
  console.log('written       : ' + cfgPath + ' , ' + hooksPath);
  console.log('state         : ' + statePath);
}

function restoreOrRemove(entry, fallbackTarget, label) {
  const tgt = (entry && entry.target) || fallbackTarget;
  if (!entry) { console.log('  (no state entry — skipped) ' + (fallbackTarget || '')); return; }
  if (fs.existsSync(tgt)) state.backupFile(tgt, label + '-preundo');
  if (entry.originalBackup && fs.existsSync(entry.originalBackup)) {
    fs.copyFileSync(entry.originalBackup, tgt);
    console.log('  restored: ' + tgt + ' ← ' + entry.originalBackup);
  } else if (entry.targetExistedBefore === false) {
    if (fs.existsSync(tgt)) fs.unlinkSync(tgt);
    console.log('  removed : ' + tgt + ' (適用前は存在しなかったため削除)');
  } else {
    console.log('  WARN: backup missing and file existed before — left as-is: ' + tgt);
  }
}

function doUninstall() {
  const st = state.loadState(statePath);
  if (!st.codexConfig && !st.codexHooks) {
    console.log('Codex グローバル適用の記録がありません(既に解除済み or 未適用)。');
    return;
  }
  if (opts.dryRun) {
    console.log('[dry-run] would restore/remove codex config.toml and hooks.json from backups');
    return;
  }
  restoreOrRemove(st.codexConfig, opts['config-target'], 'global-codex-config');
  restoreOrRemove(st.codexHooks, opts['hooks-target'], 'global-codex-hooks');
  delete st.codexConfig; delete st.codexHooks;
  state.saveState(statePath, st);
  console.log('state         : ' + statePath + ' (codex entries removed)');
}

if (mode === 'apply') doApply(); else doUninstall();
