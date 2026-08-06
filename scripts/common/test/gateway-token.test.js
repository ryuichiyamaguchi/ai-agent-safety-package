'use strict';
// 送信検査 Gateway の合言葉共有（複数窓の同時起動を可能にする土台）の回帰テスト。
//
// ここで守りたいこと:
//   1. 合言葉は一度作ったら変わらない（変わると、開きっぱなしの窓が 401 になる）
//   2. 合言葉ファイルは本人だけが読める（実キーと同じ扱い）
//   3. 「生きている・中身が同じ」gateway だけを再利用する（古い gateway は使い回さない）
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawnSync } = require('node:child_process');

const {
  ensureToken,
  readTokenFile,
  recordGatewayStart,
  gatewayFingerprint,
  probeReusable,
} = require('../gateway-token.js');

const GATEWAY_JS = path.join(__dirname, '..', 'ds-gateway.js');
const TOKEN_TOOL = path.join(__dirname, '..', 'gateway-token.js');

function tmpTokenFile(name) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `gwtok-${name}-`));
  return path.join(dir, 'gateway-token');
}

function startFakeGateway() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      if (req.method === 'GET' && req.url === '/healthz') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end('{"status":"ok"}');
        return;
      }
      res.writeHead(404);
      res.end();
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

test('合言葉は一度作られたら再起動をまたいで変わらない', () => {
  const file = tmpTokenFile('stable');
  const first = ensureToken({ file, gatewayPath: GATEWAY_JS });
  assert.match(first.token, /^[0-9a-f]{64}$/);
  assert.strictEqual(first.created, true);

  const second = ensureToken({ file, gatewayPath: GATEWAY_JS });
  assert.strictEqual(second.token, first.token, '2 回目の起動で合言葉が変わってはいけない');
  assert.strictEqual(second.created, false);
});

test('合言葉ファイルは本人だけが読める権限で作られる', { skip: process.platform === 'win32' }, () => {
  const file = tmpTokenFile('perm');
  ensureToken({ file, gatewayPath: GATEWAY_JS });
  const mode = fs.statSync(file).mode & 0o777;
  assert.strictEqual(mode, 0o600, `合言葉ファイルは 0600 であること (実際: ${mode.toString(8)})`);
});

test('壊れた合言葉ファイルは作り直される（読めない合言葉は誰も使えないため）', () => {
  const file = tmpTokenFile('broken');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, 'not json at all');
  const ensured = ensureToken({ file, gatewayPath: GATEWAY_JS });
  assert.match(ensured.token, /^[0-9a-f]{64}$/);
  assert.strictEqual(readTokenFile(file).token, ensured.token);
});

test('gateway の起動記録は合言葉を保ったまま素性だけを更新する', () => {
  const file = tmpTokenFile('record');
  const ensured = ensureToken({ file, gatewayPath: GATEWAY_JS });
  const recorded = recordGatewayStart({ file, gatewayPath: GATEWAY_JS, port: 8788, pid: 4242 });

  assert.strictEqual(recorded.token, ensured.token, '起動記録で合言葉を作り直してはいけない');
  assert.strictEqual(recorded.pid, 4242);
  assert.strictEqual(recorded.port, 8788);
  assert.strictEqual(recorded.gateway_fingerprint, gatewayFingerprint(GATEWAY_JS));
  assert.match(recorded.started_at, /^\d{4}-\d{2}-\d{2}T/);
});

test('gateway が listen していなければ再利用しない', async () => {
  const file = tmpTokenFile('dead');
  recordGatewayStart({ file, gatewayPath: GATEWAY_JS, port: 8788, pid: 1 });
  // 誰も listen していないポート（0 番は使えないので、閉じた直後のポートを使う）
  const server = await startFakeGateway();
  const deadPort = server.address().port;
  await new Promise((resolve) => server.close(resolve));

  const result = await probeReusable({ file, gatewayPath: GATEWAY_JS, port: deadPort });
  assert.strictEqual(result.reusable, false);
  assert.strictEqual(result.reason, 'not-listening');
});

test('合言葉ファイルが無ければ再利用しない', async () => {
  const file = tmpTokenFile('missing');
  const server = await startFakeGateway();
  try {
    const result = await probeReusable({ file, gatewayPath: GATEWAY_JS, port: server.address().port });
    assert.strictEqual(result.reusable, false);
    assert.strictEqual(result.reason, 'no-token-file');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('中身が違う gateway（更新後に居座った古いもの）は再利用しない', async () => {
  const file = tmpTokenFile('stale');
  const server = await startFakeGateway();
  try {
    recordGatewayStart({ file, gatewayPath: GATEWAY_JS, port: server.address().port, pid: 1 });
    // 指紋だけを別物に書き換える＝「今から使いたい ds-gateway.js とは違う gateway」
    const info = readTokenFile(file);
    fs.writeFileSync(file, `${JSON.stringify({ ...info, gateway_fingerprint: 'deadbeef'.repeat(4) })}\n`);

    const result = await probeReusable({ file, gatewayPath: GATEWAY_JS, port: server.address().port });
    assert.strictEqual(result.reusable, false);
    assert.strictEqual(result.reason, 'fingerprint-mismatch');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('生きていて中身も同じ gateway は再利用する（＝2 枚目の窓が 401 にならない）', async () => {
  const file = tmpTokenFile('reuse');
  const server = await startFakeGateway();
  try {
    const recorded = recordGatewayStart({ file, gatewayPath: GATEWAY_JS, port: server.address().port, pid: 1 });
    const result = await probeReusable({ file, gatewayPath: GATEWAY_JS, port: server.address().port });
    assert.strictEqual(result.reusable, true);
    assert.strictEqual(result.token, recorded.token, '再利用時は同じ合言葉を返すこと');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

// ランチャー（bash / PowerShell）はこの CLI 経由で同じ判断を行う。
test('CLI: --ensure は合言葉を標準出力に出し、2 回目も同じ値を返す', () => {
  const file = tmpTokenFile('cli-ensure');
  const args = [TOKEN_TOOL, '--ensure', '--gateway', GATEWAY_JS, '--file', file];
  const first = spawnSync(process.execPath, args, { encoding: 'utf8' });
  assert.strictEqual(first.status, 0, first.stderr);
  assert.match(first.stdout.trim(), /^[0-9a-f]{64}$/);

  const second = spawnSync(process.execPath, args, { encoding: 'utf8' });
  assert.strictEqual(second.stdout.trim(), first.stdout.trim());
});

test('CLI: --probe は再利用できないとき非ゼロで終わる（＝ランチャーは立て直す）', () => {
  const file = tmpTokenFile('cli-probe');
  const probe = spawnSync(
    process.execPath,
    [TOKEN_TOOL, '--probe', '--gateway', GATEWAY_JS, '--file', file, '--port', '1'],
    { encoding: 'utf8' },
  );
  assert.notStrictEqual(probe.status, 0);
  assert.strictEqual(probe.stdout, '', '再利用できないときに合言葉を出力してはいけない');
});
