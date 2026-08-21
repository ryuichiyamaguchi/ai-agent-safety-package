// d-claude（DeepSeek バックエンドの Claude Code）まわりの回帰テスト。
//
// 背景（2026-08-21・mac 実機で実測）:
//   Claude Code が出す
//     "There's an issue with the selected model (deepseek-v4-flash).
//      It may not exist or you may not have access to it."
//   は **POST /v1/messages が HTTP 404 を返したときだけ** 出る。本文の形は問わない
//   （Anthropic 形式でも `{"error":"Not Found"}` でも同じ）。401 では出ない。
//   `/v1/models` を 404 にしても、モデル一覧に別 ID しか無くても出ない。
//   ＝このメッセージは「モデル名が悪い」ではなく「送り先が 404 を返した」の意味。
//   そのため ds-gateway は上流の 4xx/5xx を必ずログに残す（切り分け不能をなくす）。
//
// このファイルが固定するのは次の 3 点:
//   (1) gateway が /v1/messages のパス・クエリ・ステータスを素通しすること
//   (2) 上流 4xx/5xx を upstream_error としてイベントログに残すこと
//   (3) 既定は deepseek-v4-flash のまま、/model から deepseek-v4-pro を選べる形になっていること

const { test } = require('node:test');
const assert = require('node:assert');
const nodeHttp = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const TEST_TOKEN = 'test-gateway-token-0123456789abcdef';
process.env.DS_GATEWAY_TOKEN = TEST_TOKEN;
const LOG_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-gw-log-'));
process.env.AI_SAFE_LOG_DIR = LOG_DIR;

const { createGateway } = require('../ds-gateway.js');

const repoRoot = path.resolve(__dirname, '..', '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');

function startUpstream(handler) {
  return new Promise((resolve) => {
    const s = nodeHttp.createServer(handler);
    s.listen(0, '127.0.0.1', () => resolve(s));
  });
}

function postJson(port, reqPath, obj) {
  return new Promise((resolve, reject) => {
    const data = Buffer.from(JSON.stringify(obj));
    const r = nodeHttp.request({
      host: '127.0.0.1', port, path: reqPath, method: 'POST',
      headers: {
        'content-type': 'application/json',
        'content-length': data.length,
        authorization: `Bearer ${TEST_TOKEN}`,
      },
    }, (res) => {
      let b = '';
      res.on('data', (c) => (b += c));
      res.on('end', () => resolve({ status: res.statusCode, body: b }));
    });
    r.on('error', reject);
    r.end(data);
  });
}

function eventLogLines() {
  const file = path.join(LOG_DIR, 'ds-gateway-events.jsonl');
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

test('gateway は /v1/messages のパス・クエリ・ステータスをそのまま上流へ渡す', async () => {
  const seen = [];
  const up = await startUpstream((req, res) => {
    seen.push(`${req.method} ${req.url}`);
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
  });
  const upPort = up.address().port;
  const gw = createGateway({
    upstream: `http://127.0.0.1:${upPort}/anthropic`,
    port: 0, upstreamKey: 'dummy-upstream-key', authToken: TEST_TOKEN, denylistTerms: [],
  });
  const server = await gw.listen();
  const port = server.address().port;
  try {
    const r = await postJson(port, '/v1/messages?beta=true', { model: 'deepseek-v4-flash', messages: [] });
    assert.strictEqual(r.status, 200);
    // Claude Code が実際に叩く形（実測）。ここが崩れると上流が 404 を返し、
    // 画面には「モデルが存在しない」という無関係なメッセージだけが出る。
    assert.deepStrictEqual(seen, ['POST /anthropic/v1/messages?beta=true']);
  } finally {
    server.close(); up.close();
  }
});

test('上流の 404 はステータスを保ったまま返り、upstream_error としてログに残る', async () => {
  const up = await startUpstream((req, res) => {
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end('{"type":"error","error":{"type":"not_found_error","message":"model not found"}}');
  });
  const upPort = up.address().port;
  const gw = createGateway({
    upstream: `http://127.0.0.1:${upPort}/anthropic`,
    port: 0, upstreamKey: 'dummy-upstream-key', authToken: TEST_TOKEN, denylistTerms: [],
  });
  const server = await gw.listen();
  const port = server.address().port;
  try {
    const r = await postJson(port, '/v1/messages?beta=true', { model: 'deepseek-v4-flash', messages: [] });
    assert.strictEqual(r.status, 404, '上流のステータスを握りつぶしてはいけない');
    const errs = eventLogLines().filter((e) => e.event === 'upstream_error');
    const hit = errs.find((e) => e.status === 404 && e.path === '/anthropic/v1/messages');
    assert.ok(hit, `upstream_error が記録されていない: ${JSON.stringify(errs)}`);
    assert.match(hit.body, /not_found_error/);
  } finally {
    server.close(); up.close();
  }
});

test('d-claude の既定は V4 Flash のまま、/model の一覧に V4 Pro が出る', () => {
  const targets = [
    'scripts/macos/launch-integrated.sh',
    'scripts/macos/deepseek/起動-Claude-DeepSeek.command',
    'scripts/windows/launch-integrated.ps1',
  ];
  for (const rel of targets) {
    const src = read(rel);
    assert.match(src, /ANTHROPIC_MODEL\s*=?\s*["']?deepseek-v4-flash/,
      `${rel}: 既定モデルが deepseek-v4-flash でない`);
    assert.match(src, /ANTHROPIC_CUSTOM_MODEL_OPTION\s*=\s*["']deepseek-v4-pro["']/,
      `${rel}: /model の一覧に deepseek-v4-pro が出ない`);
  }
});

test('claude-safe / 長時間おまかせは d-claude の追加 env を残さない（置き土産の封鎖）', () => {
  const targets = [
    'scripts/macos/launch-claude-safe.sh',
    'scripts/windows/launch-claude-safe.ps1',
    'scripts/macos/launch-longrun.sh',
    'scripts/windows/launch-longrun.ps1',
  ];
  for (const rel of targets) {
    const src = read(rel);
    for (const v of ['ANTHROPIC_CUSTOM_MODEL_OPTION',
      'ANTHROPIC_CUSTOM_MODEL_OPTION_NAME', 'ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION']) {
      assert.ok(src.includes(v), `${rel}: ${v} を消していない`);
    }
  }
});

test('/モデル コマンドが配布物にあり、必要な案内をすべて含む', () => {
  const rel = 'workspace-template/dist-claude-commands/モデル.md';
  const src = read(rel);
  assert.match(src, /^---\r?\ndescription:/, 'frontmatter の description が無い');
  assert.ok(src.includes('/model deepseek-v4-pro'), 'Pro への切り替え方が書かれていない');
  assert.ok(src.includes('/model deepseek-v4-flash'), 'Flash へ戻す方法が書かれていない');
  assert.ok(src.includes('この会話のあいだだけ'), 'その場かぎりである説明が無い');
  assert.ok(/料金が高く/.test(src), '料金が変わる旨の一言が無い');
  assert.ok(!/[0-9０-９]+\s*(円|ドル|\$|USD)/.test(src), '金額を書いてはいけない');
  // OpenCode / Claude Code とも、コマンド本文の !`...` はテンプレート展開時に
  // 受講者のシェルへ直接渡って実行される。指示書に書いてはいけない。
  assert.ok(!/!`/.test(src), 'コマンド本文に !`...` を書いてはいけない');
});

test('install（両OS）が dist-claude-commands をハッシュ検証して .claude/commands へ配置する', () => {
  const mac = read('scripts/macos/install.sh');
  assert.match(mac, /dist-claude-commands/, 'mac install が配布元を参照していない');
  assert.match(mac, /\.claude\/commands/, 'mac install が配置先を持たない');
  assert.match(mac, /workspace-template\/dist-claude-commands\/\*/,
    'mac install でハッシュ登録漏れが fail-closed になっていない');

  const win = read('scripts/windows/install.ps1');
  assert.ok(win.includes('dist-claude-commands'), 'Windows install が配布元を参照していない');
  assert.ok(win.includes('.claude\\commands'), 'Windows install が配置先を持たない');
  assert.ok(win.includes("'workspace-template/dist-claude-commands/'"),
    'Windows install でハッシュ登録漏れが fail-closed になっていない');
});

test('配布する .claude 用コマンドは 1 枚残らず改ざん検知の表に載っている', () => {
  const dir = path.join(repoRoot, 'workspace-template/dist-claude-commands');
  const versions = read('docs/tested_versions.md');
  for (const name of fs.readdirSync(dir).filter((f) => f.endsWith('.md'))) {
    const rel = `workspace-template/dist-claude-commands/${name}`;
    assert.ok(versions.includes(`| ${rel} |`), `${rel} のハッシュ行が docs/tested_versions.md に無い`);
  }
});
