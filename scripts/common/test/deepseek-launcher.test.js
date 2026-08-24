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

  for (const file of ['ds-gateway.js', 'gateway-token.js', 'secret-patterns.js', 'token-map.js', 'denylist.js', 'secret-store.js']) {
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
  for (const file of ['ds-gateway.js', 'gateway-token.js', 'secret-patterns.js', 'token-map.js', 'denylist.js', 'secret-store.js']) {
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
  // モデル名に [1m] を付けると Claude Code 2.1.226 以降は「そんなモデルは無い」で
  // 起動できなくなる（実機で再現）。1M コンテキストは env で伝える。
  assert.match(script, /ANTHROPIC_MODEL="deepseek-v4-flash"/);
  assert.match(script, /ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-v4-flash"/);
  assert.match(script, /ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-flash"/);
  assert.match(script, /CLAUDE_CODE_MAX_CONTEXT_TOKENS="1048576"/);
  assert.doesNotMatch(script, /deepseek-v4-flash\[1m\]/, 'モデル名に [1m] を残さないこと');
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
      // v1.17.0: 実キーは統合ランチャーでは読まない（Gateway 子プロセスだけが読む）。
      // ANTHROPIC_AUTH_TOKEN は gateway が「起動限りの合言葉」で上書きするので、
      // ここへ来た時点では空でなければならない。
      '[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] || exit 8',
      '[ "$ANTHROPIC_MODEL" = "deepseek-v4-flash" ] || exit 7',
      '[ "$ANTHROPIC_DEFAULT_OPUS_MODEL" = "deepseek-v4-flash" ] || exit 10',
      '[ "$ANTHROPIC_DEFAULT_SONNET_MODEL" = "deepseek-v4-flash" ] || exit 11',
      '[ "$CLAUDE_CODE_MAX_CONTEXT_TOKENS" = "1048576" ] || exit 12',
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
  for (const file of ['ds-gateway.js', 'gateway-token.js', 'secret-patterns.js', 'token-map.js', 'denylist.js', 'secret-store.js']) {
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

// 既定ポート 8788 が別のプログラム（安全パッケージとは無関係な常駐サービス等）に
// 取られている PC が実在した。決め打ちのままだと gateway が bind できず、
// 「送信検査 Gateway を確認できない」で起動そのものができなくなる。
test('macOS DeepSeek launcher falls back to another port when 8788 is taken', async (t) => {
  const http = require('node:http');
  const { readTokenFile } = require('../gateway-token.js');
  const root = path.join(__dirname, '..', '..', '..');

  // 8788 を「gateway ではない何か」で塞ぐ。既に他のプログラムが使っていれば、
  // その状態こそが再現したい状況なのでそのまま進める。
  let blocker = null;
  try {
    blocker = await new Promise((resolve, reject) => {
      const s = http.createServer((req, res) => {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end('{"ok":true,"role":"not-a-gateway"}');
      });
      s.on('error', reject);
      s.listen(8788, '127.0.0.1', () => resolve(s));
    });
  } catch (_) {
    blocker = null;
  }
  t.after(() => { if (blocker) blocker.close(); });

  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-fallback-'));
  const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-fallback-home-'));
  t.after(() => {
    fs.rmSync(workspace, { recursive: true, force: true });
    fs.rmSync(fakeHome, { recursive: true, force: true });
  });
  fs.mkdirSync(path.join(fakeHome, '.deepseek-claude'), { recursive: true });
  fs.writeFileSync(path.join(fakeHome, '.deepseek-claude', 'auth'), 'ds-test-key-never-log\n', { mode: 0o600 });

  const hooks = path.join(workspace, '.ai-safety', 'hooks');
  fs.mkdirSync(path.join(hooks, 'common'), { recursive: true });
  fs.mkdirSync(path.join(hooks, 'macos', 'deepseek'), { recursive: true });
  for (const file of ['ds-gateway.js', 'gateway-token.js', 'secret-patterns.js', 'token-map.js', 'denylist.js', 'secret-store.js']) {
    fs.copyFileSync(path.join(root, 'scripts', 'common', file), path.join(hooks, 'common', file));
  }
  fs.copyFileSync(
    path.join(root, 'scripts', 'macos', 'deepseek', 'launch-deepseek-gateway.sh'),
    path.join(hooks, 'macos', 'deepseek', 'launch-deepseek-gateway.sh'),
  );
  fs.writeFileSync(path.join(hooks, 'macos', 'launch-claude-safe.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });

  // DS_GATEWAY_PORT は渡さない（＝自動選択に任せる）。
  const env = { ...process.env, HOME: fakeHome, AI_SAFE_LOG_DIR: path.join(fakeHome, 'logs') };
  delete env.DS_GATEWAY_PORT;
  const launcher = spawn('bash', [path.join(hooks, 'macos', 'deepseek', 'launch-deepseek-gateway.sh'), workspace], {
    env, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  let err = '';
  launcher.stdout.on('data', (c) => { out += c; });
  launcher.stderr.on('data', (c) => { err += c; });
  const code = await waitForExit(launcher);

  assert.strictEqual(code, 0, `stdout:\n${out}\nstderr:\n${err}`);
  const info = readTokenFile(path.join(fakeHome, '.deepseek-claude', 'gateway-token'));
  assert.ok(info, '合言葉ファイルが作られること');
  assert.ok(info.port > 0, 'gateway が使ったポートが記録されること');
  assert.notStrictEqual(info.port, 8788, '塞がれた 8788 ではなく別のポートで起動すること');
  assert.match(out, /8788 は他のプログラムが使っていたため/, '別ポートを使ったことを利用者に伝えること');
  assert.doesNotMatch(out + err, /ds-test-key-never-log/, 'キー本文を出力しない');
  assert.doesNotMatch(out + err, /[0-9a-f]{64}/, '合言葉を出力しない');
});

// ★ 実機で踏んだ事故の回帰テスト。
// 候補ポートに「別の gateway」(別ワークスペースから起動されたもの) が動いていると、
// healthz は正常に応答する。自分の gateway は bind に失敗して終了しているのに、その応答を
// 自分のものと取り違えて相乗りしていた（別の検査設定を通って通信することになる）。
// bash のバックグラウンドジョブは即死しても zombie として残り kill -0 が通るため、
// 「プロセスが生きているか」だけでは防げない。gateway が listen 直後に出す
// "listening on 127.0.0.1:<port> pid=<pid>" の pid 照合で確定させる。
test('macOS DeepSeek launcher does not attach to another gateway on the same port', async (t) => {
  const http = require('node:http');
  const { readTokenFile } = require('../gateway-token.js');
  const root = path.join(__dirname, '..', '..', '..');

  // 「別の gateway」を装う: /healthz に正常応答を返すだけのサーバー。
  // 既定 8788 が既に他プログラムに使われている環境ではそのまま進める（同じ状況なので）。
  let impostor = null;
  try {
    impostor = await new Promise((resolve, reject) => {
      const s = http.createServer((req, res) => {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end('{"status":"ok"}');
      });
      s.on('error', reject);
      s.listen(8788, '127.0.0.1', () => resolve(s));
    });
  } catch (_) {
    impostor = null;
  }
  t.after(() => { if (impostor) impostor.close(); });

  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-impostor-'));
  const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-impostor-home-'));
  t.after(() => {
    fs.rmSync(workspace, { recursive: true, force: true });
    fs.rmSync(fakeHome, { recursive: true, force: true });
  });
  fs.mkdirSync(path.join(fakeHome, '.deepseek-claude'), { recursive: true });
  fs.writeFileSync(path.join(fakeHome, '.deepseek-claude', 'auth'), 'ds-test-key-never-log\n', { mode: 0o600 });

  const hooks = path.join(workspace, '.ai-safety', 'hooks');
  fs.mkdirSync(path.join(hooks, 'common'), { recursive: true });
  fs.mkdirSync(path.join(hooks, 'macos', 'deepseek'), { recursive: true });
  for (const file of ['ds-gateway.js', 'gateway-token.js', 'secret-patterns.js', 'token-map.js', 'denylist.js', 'secret-store.js']) {
    fs.copyFileSync(path.join(root, 'scripts', 'common', file), path.join(hooks, 'common', file));
  }
  fs.copyFileSync(
    path.join(root, 'scripts', 'macos', 'deepseek', 'launch-deepseek-gateway.sh'),
    path.join(hooks, 'macos', 'deepseek', 'launch-deepseek-gateway.sh'),
  );
  fs.writeFileSync(path.join(hooks, 'macos', 'launch-claude-safe.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });

  const env = { ...process.env, HOME: fakeHome, AI_SAFE_LOG_DIR: path.join(fakeHome, 'logs') };
  delete env.DS_GATEWAY_PORT;
  const launcher = spawn('bash', [path.join(hooks, 'macos', 'deepseek', 'launch-deepseek-gateway.sh'), workspace], {
    env, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  let err = '';
  launcher.stdout.on('data', (c) => { out += c; });
  launcher.stderr.on('data', (c) => { err += c; });
  const code = await waitForExit(launcher);

  assert.strictEqual(code, 0, `stdout:\n${out}\nstderr:\n${err}`);
  const info = readTokenFile(path.join(fakeHome, '.deepseek-claude', 'gateway-token'));
  assert.ok(info, '合言葉ファイルが作られること');
  assert.ok(info.port > 0, '自分の gateway が実際に listen したポートが記録されること');
  assert.notStrictEqual(info.port, 8788, '別の gateway が応答しているポートに相乗りしてはいけない');
  assert.ok(info.pid > 0, '記録された PID は自分で立てた gateway のもの');
});

// ---------------------------------------------------------------------------
// v1.17.0 回帰: 秘密の金庫化で旧平文 ~/.deepseek-claude/auth は削除される。
// d-claude の起動条件がその平文ファイルの実在のままだと、金庫に鍵があるのに
// 「未登録」で起動できない（配布前レビューで RED として実測された不具合）。
// 判定は secret-store.js の resolve()（環境変数 → 金庫 → 旧平文）に一本化する。
// ---------------------------------------------------------------------------

const store = require('../secret-store.js');

function vaultUsable() {
  return process.platform === 'darwin' && store.available();
}

// 偽 HOME を作る。旧平文（~/.deepseek-claude/auth）は置かないが、キーチェーン本体は
// $HOME/Library/Keychains にあるので、そこだけ実 HOME へ symlink して金庫を使えるようにする。
// （実キーは一切使わず、テスト専用の service 接頭辞にダミー値を入れて必ず後始末する）
function makeVaultHome(prefix) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  fs.mkdirSync(path.join(home, 'Library'), { recursive: true });
  fs.symlinkSync(path.join(os.homedir(), 'Library', 'Keychains'), path.join(home, 'Library', 'Keychains'));
  return home;
}

test('統合ランチャー(mac/Windows)は旧平文ファイルの実在を起動条件にしない', () => {
  const root = path.join(__dirname, '..', '..', '..');
  const sh = fs.readFileSync(path.join(root, 'scripts', 'macos', 'launch-integrated.sh'), 'utf8');
  const ps1 = fs.readFileSync(path.join(root, 'scripts', 'windows', 'launch-integrated.ps1'), 'utf8');
  // 平文ファイルの実在チェック・平文の直読みが残っていないこと
  assert.doesNotMatch(sh, /\[\s*-s\s+"\$auth_file"\s*\]/, 'mac: 平文ファイルの実在を条件にしている');
  assert.doesNotMatch(sh, /ANTHROPIC_AUTH_TOKEN="\$\(cat /, 'mac: 平文キーを直読みしている');
  assert.doesNotMatch(ps1, /Test-Path -LiteralPath \$authFile/, 'Windows: 平文ファイルの実在を条件にしている');
  assert.doesNotMatch(ps1, /ReadAllText\(\$authFile\)/, 'Windows: 平文キーを直読みしている');
  // 解決結果（secret-store.js）で判定していること
  assert.match(sh, /secret-store\.js/);
  assert.match(sh, /--has deepseek/);
  assert.match(ps1, /secret-store\.js/);
  assert.match(ps1, /'--has'\s*,?\s*'deepseek'/);
});

test('secret-store.js --has は値を出さずに登録の有無だけを返す', { skip: vaultUsable() ? false : 'OS の金庫を使えない環境のため skip' }, (t) => {
  const root = path.join(__dirname, '..', '..', '..');
  const script = path.join(root, 'scripts', 'common', 'secret-store.js');
  const prefix = `ai-safety-test-has-${process.pid}.`;
  const env = { ...process.env, AI_SAFE_KEYCHAIN_PREFIX: prefix, HOME: makeVaultHome('has-home-') };
  delete env.DEEPSEEK_API_KEY;
  const restore = process.env.AI_SAFE_KEYCHAIN_PREFIX;
  process.env.AI_SAFE_KEYCHAIN_PREFIX = prefix;
  t.after(() => {
    try { store.remove('deepseek'); } catch { /* ignore */ }
    if (restore === undefined) delete process.env.AI_SAFE_KEYCHAIN_PREFIX;
    else process.env.AI_SAFE_KEYCHAIN_PREFIX = restore;
    fs.rmSync(env.HOME, { recursive: true, force: true });
  });

  const run = () => require('node:child_process').spawnSync(
    process.execPath, [script, '--has', 'deepseek'], { env, encoding: 'utf8', timeout: 60000 });

  let r = run();
  assert.strictEqual(r.stdout.trim(), 'no');
  assert.notStrictEqual(r.status, 0);

  store.set('deepseek', 'ds-dummy-key-never-log-0001');
  r = run();
  assert.strictEqual(r.stdout.trim(), 'yes');
  assert.strictEqual(r.status, 0);
  assert.doesNotMatch(r.stdout + r.stderr, /ds-dummy-key-never-log-0001/, '値そのものを出力しない');
});

// 実測: 平文を消した状態（金庫にだけ鍵がある状態）で d-claude 経路が起動できること。
test('d-claude は平文が無く金庫にだけ鍵があるときも起動する', { skip: vaultUsable() ? false : 'OS の金庫を使えない環境のため skip' }, (t) => {
  const root = path.join(__dirname, '..', '..', '..');
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-vault-only-'));
  const fakeHome = makeVaultHome('ds-vault-only-home-');
  const prefix = `ai-safety-test-vault-${process.pid}.`;
  const restore = process.env.AI_SAFE_KEYCHAIN_PREFIX;
  process.env.AI_SAFE_KEYCHAIN_PREFIX = prefix;
  t.after(() => {
    try { store.remove('deepseek'); } catch { /* ignore */ }
    if (restore === undefined) delete process.env.AI_SAFE_KEYCHAIN_PREFIX;
    else process.env.AI_SAFE_KEYCHAIN_PREFIX = restore;
    fs.rmSync(workspace, { recursive: true, force: true });
    fs.rmSync(fakeHome, { recursive: true, force: true });
  });

  const hooks = path.join(workspace, '.ai-safety', 'hooks', 'macos');
  fs.mkdirSync(path.join(hooks, 'deepseek'), { recursive: true });
  fs.mkdirSync(path.join(workspace, '.ai-safety', 'hooks', 'common'), { recursive: true });
  fs.copyFileSync(path.join(root, 'scripts', 'common', 'secret-store.js'),
    path.join(workspace, '.ai-safety', 'hooks', 'common', 'secret-store.js'));
  fs.copyFileSync(path.join(root, 'scripts', 'macos', 'launch-integrated.sh'), path.join(hooks, 'launch-integrated.sh'));
  fs.chmodSync(path.join(hooks, 'launch-integrated.sh'), 0o755);
  fs.writeFileSync(path.join(hooks, 'open-monitor.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });
  fs.writeFileSync(path.join(hooks, 'launch-deepseek-safe.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });
  fs.writeFileSync(path.join(hooks, 'deepseek', 'launch-deepseek-gateway.sh'), [
    '#!/usr/bin/env bash',
    '[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] || exit 8',
    `printf gateway > "${path.join(workspace, 'gateway-called')}"`,
  ].join('\n') + '\n', { mode: 0o755 });

  // 旧平文は存在しない（金庫化で削除された状態）。
  assert.ok(!fs.existsSync(path.join(fakeHome, '.deepseek-claude', 'auth')));

  const env = {
    ...process.env,
    HOME: fakeHome,
    AI_SAFE_KEYCHAIN_PREFIX: prefix,
    AI_SAFE_LOG_DIR: path.join(fakeHome, 'logs'),
  };
  delete env.DEEPSEEK_API_KEY;
  const run = () => require('node:child_process').spawnSync(
    'bash', [path.join(hooks, 'launch-integrated.sh'), workspace, 'd-claude', 'standard'],
    { env, encoding: 'utf8', timeout: 120000 });

  // 1) 金庫にも平文にも無い → 未登録で止まる（fail-closed は維持）
  let r = run();
  assert.notStrictEqual(r.status, 0, '未登録なのに起動した');
  assert.match(r.stdout + r.stderr, /DeepSeek APIキーが未登録/);

  // 2) 金庫にだけダミー鍵がある → 起動できる（これが今回の RED の回帰）
  store.set('deepseek', 'ds-dummy-key-never-log-0002');
  r = run();
  assert.strictEqual(r.status, 0, `金庫に鍵があるのに起動しない:\n${r.stdout}\n${r.stderr}`);
  assert.strictEqual(fs.readFileSync(path.join(workspace, 'gateway-called'), 'utf8'), 'gateway');
  assert.doesNotMatch(r.stdout + r.stderr, /ds-dummy-key-never-log-0002/, 'キー本文を出力しない');
});

// ---------------------------------------------------------------------------
// v1.17.0 回帰: 上級 2「DeepSeek-Claudeを起動」
//   (a) キーの有無を解決結果で判定する（平文の実在で誤表示しない）
//   (b) ワークスペースをハードコードせず、自分の位置／引数から解決する
// ---------------------------------------------------------------------------

test('起動-Claude-DeepSeek.command はワークスペースを固定せず鍵も解決結果で見る', () => {
  const root = path.join(__dirname, '..', '..', '..');
  const cmd = fs.readFileSync(
    path.join(root, 'scripts', 'macos', 'deepseek', '起動-Claude-DeepSeek.command'), 'utf8');
  assert.doesNotMatch(cmd, /^WORKSPACE="\$HOME\/Documents\/my-ai-workspace"$/m, 'ワークスペースがハードコードされている');
  assert.match(cmd, /BASH_SOURCE\[0\]/, '自分の位置から作業フォルダを解決していない');
  assert.match(cmd, /WORKSPACE="\$1"/, '引数で作業フォルダを受け取れない');
  assert.doesNotMatch(cmd, /ANTHROPIC_AUTH_TOKEN="\$\(cat /, '平文キーを直読みしている');
  assert.match(cmd, /--has deepseek/, '鍵の有無を解決結果で見ていない');
  // ラッパー（スタートのボタン）が作業フォルダを渡すこと。
  // v1.18.0: 単独ボタンは廃止され「4_AIを起動する」→ menu モードのメニューに集約された
  // （ボタンは menu モードへ委譲し、d-claude の分岐はランチャー本体が持つ）。
  const wrapper = fs.readFileSync(
    path.join(root, 'workspace-template', 'スタート', '4_AIを起動する.command'), 'utf8');
  assert.match(wrapper, /exec bash "\$LAUNCHER" "\$WORKSPACE" menu standard/);
  const launcher = fs.readFileSync(
    path.join(root, 'scripts', 'macos', 'launch-integrated.sh'), 'utf8');
  assert.match(launcher, /agent="d-claude"; profile="standard"/, 'メニューに d-claude の分岐が無い');
});

test('起動-Claude-DeepSeek.command は自分の置き場所の作業フォルダで起動する', () => {
  const root = path.join(__dirname, '..', '..', '..');
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-cmd-ws-'));
  const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-cmd-home-'));
  try {
    const hooks = path.join(workspace, '.ai-safety', 'hooks', 'macos');
    fs.mkdirSync(path.join(hooks, 'deepseek'), { recursive: true });
    fs.copyFileSync(
      path.join(root, 'scripts', 'macos', 'deepseek', '起動-Claude-DeepSeek.command'),
      path.join(hooks, 'deepseek', '起動-Claude-DeepSeek.command'));
    fs.writeFileSync(path.join(hooks, 'launch-claude-safe.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });
    fs.writeFileSync(path.join(hooks, 'launch-deepseek-safe.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });
    fs.writeFileSync(path.join(hooks, 'deepseek', 'launch-deepseek-gateway.sh'), [
      '#!/usr/bin/env bash',
      `printf '%s' "$1" > "${path.join(workspace, 'gateway-workspace')}"`,
    ].join('\n') + '\n', { mode: 0o755 });

    const r = require('node:child_process').spawnSync(
      'bash', [path.join(hooks, 'deepseek', '起動-Claude-DeepSeek.command')],
      { env: { ...process.env, HOME: fakeHome }, cwd: os.tmpdir(), encoding: 'utf8', input: '', timeout: 120000 });
    assert.strictEqual(r.status, 0, r.stdout + r.stderr);
    assert.strictEqual(
      fs.realpathSync(fs.readFileSync(path.join(workspace, 'gateway-workspace'), 'utf8')),
      fs.realpathSync(workspace),
      '自分の置き場所ではない作業フォルダで起動した');
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
    fs.rmSync(fakeHome, { recursive: true, force: true });
  }
});

test('Windows の 起動-Claude-DeepSeek.bat もワークスペース固定をやめ鍵は解決結果で見る', () => {
  const root = path.join(__dirname, '..', '..', '..');
  const p = path.join(root, 'scripts', 'windows', 'deepseek', '起動-Claude-DeepSeek.bat');
  const raw = fs.readFileSync(p);
  // 配布条件: .bat は CP932 + CRLF（BOM なし）
  assert.strictEqual(raw.subarray(0, 3).equals(Buffer.from([0xEF, 0xBB, 0xBF])), false, '.bat に BOM が付いている');
  const lf = raw.toString('binary').split('\n').length - 1;
  const crlf = raw.toString('binary').split('\r\n').length - 1;
  assert.strictEqual(lf, crlf, '.bat の改行が CRLF でない');
  const bat = new TextDecoder('shift_jis').decode(raw);

  assert.doesNotMatch(bat, /^set "WORKSPACE=%USERPROFILE%\\Documents\\my-ai-workspace"$/m,
    'ワークスペースが無条件でハードコードされている');
  assert.match(bat, /%~dp0\.\.\\\.\.\\\.\.\\\.\./, '自分の位置から作業フォルダを解決していない');
  assert.match(bat, /if not "%~1"=="" set "WORKSPACE=%~1"/, '引数で作業フォルダを受け取れない');
  assert.doesNotMatch(bat, /for \/f "usebackq delims=" %%K in \("%AUTH_FILE%"\)/, '平文キーを直読みしている');
  assert.match(bat, /--has deepseek/, '鍵の有無を解決結果で見ていない');

  // v1.18.0: 単独ボタンは廃止され「4_AIを起動する」→ menu モードのメニューに集約された
  // （ボタンは menu モードへ委譲し、d-claude の分岐はランチャー本体が持つ）。
  const wrapperRaw = fs.readFileSync(
    path.join(root, 'workspace-template', 'スタート', '4_AIを起動する.bat'));
  const wrapper = new TextDecoder('shift_jis').decode(wrapperRaw);
  assert.match(wrapper, /-Workspace "%WORKSPACE%" -Agent menu -Profile standard/,
    'ラッパーが作業フォルダを渡していない');
  const launcher = fs.readFileSync(
    path.join(root, 'scripts', 'windows', 'launch-integrated.ps1'), 'utf8');
  assert.match(launcher, /\$Agent = 'd-claude'; \$SafetyProfile = 'standard'/, 'メニューに d-claude の分岐が無い');
});
