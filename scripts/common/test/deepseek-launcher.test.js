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

// 素性が確かめられない gateway（合言葉の共有ファイルに記録が無い）は信用せず、
// 停止してから自分で立て直す。ここが緩むと「中身の分からない gateway に実キーを預ける」
// ことになるため、共用を入れたあとも残す必要がある回帰。
test('macOS DeepSeek launcher replaces a stale gateway from the same package path', async (t) => {
  const root = path.join(__dirname, '..', '..', '..');
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-launcher-'));
  t.after(() => fs.rmSync(workspace, { recursive: true, force: true }));
  // gateway は実キー（$HOME/.deepseek-claude/auth）と呼び出し元認証トークンを必須にしたので、
  // 実 HOME を汚さない偽 HOME にキーを置いて起動させる。
  const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-launcher-home-'));
  t.after(() => fs.rmSync(fakeHome, { recursive: true, force: true }));
  fs.mkdirSync(path.join(fakeHome, '.deepseek-claude'), { recursive: true });
  fs.writeFileSync(path.join(fakeHome, '.deepseek-claude', 'auth'), 'ds-test-key-never-log\n', { mode: 0o600 });

  const hooks = path.join(workspace, '.ai-safety', 'hooks');
  fs.mkdirSync(path.join(hooks, 'common'), { recursive: true });
  fs.mkdirSync(path.join(hooks, 'macos', 'deepseek'), { recursive: true });
  fs.mkdirSync(path.join(hooks, 'macos'), { recursive: true });

  for (const file of ['ds-gateway.js', 'gateway-token.js', 'secret-patterns.js', 'token-map.js', 'denylist.js']) {
    fs.copyFileSync(path.join(root, 'scripts', 'common', file), path.join(hooks, 'common', file));
  }
  fs.copyFileSync(
    path.join(root, 'scripts', 'macos', 'deepseek', 'launch-deepseek-gateway.sh'),
    path.join(hooks, 'macos', 'deepseek', 'launch-deepseek-gateway.sh'),
  );
  fs.writeFileSync(path.join(hooks, 'macos', 'launch-claude-safe.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });

  // 「素性の記録が無い gateway」を装う。合言葉の共有ファイルは実 HOME を汚さないよう
  // 使い捨ての場所に向ける（ランチャー側は fakeHome を見るので、記録は見つからない）。
  const stale = spawn(process.execPath, [path.join(hooks, 'common', 'ds-gateway.js')], {
    env: {
      ...process.env,
      DS_GATEWAY_PORT: '8799',
      DS_GATEWAY_TOKEN: 'stale-gateway-token',
      DS_GATEWAY_TOKEN_FILE: path.join(workspace, 'stale-gateway-token.json'),
      AI_SAFE_LOG_DIR: path.join(workspace, 'stale-logs'),
    },
    stdio: 'ignore',
  });
  t.after(() => {
    if (!stale.killed) stale.kill('SIGKILL');
  });
  await waitForHealth(8799);

  const launcher = spawn('bash', [path.join(hooks, 'macos', 'deepseek', 'launch-deepseek-gateway.sh'), workspace], {
    env: {
      ...process.env,
      HOME: fakeHome,
      DS_GATEWAY_PORT: '8799',
      AI_SAFE_LOG_DIR: path.join(fakeHome, 'logs'),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  let err = '';
  launcher.stdout.on('data', (c) => { out += c; });
  launcher.stderr.on('data', (c) => { err += c; });
  const code = await waitForExit(launcher);

  assert.strictEqual(code, 0, `stdout:\n${out}\nstderr:\n${err}`);
  assert.match(out, /送信検査 Gateway 稼働中/);
  // 合言葉も実キーも画面・ログには出さない。
  assert.doesNotMatch(out + err, /ds-test-key-never-log/, 'キー本文を出力しない');
  assert.doesNotMatch(out + err, /[0-9a-f]{64}/, '合言葉を出力しない');
});

test('macOS DeepSeek launcher is fail-closed when the DeepSeek key is not registered', async (t) => {
  const root = path.join(__dirname, '..', '..', '..');
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-launcher-nokey-'));
  const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-launcher-nokey-home-'));
  t.after(() => {
    fs.rmSync(workspace, { recursive: true, force: true });
    fs.rmSync(fakeHome, { recursive: true, force: true });
  });

  const hooks = path.join(workspace, '.ai-safety', 'hooks');
  fs.mkdirSync(path.join(hooks, 'common'), { recursive: true });
  fs.mkdirSync(path.join(hooks, 'macos', 'deepseek'), { recursive: true });
  for (const file of ['ds-gateway.js', 'gateway-token.js', 'secret-patterns.js', 'token-map.js', 'denylist.js']) {
    fs.copyFileSync(path.join(root, 'scripts', 'common', file), path.join(hooks, 'common', file));
  }
  fs.copyFileSync(
    path.join(root, 'scripts', 'macos', 'deepseek', 'launch-deepseek-gateway.sh'),
    path.join(hooks, 'macos', 'deepseek', 'launch-deepseek-gateway.sh'),
  );
  fs.writeFileSync(path.join(hooks, 'macos', 'launch-claude-safe.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });

  const result = require('node:child_process').spawnSync(
    'bash', [path.join(hooks, 'macos', 'deepseek', 'launch-deepseek-gateway.sh'), workspace],
    { env: { ...process.env, HOME: fakeHome, DS_GATEWAY_PORT: '8798', AI_SAFE_LOG_DIR: path.join(fakeHome, 'logs') }, encoding: 'utf8' },
  );
  assert.notStrictEqual(result.status, 0, 'キー未登録では起動しない');
  assert.match(result.stdout + result.stderr, /DeepSeek APIキーが未登録/);
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
  assert.match(script, /ANTHROPIC_MODEL="deepseek-v4-flash\[1m\]"/);
  assert.match(script, /ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-v4-flash\[1m\]"/);
  assert.match(script, /ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-flash\[1m\]"/);
  assert.match(script, /ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"/);
  assert.match(script, /CLAUDE_CODE_SUBAGENT_MODEL="deepseek-v4-flash"/);
  assert.match(script, /CLAUDE_CODE_EFFORT_LEVEL="max"/);
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
      '[ "$ANTHROPIC_MODEL" = "deepseek-v4-flash[1m]" ] || exit 7',
      '[ "$ANTHROPIC_DEFAULT_OPUS_MODEL" = "deepseek-v4-flash[1m]" ] || exit 10',
      '[ "$ANTHROPIC_DEFAULT_SONNET_MODEL" = "deepseek-v4-flash[1m]" ] || exit 11',
      '[ "$ANTHROPIC_DEFAULT_HAIKU_MODEL" = "deepseek-v4-flash" ] || exit 12',
      '[ "$CLAUDE_CODE_SUBAGENT_MODEL" = "deepseek-v4-flash" ] || exit 13',
      '[ "$CLAUDE_CODE_EFFORT_LEVEL" = "max" ] || exit 14',
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

// 素性が確かめられる gateway（自分たちの ds-gateway.js・中身も同じ）が既に動いていれば、
// 停止せずそのまま使う。これが無いと、2 枚目の窓を開いた時点で 1 枚目の合言葉が無効になり、
// 先に開いていた窓が「Unauthorized」で全部止まる（教室で頻発した事象）。
test('macOS DeepSeek launcher reuses a healthy gateway instead of restarting it', async (t) => {
  const { ensureToken } = require('../gateway-token.js');
  const root = path.join(__dirname, '..', '..', '..');
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-reuse-'));
  const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-reuse-home-'));
  t.after(() => {
    fs.rmSync(workspace, { recursive: true, force: true });
    fs.rmSync(fakeHome, { recursive: true, force: true });
  });
  fs.mkdirSync(path.join(fakeHome, '.deepseek-claude'), { recursive: true });
  fs.writeFileSync(path.join(fakeHome, '.deepseek-claude', 'auth'), 'ds-test-key-never-log\n', { mode: 0o600 });

  const hooks = path.join(workspace, '.ai-safety', 'hooks');
  fs.mkdirSync(path.join(hooks, 'common'), { recursive: true });
  fs.mkdirSync(path.join(hooks, 'macos', 'deepseek'), { recursive: true });
  for (const file of ['ds-gateway.js', 'gateway-token.js', 'secret-patterns.js', 'token-map.js', 'denylist.js']) {
    fs.copyFileSync(path.join(root, 'scripts', 'common', file), path.join(hooks, 'common', file));
  }
  fs.copyFileSync(
    path.join(root, 'scripts', 'macos', 'deepseek', 'launch-deepseek-gateway.sh'),
    path.join(hooks, 'macos', 'deepseek', 'launch-deepseek-gateway.sh'),
  );
  fs.writeFileSync(path.join(hooks, 'macos', 'launch-claude-safe.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });

  // 先に開いている窓の gateway を再現する（合言葉は共有ファイルから取る＝ランチャーと同じ経路）。
  const gatewayJs = path.join(hooks, 'common', 'ds-gateway.js');
  const tokenFile = path.join(fakeHome, '.deepseek-claude', 'gateway-token');
  const shared = ensureToken({ file: tokenFile, gatewayPath: gatewayJs });
  const running = spawn(process.execPath, [gatewayJs], {
    env: {
      ...process.env,
      HOME: fakeHome,
      DS_GATEWAY_PORT: '8797',
      DS_GATEWAY_TOKEN: shared.token,
      DS_GATEWAY_AUTH_FILE: path.join(fakeHome, '.deepseek-claude', 'auth'),
      AI_SAFE_LOG_DIR: path.join(fakeHome, 'logs'),
    },
    stdio: 'ignore',
  });
  t.after(() => { if (!running.killed) running.kill('SIGKILL'); });
  await waitForHealth(8797);

  const launcher = spawn('bash', [path.join(hooks, 'macos', 'deepseek', 'launch-deepseek-gateway.sh'), workspace], {
    env: {
      ...process.env,
      HOME: fakeHome,
      DS_GATEWAY_PORT: '8797',
      AI_SAFE_LOG_DIR: path.join(fakeHome, 'logs'),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  let err = '';
  launcher.stdout.on('data', (c) => { out += c; });
  launcher.stderr.on('data', (c) => { err += c; });
  const code = await waitForExit(launcher);

  assert.strictEqual(code, 0, `stdout:\n${out}\nstderr:\n${err}`);
  assert.match(out, /稼働中の送信検査 Gateway をそのまま使います/, '動いている gateway は立て直さない');
  assert.strictEqual(running.exitCode, null, '先に開いていた窓の gateway を停止してはいけない');
  assert.doesNotMatch(out + err, /ds-test-key-never-log/, 'キー本文を出力しない');
  assert.doesNotMatch(out + err, /[0-9a-f]{64}/, '合言葉を出力しない');
});
