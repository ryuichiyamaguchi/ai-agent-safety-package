const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

function waitForHealth(port) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 5000;
    const tick = () => {
      fetch(`http://127.0.0.1:${port}/healthz`)
        .then((r) => r.text())
        .then((body) => {
          if (body === '{"status":"ok"}') resolve();
          else if (Date.now() > deadline) reject(new Error(`unexpected health body: ${body}`));
          else setTimeout(tick, 100);
        })
        .catch((e) => {
          if (Date.now() > deadline) reject(e);
          else setTimeout(tick, 100);
        });
    };
    tick();
  });
}

function waitForExit(child) {
  return new Promise((resolve, reject) => {
    child.on('exit', (code) => resolve(code));
    child.on('error', reject);
  });
}

test('macOS DeepSeek launcher replaces a stale gateway from the same package path', async (t) => {
  const root = path.join(__dirname, '..', '..', '..');
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-launcher-'));
  t.after(() => fs.rmSync(workspace, { recursive: true, force: true }));

  const hooks = path.join(workspace, '.ai-safety', 'hooks');
  fs.mkdirSync(path.join(hooks, 'common'), { recursive: true });
  fs.mkdirSync(path.join(hooks, 'macos', 'deepseek'), { recursive: true });
  fs.mkdirSync(path.join(hooks, 'macos'), { recursive: true });

  for (const file of ['ds-gateway.js', 'secret-patterns.js', 'token-map.js', 'denylist.js']) {
    fs.copyFileSync(path.join(root, 'scripts', 'common', file), path.join(hooks, 'common', file));
  }
  fs.copyFileSync(
    path.join(root, 'scripts', 'macos', 'deepseek', 'launch-deepseek-gateway.sh'),
    path.join(hooks, 'macos', 'deepseek', 'launch-deepseek-gateway.sh'),
  );
  fs.writeFileSync(path.join(hooks, 'macos', 'launch-claude-safe.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });

  const stale = spawn(process.execPath, [path.join(hooks, 'common', 'ds-gateway.js')], {
    env: { ...process.env, DS_GATEWAY_PORT: '8799' },
    stdio: 'ignore',
  });
  t.after(() => {
    if (!stale.killed) stale.kill('SIGKILL');
  });
  await waitForHealth(8799);

  const launcher = spawn('bash', [path.join(hooks, 'macos', 'deepseek', 'launch-deepseek-gateway.sh'), workspace], {
    env: { ...process.env, DS_GATEWAY_PORT: '8799' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  let err = '';
  launcher.stdout.on('data', (c) => { out += c; });
  launcher.stderr.on('data', (c) => { err += c; });
  const code = await waitForExit(launcher);

  assert.strictEqual(code, 0, `stdout:\n${out}\nstderr:\n${err}`);
  assert.match(out, /送信検査 Gateway 稼働中/);
});

test('Windows DeepSeek launcher has same-package stale gateway cleanup before Start-Process', () => {
  const root = path.join(__dirname, '..', '..', '..');
  const ps1 = fs.readFileSync(path.join(root, 'scripts', 'windows', 'deepseek', 'launch-deepseek-gateway.ps1'), 'utf8');
  assert.match(ps1, /Stop-StaleGateway/);
  assert.match(ps1, /Get-NetTCPConnection/);
  assert.match(ps1, /Win32_Process/);
  assert.ok(ps1.indexOf('Stop-StaleGateway -Port') < ps1.indexOf('Start-Process node'));
});

test('macOS integrated launcher includes monitored d-claude through the existing safe gateway', () => {
  const root = path.join(__dirname, '..', '..', '..');
  const script = fs.readFileSync(path.join(root, 'scripts', 'macos', 'launch-integrated.sh'), 'utf8');
  assert.match(script, /codex\|claude\|opencode\|d-claude/);
  assert.match(script, /d-claude:standard/);
  assert.match(script, /consent=.*launch-deepseek-safe[.]sh/);
  assert.match(script, /bash "\$consent" --consent-only/);
  assert.match(script, /deepseek[/]launch-deepseek-gateway[.]sh/);
  assert.match(script, /ANTHROPIC_AUTH_TOKEN/);
  assert.doesNotMatch(script, /d-claude:standard[\s\S]{0,500}\bclaude\b(?:\s|$)/, '統合経路から素のclaudeを直接起動しない');
});

test('macOS integrated d-claude dry-run reports monitor and send inspection', () => {
  const root = path.join(__dirname, '..', '..', '..');
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'integrated-d-claude-'));
  const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), 'integrated-d-claude-home-'));
  try {
    const hooks = path.join(workspace, '.ai-safety', 'hooks', 'macos');
    fs.mkdirSync(hooks, { recursive: true });
    const launcher = path.join(hooks, 'launch-integrated.sh');
    const monitor = path.join(hooks, 'open-monitor.sh');
    fs.copyFileSync(path.join(root, 'scripts', 'macos', 'launch-integrated.sh'), launcher);
    fs.writeFileSync(monitor, '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });
    fs.chmodSync(launcher, 0o755);
    const result = require('node:child_process').spawnSync('bash', [launcher, workspace, 'd-claude', 'standard'], {
      env: { ...process.env, HOME: fakeHome, AI_SAFE_DRY_RUN: '1' },
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /agent:\s+d-claude/);
    assert.match(result.stdout, /monitor:\s+enabled/);
    assert.match(result.stdout, /127[.]0[.]0[.]1:8788.*send inspection/);
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
    fs.rmSync(fakeHome, { recursive: true, force: true });
  }
});

test('macOS integrated d-claude starts monitor, consent gate, and safe gateway together', () => {
  const root = path.join(__dirname, '..', '..', '..');
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'integrated-d-claude-live-'));
  const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), 'integrated-d-claude-live-home-'));
  try {
    const hooks = path.join(workspace, '.ai-safety', 'hooks', 'macos');
    fs.mkdirSync(path.join(hooks, 'deepseek'), { recursive: true });
    fs.mkdirSync(path.join(fakeHome, '.deepseek-claude'), { recursive: true });
    fs.writeFileSync(path.join(fakeHome, '.deepseek-claude', 'auth'), 'test-key-never-log\n', { mode: 0o600 });
    fs.copyFileSync(path.join(root, 'scripts', 'macos', 'launch-integrated.sh'), path.join(hooks, 'launch-integrated.sh'));
    fs.chmodSync(path.join(hooks, 'launch-integrated.sh'), 0o755);
    fs.writeFileSync(path.join(hooks, 'open-monitor.sh'), [
      '#!/usr/bin/env bash',
      `printf '%s' "$AI_SAFE_AGENT" > "${path.join(workspace, 'monitor-agent')}"`,
    ].join('\n') + '\n', { mode: 0o755 });
    fs.writeFileSync(path.join(hooks, 'launch-deepseek-safe.sh'), [
      '#!/usr/bin/env bash',
      '[ "$1" = "--consent-only" ] || exit 9',
      `printf consent > "${path.join(workspace, 'consent-called')}"`,
    ].join('\n') + '\n', { mode: 0o755 });
    fs.writeFileSync(path.join(hooks, 'deepseek', 'launch-deepseek-gateway.sh'), [
      '#!/usr/bin/env bash',
      '[ -n "$ANTHROPIC_AUTH_TOKEN" ] || exit 8',
      '[ "$ANTHROPIC_MODEL" = "deepseek-v4-pro" ] || exit 7',
      `printf gateway > "${path.join(workspace, 'gateway-called')}"`,
    ].join('\n') + '\n', { mode: 0o755 });

    const result = require('node:child_process').spawnSync('bash', [
      path.join(hooks, 'launch-integrated.sh'), workspace, 'd-claude', 'standard',
    ], {
      env: { ...process.env, HOME: fakeHome, AI_SAFE_LOG_DIR: path.join(fakeHome, 'logs') },
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(path.join(workspace, 'monitor-agent'), 'utf8'), 'd-claude');
    assert.equal(fs.readFileSync(path.join(workspace, 'consent-called'), 'utf8'), 'consent');
    assert.equal(fs.readFileSync(path.join(workspace, 'gateway-called'), 'utf8'), 'gateway');
    assert.doesNotMatch(result.stdout + result.stderr, /test-key-never-log/, 'キー本文をログへ出さない');
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
    fs.rmSync(fakeHome, { recursive: true, force: true });
  }
});
