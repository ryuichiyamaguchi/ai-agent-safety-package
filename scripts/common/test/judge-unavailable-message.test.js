// judge-unavailable-message.test.js — グレー判定が「AI に聞けなかった」ときの表示を mac / Windows で揃える回帰テスト。
//
// 背景（v1.19.0）: 判定結果には status（ok / unavailable）があり、ask の文言を
//   - unavailable = AI に聞けなかった（キー未設定・通信断・時間切れ・異常終了）
//   - ok          = AI が慎重に判断した
// で言い分ける。mac の guard-bash.sh は judge が何も返さなかったとき（異常終了・30 秒の打ち切り）に
// status が空のまま「AI が確信できませんでした」側へ落ちていた。Windows 側は初期値が unavailable で正しかった。
//
// ここでは「何も出力せずに異常終了する偽の node」を PATH の先頭に置き、判定プロセスが落ちた状況を作る。
// ネットワークには一切出ない。
'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const REPO = path.resolve(__dirname, '..', '..', '..');
const MAC_GUARD = path.join(REPO, 'scripts', 'macos', 'guard-bash.sh');
const WIN_GUARD = path.join(REPO, 'scripts', 'windows', 'guard-bash.ps1');

const UNAVAILABLE = 'AI 判定を実行できませんでした';
const CAUTIOUS = '確信できませんでした';

// 決定的 deny にも決定的 allow にも当たらない、ふつうのグレーなコマンド。
const GREY_COMMAND = 'make build';

function makeSandbox() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'judge-unavail-'));
  const fakebin = path.join(root, 'fakebin');
  const ws = path.join(root, 'ws');
  const logs = path.join(root, 'logs');
  for (const d of [fakebin, ws, logs]) fs.mkdirSync(d, { recursive: true });
  const fakeNode = path.join(fakebin, 'node');
  fs.writeFileSync(fakeNode, '#!/bin/sh\nexit 1\n');
  fs.chmodSync(fakeNode, 0o755);
  return { root, fakebin, ws, logs };
}

function hookInput(ws) {
  return JSON.stringify({ tool_name: 'Bash', tool_input: { command: GREY_COMMAND }, cwd: ws });
}

function baseEnv(sb) {
  const env = { ...process.env };
  for (const k of ['GEMINI_API_KEY', 'GOOGLE_API_KEY', 'DS_CLAUDE_MODE', 'AI_SAFE_POLICY', 'AI_SAFE_ROOT', 'NODE_BIN']) {
    delete env[k];
  }
  return {
    ...env,
    HOME: sb.root,
    USERPROFILE: sb.root,
    PATH: sb.fakebin + path.delimiter + process.env.PATH,
    AI_SAFE_ASSISTED_APPROVAL: '1',
    AI_SAFE_LOG_DIR: sb.logs,
  };
}

function reasonOf(stdout) {
  const line = String(stdout).split('\n').find((l) => l.includes('permissionDecision'));
  assert.ok(line, 'hook の JSON 出力がありません: ' + stdout);
  const j = JSON.parse(line);
  return { decision: j.hookSpecificOutput.permissionDecision, reason: j.hookSpecificOutput.permissionDecisionReason };
}

const HAS_BASH = process.platform !== 'win32' && spawnSync('bash', ['-c', 'exit 0']).status === 0;

test('mac guard-bash: 判定プロセスが何も返さずに落ちたら「実行できませんでした」と表示する', { skip: HAS_BASH ? false : 'bash が無い環境' }, () => {
  const sb = makeSandbox();
  try {
    const r = spawnSync('bash', [MAC_GUARD], { cwd: sb.ws, env: baseEnv(sb), input: hookInput(sb.ws), encoding: 'utf8', timeout: 60000 });
    const { decision, reason } = reasonOf(r.stdout);
    assert.strictEqual(decision, 'ask');
    assert.ok(reason.includes(UNAVAILABLE), '文言: ' + reason);
    assert.ok(!reason.includes(CAUTIOUS), '「慎重だった」側の文言になっている: ' + reason);
  } finally {
    fs.rmSync(sb.root, { recursive: true, force: true });
  }
});

const pwshCheck = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8' });
const HAS_PWSH = pwshCheck.status === 0 && process.platform !== 'win32';

test('Windows guard-bash: 判定プロセスが何も返さずに落ちたら「実行できませんでした」と表示する（mac と同じ）', { skip: HAS_PWSH ? false : 'pwsh が無い環境（Windows 実機では CI で確認）' }, () => {
  const sb = makeSandbox();
  try {
    // mac の pwsh には Windows 専用の環境変数が無く、node の候補探し（Join-Path $env:ProgramFiles …）で
    // 見張りが fail-closed になって判定まで届かない。本物の Windows では常にある変数なので、空の置き場を与える。
    const env = { ...baseEnv(sb) };
    for (const k of ['ProgramFiles', 'ProgramFiles(x86)', 'APPDATA', 'LOCALAPPDATA']) {
      const d = path.join(sb.root, 'win-' + k.replace(/[^A-Za-z]/g, ''));
      fs.mkdirSync(d, { recursive: true });
      env[k] = d;
    }
    const r = spawnSync('pwsh', ['-NoProfile', '-File', WIN_GUARD], { cwd: sb.ws, env, input: hookInput(sb.ws), encoding: 'utf8', timeout: 60000 });
    const { decision, reason } = reasonOf(r.stdout);
    assert.strictEqual(decision, 'ask');
    assert.ok(reason.includes(UNAVAILABLE), '文言: ' + reason);
    assert.ok(!reason.includes(CAUTIOUS), '「慎重だった」側の文言になっている: ' + reason);
  } finally {
    fs.rmSync(sb.root, { recursive: true, force: true });
  }
});
