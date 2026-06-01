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
