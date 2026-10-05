'use strict';
// longrun-no-prompt.test.js — 長時間おまかせモードで確認ダイアログを出さない作り（v1.20.0）の回帰テスト。
//
// 方針（2026-10-05 依頼者の判断）:
//   ・Claude（Anthropic）の長時間おまかせモードは auto モード（Claude Code 公式の判定役が裏で確かめる）
//   ・d-claude（DeepSeek）は全承認（bypassPermissions）＋安全パッケージの AI 判定（Gemini）
//   ・どちらも、安全パッケージの禁止の規則・ガード・作業フォルダの控えはそのまま
//   ・ガードが返していた「確認」は、長時間おまかせモード（AI_SAFE_LONGRUN=1）では「止める」に置き換える
//     （止める向きにしか変わらないので、印が誤って立っても守りは緩まない）
//   ・学習用のふだんの起動は変えない（印が無ければ、これまでどおり確認を出す）
// 本物の AI ツールの代わりに偽物を使い、本物のホームフォルダには触らない。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PKG = path.resolve(__dirname, '..', '..', '..');
const macOnly = process.platform === 'darwin' ? false : 'macOS 専用の経路のため skip';
const pwshCheck = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8' });
const HAS_PWSH = pwshCheck.status === 0 && process.platform !== 'win32';
const pwshSkip = HAS_PWSH ? false : 'pwsh が無い環境（Windows 実機では CI で確認）';
const BLOCK_TEXT = /長時間おまかせモードでは確認できないため止めました/;

function makeSandbox(t) {
  const base = path.join(os.homedir(), '.cache');
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, 'asp-longrun-noprompt-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, 'home');
  const ws = path.join(root, 'ws');
  const bin = path.join(root, 'bin');
  const logs = path.join(root, 'logs');
  for (const d of [home, ws, bin, logs, path.join(ws, '.claude'), path.join(ws, '.ai-safety', 'policy')]) {
    fs.mkdirSync(d, { recursive: true });
  }
  fs.copyFileSync(path.join(PKG, 'policy', 'safety-policy.json'), path.join(ws, '.ai-safety', 'policy', 'safety-policy.json'));
  return { root, home, ws, bin, logs };
}

const writeOutside = (sb) => JSON.stringify({
  hook_event_name: 'PreToolUse', tool_name: 'Write', cwd: sb.ws,
  tool_input: { file_path: path.join(sb.root, 'elsewhere', 'notes.txt'), content: 'hello' },
});
const bashInput = (sb, command) => JSON.stringify({
  hook_event_name: 'PreToolUse', tool_name: 'Bash', cwd: sb.ws, tool_input: { command },
});

function runMac(sb, guard, input, extraEnv = {}) {
  return spawnSync('bash', [path.join(PKG, 'scripts', 'macos', guard)], {
    env: { ...process.env, HOME: sb.home, AI_SAFE_LOG_DIR: sb.logs, ...extraEnv },
    input, encoding: 'utf8', timeout: 60000,
  });
}
function runWin(sb, guard, input, extraEnv = {}) {
  const env = { ...process.env, HOME: sb.home, USERPROFILE: sb.home, AI_SAFE_LOG_DIR: sb.logs, ...extraEnv };
  // mac の pwsh には Windows 専用の環境変数（USERPROFILE など）が無い。本物の Windows では常にあるので、空の置き場を与える。
  for (const k of ['ProgramFiles', 'ProgramFiles(x86)', 'APPDATA', 'LOCALAPPDATA']) {
    const d = path.join(sb.root, 'win-' + k.replace(/[^A-Za-z]/g, ''));
    fs.mkdirSync(d, { recursive: true });
    env[k] = d;
  }
  return spawnSync('pwsh', ['-NoProfile', '-File', path.join(PKG, 'scripts', 'windows', guard)], {
    env, input, encoding: 'utf8', timeout: 60000,
  });
}
const isAsk = (r) => r.status === 0 && /"permissionDecision"\s*:\s*"ask"/.test(r.stdout);
const isLongrunBlock = (r) => r.status === 2 && BLOCK_TEXT.test(r.stderr);

// 「判定できない AI」を作る: 何も出さずに異常終了する偽の node を PATH の先頭に置く。
function fakeBrokenNode(sb) {
  const p = path.join(sb.bin, 'node');
  fs.writeFileSync(p, '#!/bin/sh\nexit 1\n', { mode: 0o755 });
  return { PATH: `${sb.bin}:${process.env.PATH}` };
}

// --- ガード: mac ----------------------------------------------------------------------------
test('mac: 作業フォルダの外への書き込みは、ふだんは確認・長時間モードでは止める', { skip: macOnly }, (t) => {
  const sb = makeSandbox(t);
  assert.ok(isAsk(runMac(sb, 'guard-write.sh', writeOutside(sb))), 'ふだんは確認を出すこと');
  const r = runMac(sb, 'guard-write.sh', writeOutside(sb), { AI_SAFE_LONGRUN: '1' });
  assert.ok(isLongrunBlock(r), `長時間モードでは止めること: ${r.status} ${r.stdout} ${r.stderr}`);
});

test('mac: 生成物のまとめ削除は、ふだんは確認・長時間モードでは止める', { skip: macOnly }, (t) => {
  const sb = makeSandbox(t);
  const cmd = 'rm -rf node_modules';
  assert.ok(isAsk(runMac(sb, 'guard-bash.sh', bashInput(sb, cmd))), 'ふだんは確認を出すこと');
  const r = runMac(sb, 'guard-bash.sh', bashInput(sb, cmd), { AI_SAFE_LONGRUN: '1' });
  assert.ok(isLongrunBlock(r), `長時間モードでは止めること: ${r.status} ${r.stdout} ${r.stderr}`);
});

test('mac: AI 判定が使えないグレーなコマンドは、ふだんは確認・長時間モードでは止める', { skip: macOnly }, (t) => {
  const sb = makeSandbox(t);
  const env = { ...fakeBrokenNode(sb), AI_SAFE_ASSISTED_APPROVAL: '1', GEMINI_API_KEY: '', GOOGLE_API_KEY: '' };
  const cmd = 'python3 tools/convert.py data.csv';
  assert.ok(isAsk(runMac(sb, 'guard-bash.sh', bashInput(sb, cmd), env)), 'ふだんは確認を出すこと');
  const r = runMac(sb, 'guard-bash.sh', bashInput(sb, cmd), { ...env, AI_SAFE_LONGRUN: '1' });
  assert.ok(isLongrunBlock(r), `長時間モードでは止めること: ${r.status} ${r.stdout} ${r.stderr}`);
});

test('mac: 危険なコマンドは、ふだんも長時間モードも止める（印で緩まない）', { skip: macOnly }, (t) => {
  const sb = makeSandbox(t);
  for (const extra of [{}, { AI_SAFE_LONGRUN: '1' }]) {
    const r = runMac(sb, 'guard-bash.sh', bashInput(sb, 'rm -rf ~/Documents'), extra);
    assert.strictEqual(r.status, 2, JSON.stringify(extra) + ' ' + r.stderr);
  }
});

// --- ガード: Windows（mac の pwsh で検証） -------------------------------------------------------
test('Windows: 作業フォルダの外への書き込みは、ふだんは確認・長時間モードでは止める', { skip: pwshSkip }, (t) => {
  const sb = makeSandbox(t);
  assert.ok(isAsk(runWin(sb, 'guard-write.ps1', writeOutside(sb))), 'ふだんは確認を出すこと');
  const r = runWin(sb, 'guard-write.ps1', writeOutside(sb), { AI_SAFE_LONGRUN: '1' });
  assert.ok(isLongrunBlock(r), `長時間モードでは止めること: ${r.status} ${r.stdout} ${r.stderr}`);
});

test('Windows: 生成物のまとめ削除は、ふだんは確認・長時間モードでは止める', { skip: pwshSkip }, (t) => {
  const sb = makeSandbox(t);
  const cmd = 'rm -rf node_modules';
  assert.ok(isAsk(runWin(sb, 'guard-bash.ps1', bashInput(sb, cmd))), 'ふだんは確認を出すこと');
  const r = runWin(sb, 'guard-bash.ps1', bashInput(sb, cmd), { AI_SAFE_LONGRUN: '1' });
  assert.ok(isLongrunBlock(r), `長時間モードでは止めること: ${r.status} ${r.stdout} ${r.stderr}`);
});

test('Windows: AI 判定が使えないグレーなコマンドは、ふだんは確認・長時間モードでは止める', { skip: pwshSkip }, (t) => {
  const sb = makeSandbox(t);
  const env = { ...fakeBrokenNode(sb), AI_SAFE_ASSISTED_APPROVAL: '1', GEMINI_API_KEY: '', GOOGLE_API_KEY: '' };
  const cmd = 'python3 tools/convert.py data.csv';
  assert.ok(isAsk(runWin(sb, 'guard-bash.ps1', bashInput(sb, cmd), env)), 'ふだんは確認を出すこと');
  const r = runWin(sb, 'guard-bash.ps1', bashInput(sb, cmd), { ...env, AI_SAFE_LONGRUN: '1' });
  assert.ok(isLongrunBlock(r), `長時間モードでは止めること: ${r.status} ${r.stdout} ${r.stderr}`);
});

// --- 起動: Claude の長時間おまかせモードは auto モード -------------------------------------------
function writeFakeClaude(sb, { auto }) {
  const argsFile = path.join(sb.root, 'claude-args.txt');
  const envFile = path.join(sb.root, 'claude-env.txt');
  const choices = auto ? '"acceptEdits", "auto", "bypassPermissions", "manual"' : '"acceptEdits", "bypassPermissions", "default"';
  fs.writeFileSync(path.join(sb.bin, 'claude'), [
    '#!/usr/bin/env bash',
    `if [ "\${1:-}" = "--help" ]; then echo '  --permission-mode <mode>  Permission mode (choices: ${choices})'; exit 0; fi`,
    'if [ "${1:-}" = "--version" ]; then echo "2.1.999 (Claude Code)"; exit 0; fi',
    `printf '%s\\n' "$@" > ${JSON.stringify(argsFile)}`,
    `printf '%s' "\${AI_SAFE_LONGRUN:-}" > ${JSON.stringify(envFile)}`,
    'exit 0',
  ].join('\n') + '\n', { mode: 0o755 });
  return { argsFile, envFile };
}
const permissionModeOf = (argsFile) => {
  const a = fs.readFileSync(argsFile, 'utf8').split('\n');
  return a[a.indexOf('--permission-mode') + 1];
};

test('mac: Claude の長時間おまかせモードは auto モードで起動し、ガードに長時間の印を渡す', { skip: macOnly }, (t) => {
  const sb = makeSandbox(t);
  fs.copyFileSync(path.join(PKG, 'configs', 'claude', 'settings.mac.json'), path.join(sb.ws, '.claude', 'settings.json'));
  const cap = writeFakeClaude(sb, { auto: true });
  const r = spawnSync('bash', [path.join(PKG, 'scripts', 'macos', 'launch-longrun.sh'), sb.ws, 'claude'], {
    env: { ...process.env, HOME: sb.home, PATH: `${sb.bin}:${process.env.PATH}`, AI_SAFE_SNAPSHOT: 'off' },
    input: '\nはい\n', encoding: 'utf8', timeout: 120000,
  });
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  assert.strictEqual(permissionModeOf(cap.argsFile), 'auto');
  assert.strictEqual(fs.readFileSync(cap.envFile, 'utf8'), '1', 'ガードへ長時間の印が渡っていない');
});

test('mac: auto モードが無い古い Claude Code では、これまでどおり acceptEdits', { skip: macOnly }, (t) => {
  const sb = makeSandbox(t);
  fs.copyFileSync(path.join(PKG, 'configs', 'claude', 'settings.mac.json'), path.join(sb.ws, '.claude', 'settings.json'));
  const cap = writeFakeClaude(sb, { auto: false });
  const r = spawnSync('bash', [path.join(PKG, 'scripts', 'macos', 'launch-longrun.sh'), sb.ws, 'claude'], {
    env: { ...process.env, HOME: sb.home, PATH: `${sb.bin}:${process.env.PATH}`, AI_SAFE_SNAPSHOT: 'off' },
    input: '\nはい\n', encoding: 'utf8', timeout: 120000,
  });
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  assert.strictEqual(permissionModeOf(cap.argsFile), 'acceptEdits');
});

test('Windows: Claude の長時間おまかせモードは auto モードで起動する（ソースの照合）', () => {
  const ps1 = fs.readFileSync(path.join(PKG, 'scripts', 'windows', 'launch-longrun.ps1'), 'utf8');
  assert.match(ps1, /\$help\.Contains\('"auto"'\)/);
  assert.match(ps1, /@\('--permission-mode', 'auto'\) \+ \$claudeArgs/);
  assert.match(ps1, /\$env:AI_SAFE_LONGRUN = '1'/);
});

// --- 学習用のふだんの起動は変えない ----------------------------------------------------------------
test('学習用のふだんの起動（launch-claude-safe の --longrun なし）は全承認にも auto にもしない', () => {
  const sh = fs.readFileSync(path.join(PKG, 'scripts', 'macos', 'launch-claude-safe.sh'), 'utf8');
  const ps1 = fs.readFileSync(path.join(PKG, 'scripts', 'windows', 'launch-claude-safe.ps1'), 'utf8');
  assert.match(sh, /_permission_mode="default"/);
  assert.match(ps1, /\$permissionMode = "default"/);
  for (const name of ['settings.mac.json', 'settings.windows.json']) {
    const s = JSON.parse(fs.readFileSync(path.join(PKG, 'configs', 'claude', name), 'utf8'));
    assert.strictEqual(s.permissions.disableBypassPermissionsMode, 'disable', `${name}: ふだんの設定は全承認を封じたまま`);
    assert.notStrictEqual(s.permissions.defaultMode, 'auto', `${name}: ふだんの設定を auto にしない`);
    assert.notStrictEqual(s.permissions.defaultMode, 'bypassPermissions', `${name}: ふだんの設定を全承認にしない`);
  }
});
