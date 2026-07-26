'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..', '..');

function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}

test('Windows Bouncer runner binds local services and cleans up only what it started', () => {
  const script = read('bouncer-gateway/scripts/run-local.ps1');
  assert.match(script, /127\.0\.0\.1/);
  assert.match(script, /bouncer-gemma/);
  assert.match(script, /PYTHONPATH/);
  assert.match(script, /finally/);
  assert.match(script, /lms.*unload/i);
  assert.match(script, /server stop/i);
});

test('Windows integrated launcher has standard no-LLM and maximum local-Bouncer profiles', () => {
  const script = read('scripts/windows/launch-integrated.ps1');
  assert.match(script, /ValidateSet\('codex','claude','opencode','d-claude'\)/);
  assert.match(script, /ValidateSet\('standard','assisted','maximum'\)/);
  assert.match(script, /standard/);
  assert.match(script, /maximum/);
  assert.match(script, /run-local\.ps1/);
  assert.match(script, /127\.0\.0\.1:8787\/bouncer\/health/);
  assert.match(script, /BOUNCER_INTEGRATED_MODE/);
  assert.match(script, /AI_SAFE_DRY_RUN/);
  assert.match(script, /'d-claude:standard'/);
  assert.match(script, /launch-deepseek-safe[.]ps1/);
  assert.match(script, /deepseek\\launch-deepseek-gateway[.]ps1/);
  assert.match(script, /ANTHROPIC_AUTH_TOKEN/);
});

test('Windows legacy start buttons route through integrated standard mode', () => {
  const codex = read('workspace-template/スタート/2_セーフCodexを起動.bat');
  const claude = read('workspace-template/スタート/3_セーフClaudeを起動.bat');

  assert.match(codex, /launch-integrated\.ps1/i);
  assert.match(codex, /-Agent codex -Profile standard/i);
  assert.match(claude, /launch-integrated\.ps1/i);
  assert.match(claude, /-Agent claude -Profile standard/i);
});

test('Mac and Windows integrated menus expose d-claude as a monitored option', () => {
  const mac = read('workspace-template/スタート/0_Bouncer統合版を起動.command');
  const win = read('workspace-template/スタート/0_Bouncer統合版を起動.bat');
  assert.match(mac, /d-claude.*DeepSeek/i);
  assert.match(mac, /d-claude standard/);
  assert.match(win, /d-claude.*DeepSeek/i);
  assert.match(win, /-Agent d-claude -Profile standard/i);
});

test('Windows integrated d-claude dry-run reports monitor and send inspection', (t) => {
  const probe = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()'], { encoding: 'utf8' });
  if (probe.error && probe.error.code === 'ENOENT') {
    t.skip('pwsh is not installed on this host');
    return;
  }
  assert.equal(probe.status, 0, probe.stderr);
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'windows-integrated-d-claude-'));
  const fakeProfile = fs.mkdtempSync(path.join(os.tmpdir(), 'windows-integrated-d-claude-profile-'));
  try {
    const result = spawnSync('pwsh', [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', path.join(root, 'scripts', 'windows', 'launch-integrated.ps1'),
      '-Workspace', workspace,
      '-Agent', 'd-claude',
      '-Profile', 'standard',
    ], {
      env: { ...process.env, USERPROFILE: fakeProfile, AI_SAFE_DRY_RUN: '1' },
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /agent:\s+d-claude/);
    assert.match(result.stdout, /monitor:\s+enabled/);
    assert.match(result.stdout, /127[.]0[.]0[.]1:8788.*send inspection/);
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
    fs.rmSync(fakeProfile, { recursive: true, force: true });
  }
});
