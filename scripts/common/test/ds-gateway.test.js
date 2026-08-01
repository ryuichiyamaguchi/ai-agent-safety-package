const { test, after } = require('node:test');
const assert = require('node:assert');
const nodeHttp = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

// gateway は呼び出し元認証（起動ごとの乱数トークン）を必須にしている。テストでは
// 環境変数で既定トークンを与え、リクエスト側は下の http ラッパーで自動的に付与する。
// require より前に立てる（ds-gateway.js が読み込み時に既定値を確定するため）。
const TEST_TOKEN = 'test-gateway-token-0123456789abcdef';
process.env.DS_GATEWAY_TOKEN = TEST_TOKEN;

const { createGateway } = require('../ds-gateway.js');
const { createTokenMap } = require('../token-map.js');
const { loadDenylistResult } = require('../denylist.js');

// 認証以外の回帰テストは「正規の呼び出し元」であることが前提なので、認証ヘッダを
// 明示していないリクエストには自動で正しいトークンを載せる。認証そのものの回帰は
// authorization / x-api-key を明示して 401 を確かめる（自動付与は起きない）。
function withAuth(options) {
  if (!options || typeof options !== 'object') return options;
  const headers = { ...(options.headers || {}) };
  const hasAuth = Object.keys(headers).some((k) => /^(authorization|x-api-key|api-key)$/i.test(k));
  if (!hasAuth) headers.authorization = `Bearer ${TEST_TOKEN}`;
  return { ...options, headers };
}

const http = {
  createServer: (...args) => nodeHttp.createServer(...args),
  get: (options, cb) => nodeHttp.get(withAuth(options), cb),
  request: (options, cb) => nodeHttp.request(withAuth(options), cb),
};

function get(port, path) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    }).on('error', reject);
  });
}

function startUpstream(handler) {
  return new Promise((resolve) => {
    const s = http.createServer(handler);
    s.listen(0, '127.0.0.1', () => resolve(s));
  });
}

function postJson(port, path, obj) {
  return new Promise((resolve, reject) => {
    const data = Buffer.from(JSON.stringify(obj));
    const r = http.request({ host: '127.0.0.1', port, path, method: 'POST',
      headers: { 'content-type': 'application/json', 'content-length': data.length } },
      (res) => { let b=''; res.on('data',c=>b+=c); res.on('end',()=>resolve({status:res.statusCode, body:b})); });
    r.on('error', reject); r.end(data);
  });
}

// Generic request helper for non-POST methods, custom headers, and arbitrary bodies.
function request(port, { path, method = 'GET', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
    const h = { ...headers };
    if (data !== undefined && h['content-length'] === undefined) h['content-length'] = data.length;
    const r = http.request({ host: '127.0.0.1', port, path, method, headers: h },
      (res) => { let b=''; res.on('data',c=>b+=c); res.on('end',()=>resolve({status:res.statusCode, body:b, headers:res.headers})); });
    r.on('error', reject);
    if (data !== undefined) r.end(data); else r.end();
  });
}

// Upstream capture server: records the raw body, full request path (incl. query), and headers it received.
function startCaptureUpstream() {
  const cap = { body: null, path: null, headers: null };
  return new Promise((resolve) => {
    const s = http.createServer((req, res) => {
      let b=''; req.on('data',c=>b+=c); req.on('end',()=>{
        cap.body = b; cap.path = req.url; cap.headers = req.headers;
        res.writeHead(200, {'content-type':'application/json'}); res.end('{}');
      });
    });
    s.listen(0, '127.0.0.1', () => resolve({ server: s, cap }));
  });
}

test('GET /healthz returns 200 ok with no token field', async () => {
  const gw = createGateway({ upstream: 'http://127.0.0.1:1', port: 0 });
  const server = await gw.listen();
  const port = server.address().port;
  after(() => server.close());
  const res = await get(port, '/healthz');
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body, '{"status":"ok"}');
  assert.ok(!res.body.includes('token'), 'healthz must not echo any token');
});

test('GET /status reports runtime metrics without echoing prompts or caller tokens', async (t) => {
  const up = await startUpstream((req, res) => {
    req.resume();
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('data: {"choices":[{"delta":{"content":"hello"}}]}\n\n');
    res.end('data: {"usage":{"prompt_tokens":1200,"completion_tokens":80,"total_tokens":1280}}\n\ndata: [DONE]\n\n');
  });
  t.after(() => up.close());
  const gw = createGateway({
    upstream: `http://127.0.0.1:${up.address().port}`,
    port: 0,
    denylistTerms: [],
    workspace: '/tmp/my-ai-workspace',
  });
  const server = await gw.listen();
  t.after(() => server.close());

  const port = server.address().port;
  const secretPrompt = 'the classroom prompt text must not appear in status';
  const call = await request(port, {
    path: '/v1/chat/completions',
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: { model: 'deepseek-v4-pro', messages: [{ role: 'user', content: secretPrompt }], stream: true },
  });
  assert.strictEqual(call.status, 200);

  const status = await new Promise((resolve, reject) => {
    nodeHttp.get({ host: '127.0.0.1', port, path: '/status' }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    }).on('error', reject);
  });
  assert.strictEqual(status.status, 200);
  const parsed = JSON.parse(status.body);
  assert.strictEqual(parsed.status, 'ok');
  assert.strictEqual(parsed.activity.model, 'deepseek-v4-pro');
  assert.strictEqual(parsed.activity.cwd, '/tmp/my-ai-workspace');
  assert.strictEqual(parsed.activity.tokens.input, 1200);
  assert.strictEqual(parsed.activity.tokens.output, 80);
  assert.strictEqual(parsed.activity.tokens.total, 1280);
  assert.strictEqual(parsed.activity.tokens.source, 'usage');
  assert.strictEqual(parsed.activity.context.limit, 1048576);
  assert.ok(parsed.activity.speed.output_tokens_per_sec >= 0);
  assert.ok(!status.body.includes(secretPrompt));
  assert.ok(!status.body.includes(TEST_TOKEN));
});

// ── M-7: 呼び出し元認証（同一 PC の他プロセス / DNS リバインディング対策）──
test('M-7: gateway refuses to start without a caller auth token (fail-closed)', () => {
  assert.throws(
    () => createGateway({ upstream: 'http://127.0.0.1:1', port: 0, authToken: '' }),
    /DS_GATEWAY_TOKEN/,
  );
  assert.throws(
    () => createGateway({ upstream: 'http://127.0.0.1:1', port: 0, authToken: '   ' }),
    /DS_GATEWAY_TOKEN/,
  );
});

test('M-7: gateway process exits non-zero when DS_GATEWAY_TOKEN is unset', async () => {
  const gwPath = path.join(__dirname, '..', 'ds-gateway.js');
  const env = { ...process.env, DS_GATEWAY_PORT: '0' };
  delete env.DS_GATEWAY_TOKEN;
  const child = spawn(process.execPath, [gwPath], { env, stdio: 'ignore' });
  const code = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('child did not exit without a token')); }, 5000);
    child.on('exit', (c) => { clearTimeout(timer); resolve(c); });
    child.on('error', (e) => { clearTimeout(timer); reject(e); });
  });
  assert.notStrictEqual(code, 0, 'gateway must not listen without caller auth');
});

test('M-7: correct token is forwarded, wrong/missing token is 401 and never reaches upstream', async (t) => {
  let forwarded = 0;
  const up = await startUpstream((req, res) => {
    forwarded += 1; req.resume();
    res.writeHead(200, { 'content-type': 'application/json' }); res.end('{"ok":true}');
  });
  t.after(() => up.close());
  const gw = createGateway({ upstream: `http://127.0.0.1:${up.address().port}`, port: 0, denylistTerms: [] });
  const server = await gw.listen(); t.after(() => server.close());
  const port = server.address().port;
  const body = { messages: [{ role: 'user', content: 'hi' }] };

  const ok = await request(port, { path: '/v1/messages', method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${TEST_TOKEN}` }, body });
  assert.strictEqual(ok.status, 200);
  assert.strictEqual(forwarded, 1);

  // x-api-key でも同じトークンなら通る（OpenCode 系クライアント向け）。
  const viaApiKey = await request(port, { path: '/v1/messages', method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': TEST_TOKEN }, body });
  assert.strictEqual(viaApiKey.status, 200);
  assert.strictEqual(forwarded, 2);

  // 不一致（同じ長さ）
  const wrong = await request(port, { path: '/v1/messages', method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${'x'.repeat(TEST_TOKEN.length)}` }, body });
  assert.strictEqual(wrong.status, 401);

  // 不一致（長さ違い＝timingSafeEqual が throw しないこと込みで確認）
  for (const bad of ['short', `${TEST_TOKEN}extra-suffix-that-makes-it-longer`, TEST_TOKEN.slice(0, -1)]) {
    const res = await request(port, { path: '/v1/messages', method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${bad}` }, body });
    assert.strictEqual(res.status, 401, `token "${bad}" must be rejected`);
  }

  // 欠落
  const missing = await request(port, { path: '/v1/messages', method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': '' }, body });
  assert.strictEqual(missing.status, 401);

  assert.strictEqual(forwarded, 2, '401 requests must never reach upstream');
});

test('M-7: healthz stays reachable without a token (launcher readiness probe)', async (t) => {
  const gw = createGateway({ upstream: 'http://127.0.0.1:1', port: 0 });
  const server = await gw.listen(); t.after(() => server.close());
  const res = await new Promise((resolve, reject) => {
    nodeHttp.get({ host: '127.0.0.1', port: server.address().port, path: '/healthz' }, (r) => {
      let b = ''; r.on('data', (c) => (b += c)); r.on('end', () => resolve({ status: r.statusCode, body: b }));
    }).on('error', reject);
  });
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body, '{"status":"ok"}');
  assert.ok(!res.body.includes(TEST_TOKEN), 'healthz must not echo the caller token');
});

test('second gateway on the same port exits non-zero (bind failure)', async () => {
  // 1つ目を固定ポートで起動 → 同ポートで子プロセスとして2つ目を spawn → 非0で即終了することを確認。
  const first = createGateway({ upstream: 'http://127.0.0.1:1', port: 0 });
  const server = await first.listen();
  const port = server.address().port;
  after(() => server.close());

  const gwPath = path.join(__dirname, '..', 'ds-gateway.js');
  const child = spawn(process.execPath, [gwPath], {
    env: { ...process.env, DS_GATEWAY_PORT: String(port) },
    stdio: 'ignore',
  });
  const code = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('child did not exit on bind failure')); }, 5000);
    child.on('exit', (c) => { clearTimeout(timer); resolve(c); });
    child.on('error', (e) => { clearTimeout(timer); reject(e); });
  });
  assert.notStrictEqual(code, 0, 'second gateway must exit non-zero on EADDRINUSE');
});

test('rejects non-JSON POST body fail-closed (415, not forwarded)', async () => {
  let forwarded = false;
  const up = await startUpstream((req,res)=>{ forwarded = true; req.resume(); res.writeHead(200); res.end(); });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0 });
  const server = await gw.listen(); after(()=>server.close());
  const data = Buffer.from('plain text with sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX');
  const res = await new Promise((resolve,reject)=>{
    const r = http.request({host:'127.0.0.1',port:server.address().port,path:'/v1/messages',method:'POST',
      headers:{'content-type':'text/plain','content-length':data.length}},
      (rs)=>{let b='';rs.on('data',c=>b+=c);rs.on('end',()=>resolve({status:rs.statusCode}));});
    r.on('error',reject); r.end(data);
  });
  assert.strictEqual(res.status, 415);
  assert.strictEqual(forwarded, false);
});

test('masks secrets in messages before forwarding to upstream', async () => {
  let received = null;
  const up = await startUpstream((req, res) => {
    let b=''; req.on('data',c=>b+=c); req.on('end',()=>{ received = b;
      res.writeHead(200, {'content-type':'application/json'}); res.end('{"ok":true}'); });
  });
  after(() => up.close());
  const gw = createGateway({ upstream: `http://127.0.0.1:${up.address().port}`, port: 0 });
  const server = await gw.listen();
  after(() => server.close());

  const reqBody = {
    model: 'deepseek-v4-pro',
    system: 'context with sk-ant-ABCDEFGHIJKLMNOPQRSTUVWX',
    messages: [
      { role: 'user', content: 'my key is sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX' },
      { role: 'user', content: [{ type: 'text', text: 'token=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }] },
    ],
  };
  const res = await postJson(server.address().port, '/v1/messages', reqBody);
  assert.strictEqual(res.status, 200);

  const fwd = JSON.parse(received);
  assert.ok(!received.includes('sk-ant-ABCDEFGHIJKLMNOPQRSTUVWX'));
  assert.ok(!received.includes('sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX'));
  assert.ok(!received.includes('ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'));
  assert.strictEqual(fwd.model, 'deepseek-v4-pro');
  assert.strictEqual(fwd.messages.length, 2);
  assert.strictEqual(typeof fwd.messages[0].content, 'string');
  assert.strictEqual(fwd.messages[1].content[0].type, 'text');
});

test('OpenCode mode injects the upstream key from a local file and never forwards its placeholder', async (t) => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-gateway-auth-'));
  const authFile = path.join(tempDir, 'auth');
  fs.writeFileSync(authFile, 'ds-test-key-from-file\n', { mode: 0o600 });
  t.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));

  const { server: up, cap } = await startCaptureUpstream();
  t.after(() => up.close());
  const gw = createGateway({
    upstream: `http://127.0.0.1:${up.address().port}`,
    upstreamAuthFile: authFile,
    port: 0,
  });
  const server = await gw.listen();
  t.after(() => server.close());

  const res = await request(server.address().port, {
    path: '/v1/chat/completions',
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${TEST_TOKEN}`,
      'x-api-key': TEST_TOKEN,
    },
    body: {
      model: 'deepseek-v4-pro',
      messages: [{ role: 'user', content: 'hello' }],
    },
  });

  assert.strictEqual(res.status, 200);
  assert.strictEqual(cap.headers.authorization, 'Bearer ds-test-key-from-file');
  // ローカル合言葉は upstream へ出さない（local-only の秘密なので DeepSeek 側に残さない）。
  assert.ok(!JSON.stringify(cap.headers).includes(TEST_TOKEN));
  assert.strictEqual(cap.headers['x-api-key'], undefined);
});

test('configured upstream auth file is mandatory and unreadable files fail closed before listen', () => {
  assert.throws(
    () => createGateway({
      upstream: 'http://127.0.0.1:1',
      upstreamAuthFile: path.join(os.tmpdir(), 'definitely-missing-deepseek-auth'),
      port: 0,
    }),
    /auth file/i,
  );
});

test('passes through JSON without messages/system unchanged', async () => {
  let received = null;
  const up = await startUpstream((req,res)=>{ let b=''; req.on('data',c=>b+=c); req.on('end',()=>{received=b; res.writeHead(200); res.end('{}');}); });
  after(()=>up.close());
  const gw = createGateway({ upstream: `http://127.0.0.1:${up.address().port}`, port: 0 });
  const server = await gw.listen(); after(()=>server.close());
  await postJson(server.address().port, '/v1/models', { foo: 'sk-proj-SHOULDNOTBETOUCHEDXXXXXX' });
  assert.ok(received.includes('foo'));
});

test('relays SSE response unbuffered and unmodified, preserving headers', async () => {
  const up = await startUpstream((req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'x-marker': 'abc' });
    res.write('event: message_start\ndata: {"a":1}\n\n');
    setTimeout(() => { res.write('data: {"b":2}\n\n'); res.end(); }, 10);
  });
  after(() => up.close());
  const gw = createGateway({ upstream: `http://127.0.0.1:${up.address().port}`, port: 0 });
  const server = await gw.listen(); after(() => server.close());

  const chunks = [];
  await new Promise((resolve, reject) => {
    const data = Buffer.from(JSON.stringify({ messages: [{ role:'user', content:'hi' }], stream: true }));
    const r = http.request({ host:'127.0.0.1', port: server.address().port, path:'/v1/messages', method:'POST',
      headers:{'content-type':'application/json','content-length':data.length} }, (res) => {
        assert.strictEqual(res.headers['content-type'], 'text/event-stream');
        assert.strictEqual(res.headers['x-marker'], 'abc');
        res.on('data', (c) => chunks.push(c.toString()));
        res.on('end', resolve);
      });
    r.on('error', reject); r.end(data);
  });
  const all = chunks.join('');
  assert.match(all, /event: message_start/);
  assert.match(all, /"b":2/);
  assert.ok(chunks.length >= 2, 'should arrive in multiple chunks (unbuffered)');
});

test('returns 400 for unparseable JSON (fail-closed, not forwarded)', async () => {
  let forwarded = false;
  const up = await startUpstream((req,res)=>{ forwarded = true; res.writeHead(200); res.end(); });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0 });
  const server = await gw.listen(); after(()=>server.close());

  const bad = Buffer.from('{not json');
  const res = await new Promise((resolve,reject)=>{
    const r = http.request({host:'127.0.0.1',port:server.address().port,path:'/v1/messages',method:'POST',
      headers:{'content-type':'application/json','content-length':bad.length}},
      (rs)=>{let b='';rs.on('data',c=>b+=c);rs.on('end',()=>resolve({status:rs.statusCode,body:b}));});
    r.on('error',reject); r.end(bad);
  });
  assert.strictEqual(res.status, 400);
  assert.strictEqual(forwarded, false, 'must not forward unscanned body');
});

test('returns 502 when upstream is unreachable', async () => {
  const gw = createGateway({ upstream:'http://127.0.0.1:1', port:0 });
  const server = await gw.listen(); after(()=>server.close());
  const data = Buffer.from(JSON.stringify({ messages:[{role:'user',content:'hi'}] }));
  const res = await new Promise((resolve,reject)=>{
    const r = http.request({host:'127.0.0.1',port:server.address().port,path:'/v1/messages',method:'POST',
      headers:{'content-type':'application/json','content-length':data.length}},
      (rs)=>{let b='';rs.on('data',c=>b+=c);rs.on('end',()=>resolve({status:rs.statusCode,body:b}));});
    r.on('error',reject); r.end(data);
  });
  assert.strictEqual(res.status, 502);
});

test('masks secrets in nested tool_result and tool_use blocks', async () => {
  let received = null;
  const up = await startUpstream((req,res)=>{ let b=''; req.on('data',c=>b+=c); req.on('end',()=>{received=b; res.writeHead(200,{'content-type':'application/json'}); res.end('{}');}); });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0 });
  const server = await gw.listen(); after(()=>server.close());
  await postJson(server.address().port, '/v1/messages', { messages: [
    { role:'user', content:[{ type:'tool_result', tool_use_id:'x', content:[{ type:'text', text:'env has sk-ant-AAAAAAAAAAAAAAAAAAAAAA here' }] }] },
    { role:'assistant', content:[{ type:'tool_use', id:'y', name:'t', input:{ api_key:'sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX' } }] },
  ]});
  assert.ok(!received.includes('sk-ant-AAAAAAAAAAAAAAAAAAAAAA'), 'tool_result text leaked');
  assert.ok(!received.includes('sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX'), 'tool_use input leaked');
  // structure preserved
  const fwd = JSON.parse(received);
  assert.strictEqual(fwd.messages[0].content[0].type, 'tool_result');
  assert.strictEqual(fwd.messages[1].content[0].type, 'tool_use');
});

test('masks .content even when a block also carries .text (no scan-evasion)', async () => {
  let received = null;
  const up = await startUpstream((req,res)=>{ let b=''; req.on('data',c=>b+=c); req.on('end',()=>{received=b; res.writeHead(200,{'content-type':'application/json'}); res.end('{}');}); });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0 });
  const server = await gw.listen(); after(()=>server.close());
  await postJson(server.address().port, '/v1/messages', { messages: [
    { role:'user', content:[{ type:'tool_result', text:'decoy', content:[{ type:'text', text:'hidden sk-ant-AAAAAAAAAAAAAAAAAAAAAA' }] }] },
  ]});
  assert.ok(!received.includes('sk-ant-AAAAAAAAAAAAAAAAAAAAAA'), '.content secret leaked when .text present');
});

test('writes a detection log line with source ds-gateway and no raw values', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsg-'));
  const prevLogDir = process.env.AI_SAFE_LOG_DIR;
  process.env.AI_SAFE_LOG_DIR = tmp;
  after(() => {
    if (prevLogDir === undefined) delete process.env.AI_SAFE_LOG_DIR;
    else process.env.AI_SAFE_LOG_DIR = prevLogDir;
  });
  const up = await startUpstream((req,res)=>{ req.resume(); res.writeHead(200); res.end('{}'); });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0 });
  const server = await gw.listen(); after(()=>server.close());

  await postJson(server.address().port, '/v1/messages?token=sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX',
    { messages:[{role:'user',content:'sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX'}] });
  await new Promise(r=>setTimeout(r,30));

  const logFile = path.join(tmp, 'secret-scan-events.jsonl');
  assert.ok(fs.existsSync(logFile));
  const line = fs.readFileSync(logFile, 'utf8').trim().split('\n').pop();
  const ev = JSON.parse(line);
  assert.strictEqual(ev.source, 'ds-gateway');
  // F-2: body の key に加え URL クエリの key もマスクされるため検出は 2 件。
  assert.strictEqual(ev.counts.openai, 2);
  assert.ok(!line.includes('sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX'), 'must not log raw value');
  assert.ok(!ev.path.includes('?'), 'query string must be stripped from logged path');
});

test('reversible PII becomes a token in the forwarded body; hard secret stays masked', async () => {
  let received = null;
  const up = await startUpstream((req,res)=>{ let b=''; req.on('data',c=>b+=c); req.on('end',()=>{received=b; res.writeHead(200,{'content-type':'application/json'}); res.end('{}');}); });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0 });
  const server = await gw.listen(); after(()=>server.close());
  await postJson(server.address().port, '/v1/messages', { messages:[
    { role:'user', content:'連絡先 user@example.com と key sk-ant-ABCDEFGHIJKLMNOPQRSTUVWX' },
  ]});
  assert.ok(!received.includes('user@example.com'), 'email not sent raw');
  assert.match(received, /〔R\d+〕/, 'email replaced by reversible token');
  assert.ok(received.includes('[MASKED:anthropic]'), 'hard secret irreversible');
});

test('restores reversible token in SSE response, even split across chunks', async () => {
  const up = await startUpstream((req,res)=>{
    let b=''; req.on('data',c=>b+=c); req.on('end',()=>{
      const sent = JSON.parse(b);
      const token = (JSON.stringify(sent).match(/〔R\d+〕/) || [])[0] || '〔R1〕';
      res.writeHead(200, {'content-type':'text/event-stream'});
      const mid = Math.ceil(token.length/2);
      res.write('data: {"delta":{"text":"連絡先は ' + token.slice(0, mid));
      setTimeout(()=>{ res.write(token.slice(mid) + ' です"}}\n\n'); res.end(); }, 10);
    });
  });
  after(()=>up.close());
  const tm = createTokenMap();
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, tokenMap: tm, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());

  const chunks = [];
  await new Promise((resolve,reject)=>{
    const data = Buffer.from(JSON.stringify({ messages:[{role:'user',content:'連絡先 user@example.com'}], stream:true }));
    const r = http.request({host:'127.0.0.1',port:server.address().port,path:'/v1/messages',method:'POST',headers:{'content-type':'application/json','content-length':data.length}},
      (res)=>{ res.on('data',c=>chunks.push(c.toString())); res.on('end',resolve); });
    r.on('error',reject); r.end(data);
  });
  const all = chunks.join('');
  assert.ok(all.includes('user@example.com'), 'token restored to original even across chunk split');
  assert.ok(!/〔R\d+〕/.test(all), 'no residual token');
});

test('JSON-escapes restored value with special chars', async () => {
  const tm = createTokenMap();
  const up = await startUpstream((req,res)=>{
    let b=''; req.on('data',c=>b+=c); req.on('end',()=>{
      const token = (b.match(/〔R\d+〕/) || ['〔R1〕'])[0];
      res.writeHead(200,{'content-type':'text/event-stream'});
      res.end('data: {"t":"' + token + '"}\n\n');
    });
  });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, tokenMap: tm, denylistTerms: ['a"b'] });
  const server = await gw.listen(); after(()=>server.close());
  let body='';
  await new Promise((resolve,reject)=>{
    const data = Buffer.from(JSON.stringify({ messages:[{role:'user',content:'値は a"b です'}] }));
    const r = http.request({host:'127.0.0.1',port:server.address().port,path:'/v1/messages',method:'POST',headers:{'content-type':'application/json','content-length':data.length}},
      (res)=>{ res.on('data',c=>body+=c); res.on('end',resolve); });
    r.on('error',reject); r.end(data);
  });
  const jsonPart = body.split('data: ')[1].trim();
  assert.doesNotThrow(()=>JSON.parse(jsonPart));
  assert.strictEqual(JSON.parse(jsonPart).t, 'a"b');
});

test('does not restore tokens not allocated in the current request (RED-A)', async () => {
  const tm = createTokenMap();
  const victimToken = tm.alloc('victim@secret.example.com', 'email'); // 別リクエスト相当でプロセス共有 map に残存
  const up = await startUpstream((req,res)=>{
    let b=''; req.on('data',c=>b+=c); req.on('end',()=>{
      const fwdTokens = (b.match(/〔R\d+〕/g) || []);
      res.writeHead(200,{'content-type':'text/event-stream'});
      res.end('data: {"text":"' + fwdTokens.join(' ') + '"}\n\n');
    });
  });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, tokenMap: tm, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  let body='';
  await new Promise((resolve,reject)=>{
    // このリクエストは自分の PII(新規 email)＋他リクエストの目印を含む
    const data = Buffer.from(JSON.stringify({ messages:[{role:'user',content:'私のメール me@here.com と ' + victimToken}] }));
    const r = http.request({host:'127.0.0.1',port:server.address().port,path:'/v1/messages',method:'POST',headers:{'content-type':'application/json','content-length':data.length}},
      (res)=>{ res.on('data',c=>body+=c); res.on('end',resolve); });
    r.on('error',reject); r.end(data);
  });
  assert.ok(body.includes('me@here.com'), 'own request PII is restored');
  assert.ok(!body.includes('victim@secret.example.com'), 'must NOT restore another request PII');
  assert.ok(body.includes(victimToken), 'foreign token stays literal');
});

test('restores tokens in non-streaming JSON response without breaking framing (RED-B)', async () => {
  const tm = createTokenMap();
  const up = await startUpstream((req,res)=>{
    let b=''; req.on('data',c=>b+=c); req.on('end',()=>{
      const token = (b.match(/〔R\d+〕/) || ['〔R1〕'])[0];
      const payload = JSON.stringify({ content:[{ type:'text', text:'連絡先は ' + token + ' です' }] });
      res.writeHead(200, { 'content-type':'application/json', 'content-length': Buffer.byteLength(payload) });
      res.end(payload);
    });
  });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, tokenMap: tm, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  const res = await postJson(server.address().port, '/v1/messages', { messages:[{role:'user',content:'連絡先 user@example.com'}] });
  assert.strictEqual(res.status, 200);
  assert.doesNotThrow(()=>JSON.parse(res.body), 'response body must remain valid JSON (no content-length mismatch)');
  assert.ok(res.body.includes('user@example.com'), 'token restored');
  assert.ok(!/〔R\d+〕/.test(res.body), 'no residual token');
});

test('rejects oversized request body fail-closed (413, not forwarded) (M2)', async () => {
  let forwarded = false;
  const up = await startUpstream((req,res)=>{ forwarded = true; req.resume(); res.writeHead(200); res.end('{}'); });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, maxBody: 1024 });
  const server = await gw.listen(); after(()=>server.close());
  const data = Buffer.from(JSON.stringify({ messages:[{ role:'user', content:'x'.repeat(5000) }] }));
  const res = await new Promise((resolve,reject)=>{
    const r = http.request({host:'127.0.0.1',port:server.address().port,path:'/v1/messages',method:'POST',headers:{'content-type':'application/json','content-length':data.length}},
      (rs)=>{ let b=''; rs.on('data',c=>b+=c); rs.on('end',()=>resolve({status:rs.statusCode})); });
    r.on('error',reject); r.end(data);
  });
  assert.strictEqual(res.status, 413);
  assert.strictEqual(forwarded, false);
});

// ── F-1: 検査範囲を body 全体へ（messages/system 以外のフィールドも漏らさない）──
test('F-1: masks secrets in arbitrary top-level / metadata / tools fields before forwarding', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  await postJson(server.address().port, '/v1/messages', {
    model: 'deepseek-v4-pro',
    metadata: { owner: 'leak-owner@example.com', key: 'sk-ant-AAAAAAAAAAAAAAAAAAAAAA' },
    tools: [{ name: 't', description: 'contact tool-desc@example.com', input_schema: { note: 'sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX' } }],
    extraField: 'top-level sk-proj-ZZZZZZZZZZZZZZZZZZZZZ here',
    messages: [{ role:'user', content:'hi' }],
  });
  assert.ok(!cap.body.includes('sk-ant-AAAAAAAAAAAAAAAAAAAAAA'), 'metadata API key leaked');
  assert.ok(!cap.body.includes('sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX'), 'tools input_schema key leaked');
  assert.ok(!cap.body.includes('sk-proj-ZZZZZZZZZZZZZZZZZZZZZ'), 'top-level field key leaked');
  assert.ok(!cap.body.includes('leak-owner@example.com'), 'metadata email leaked raw');
  assert.ok(!cap.body.includes('tool-desc@example.com'), 'tools description email leaked raw');
  // API は壊さない: model 名は無傷、構造は保持
  const fwd = JSON.parse(cap.body);
  assert.strictEqual(fwd.model, 'deepseek-v4-pro');
  assert.strictEqual(fwd.tools[0].name, 't');
});

test('F-1: masks secrets even when body has no messages/system field at all', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  await postJson(server.address().port, '/v1/models', { foo: 'sk-proj-SHOULDBEMASKEDXXXXXXXX' });
  assert.ok(!cap.body.includes('sk-proj-SHOULDBEMASKEDXXXXXXXX'), 'secret in non-messages body leaked');
  assert.ok(cap.body.includes('foo'), 'key preserved');
});

// ── F-2: 全メソッド・URL クエリ・非配列 messages ──
test('F-2: masks PUT JSON body before forwarding', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  const res = await request(server.address().port, { path:'/v1/resource', method:'PUT',
    headers:{'content-type':'application/json'}, body:{ note:'sk-ant-AAAAAAAAAAAAAAAAAAAAAA', mail:'put-leak@example.com' } });
  assert.strictEqual(res.status, 200);
  assert.ok(!cap.body.includes('sk-ant-AAAAAAAAAAAAAAAAAAAAAA'), 'PUT body API key leaked');
  assert.ok(!cap.body.includes('put-leak@example.com'), 'PUT body email leaked raw');
});

test('F-2: non-JSON PUT body is fail-closed (415, not forwarded)', async () => {
  let forwarded = false;
  const up = await startUpstream((req,res)=>{ forwarded = true; req.resume(); res.writeHead(200); res.end(); });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0 });
  const server = await gw.listen(); after(()=>server.close());
  const res = await request(server.address().port, { path:'/v1/resource', method:'PUT',
    headers:{'content-type':'text/plain'}, body:'plain sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX' });
  assert.strictEqual(res.status, 415);
  assert.strictEqual(forwarded, false, 'non-JSON PUT must not be forwarded');
});

test('F-2: masks URL query values for GET before forwarding', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  const res = await request(server.address().port, {
    path:'/v1/messages?email=' + encodeURIComponent('query-leak@example.com') + '&key=sk-ant-AAAAAAAAAAAAAAAAAAAAAA&model=deepseek-v4',
    method:'GET' });
  assert.strictEqual(res.status, 200);
  assert.ok(!cap.path.includes('query-leak@example.com'), 'query email reached upstream raw');
  assert.ok(!cap.path.includes('sk-ant-AAAAAAAAAAAAAAAAAAAAAA'), 'query API key reached upstream raw');
  assert.ok(cap.path.includes('model=deepseek-v4'), 'benign query value preserved');
});

test('F-2: masks non-array string messages field (deep-walk)', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  await postJson(server.address().port, '/v1/messages', { messages: 'plain string with sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX' });
  assert.ok(!cap.body.includes('sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX'), 'non-array messages string leaked secret');
});

// ── F-3: header 値のマスク（標準 header は保全）──
test('F-3: masks PII/secret in custom headers but preserves standard headers', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  const res = await request(server.address().port, { path:'/v1/messages', method:'POST',
    headers:{
      'content-type':'application/json',
      'authorization':`Bearer ${TEST_TOKEN}`,
      'anthropic-version':'2023-06-01',
      'x-user-note':'contact header-leak@example.com and sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX',
    },
    body:{ messages:[{ role:'user', content:'hi' }] } });
  assert.strictEqual(res.status, 200);
  assert.ok(!cap.headers['x-user-note'].includes('header-leak@example.com'), 'custom header email leaked raw');
  assert.ok(!cap.headers['x-user-note'].includes('sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX'), 'custom header API key leaked raw');
  // 標準 header は素通り（マスクすると API 呼び出しが壊れる）
  assert.strictEqual(cap.headers['anthropic-version'], '2023-06-01', 'anthropic-version must not be masked');
  assert.strictEqual(cap.headers['content-type'], 'application/json', 'content-type must not be masked');
  // upstream キー未設定でも呼び出し元の合言葉は転送しない（M-7）。
  assert.strictEqual(cap.headers['authorization'], undefined, 'caller token must not be forwarded upstream');
});

// ── F-4: denylist 読込失敗を fail-closed 化 ──
test('F-4: denylist configured-but-unreadable does not leak the denied term (fail-closed)', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  // denylist が「設定されている」(DENYLIST_PATH 指定あり) のに読めない → fail-closed sentinel が返り、
  // gateway は全リクエストを転送拒否する。
  const sentinel = loadDenylistResult('/no/such/denylist-configured.txt', { configured: true });
  assert.ok(sentinel && sentinel.failClosed === true, 'configured-but-unreadable must yield a fail-closed sentinel');
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: sentinel });
  const server = await gw.listen(); after(()=>server.close());
  const res = await postJson(server.address().port, '/v1/messages', { messages:[{ role:'user', content:'秘密語 田中商事 を含む' }] });
  assert.notStrictEqual(res.status, 200, 'configured-but-unreadable denylist must not forward (fail-closed)');
  assert.strictEqual(cap.body, null, 'denied term reached upstream despite unreadable denylist (fail-open)');
});

test('F-4: denylist unset (no path configured, default missing) loads as [] (normal)', () => {
  const prev = process.env.DENYLIST_PATH;
  delete process.env.DENYLIST_PATH;
  const prevLog = process.env.AI_SAFE_LOG_DIR;
  // 未設定かつデフォルトパスのファイルも存在しない環境 → [] であるべき（fail-open ではなく「設定なし」）。
  process.env.AI_SAFE_LOG_DIR = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'dl-unset-')), 'logs');
  after(() => {
    if (prev === undefined) delete process.env.DENYLIST_PATH; else process.env.DENYLIST_PATH = prev;
    if (prevLog === undefined) delete process.env.AI_SAFE_LOG_DIR; else process.env.AI_SAFE_LOG_DIR = prevLog;
  });
  const r = loadDenylistResult();
  assert.deepStrictEqual(r, [], 'unset denylist must be [] (normal), not a fail-closed sentinel');
});

// ── D: base64 画像 content block は DeepSeek 経路でテキストプレースホルダに差し替える ──
// （旧 F-7: 画像を「バイト不変で保全」する挙動は、DeepSeek は画像を見られない＝毎ターン純浪費
//   になるため D で「差し替え」に変更。document(PDF) は従来どおり保全する。）
test('D: base64 image block is replaced by a JP placeholder text block (not forwarded to DeepSeek)', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  const imageData = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk' +
    'AIza' + 'B'.repeat(600 - 64 - 4) + 'AAAA';
  await postJson(server.address().port, '/v1/messages', {
    messages: [{
      role: 'user',
      content: [{
        type: 'image',
        source: { type: 'base64', media_type: 'image/png', data: imageData },
      }],
    }],
  });
  const fwd = JSON.parse(cap.body);
  const block = fwd.messages[0].content[0];
  assert.strictEqual(block.type, 'text', 'image block must become a text block');
  assert.ok(!('source' in block), 'no source/data must be forwarded');
  assert.ok(block.text.includes('画像データは送信していません'), 'JP placeholder text present');
  assert.ok(block.text.includes('describe_image'), 'placeholder points to describe_image');
  assert.ok(block.text.includes('image/png'), 'sanitized media_type surfaced in placeholder');
  assert.ok(!cap.body.includes(imageData), 'raw base64 image data must NOT reach upstream (token waste avoided)');
  assert.ok(!cap.body.includes('[MASKED:google]'), 'image stripped whole, not scanned/masked as a secret');
});

test('F-7: base64 document source.data is also preserved', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  // 純粋 base64 charset のみ（>512 chars）で PDF ヘッダに偶然 AIza が入っているケースを模擬。
  const docData = 'JVBERi0xLjQKJeLjz9MKNSAwIG9iagowCmVuZG9iagp4cmVm' +
    'AIza' + 'B'.repeat(600 - 52 - 4) + 'AAAA';
  await postJson(server.address().port, '/v1/messages', {
    messages: [{
      role: 'user',
      content: [{
        type: 'document',
        source: { type: 'base64', media_type: 'application/pdf', data: docData },
      }],
    }],
  });
  const fwd = JSON.parse(cap.body);
  const fwdData = fwd.messages[0].content[0].source.data;
  assert.strictEqual(fwdData, docData, 'document source.data must be byte-for-byte identical');
});

test('D: text content secrets are still masked even when base64 image blocks exist', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  const imageData = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA';
  await postJson(server.address().port, '/v1/messages', {
    messages: [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: imageData } },
        { type: 'text', text: 'My key is sk-ant-AAAAAAAAAAAAAAAAAAAAAA and I need help.' },
      ],
    }],
  });
  const fwd = JSON.parse(cap.body);
  assert.strictEqual(fwd.messages[0].content[0].type, 'text', 'image stripped to text placeholder');
  assert.ok(fwd.messages[0].content[0].text.includes('画像データは送信していません'), 'placeholder present');
  assert.ok(!cap.body.includes(imageData), 'image base64 not forwarded');
  assert.ok(!cap.body.includes('sk-ant-AAAAAAAAAAAAAAAAAAAAAA'), 'text content secret still masked');
});

// ── F-8: 不正 percent-encoding のクエリは fail-closed（silently rewrite 禁止）──
test('F-8: malformed percent-encoded query is rejected fail-closed (400, not forwarded)', async () => {
  let forwarded = false;
  const up = await startUpstream((req,res)=>{ forwarded = true; req.resume(); res.writeHead(200); res.end('{}'); });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  // %E0%A4%A is an incomplete/invalid percent sequence (Codex-reported case).
  const res = await request(server.address().port, { path:'/v1/messages?q=%E0%A4%A&ok=1', method:'GET' });
  assert.strictEqual(res.status, 400, 'invalid percent-encoding must be rejected 400 fail-closed');
  assert.strictEqual(forwarded, false, 'must not forward with malformed query');
});

test('F-8: valid percent-encoded query passes through without corruption', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  // Benign percent-encoded cursor and page params (base64url / standard encoding).
  const res = await request(server.address().port, { path:'/v1/messages?cursor=abc%2Fdef%2B123%3D%3D&page=2&flag', method:'GET' });
  assert.strictEqual(res.status, 200, 'valid percent-encoded query must pass through');
  assert.ok(cap.path.includes('cursor='), 'cursor param preserved in upstream path');
  assert.ok(cap.path.includes('page=2'), 'page param preserved');
});

// ── F-9: base64 除外条件の厳格化（偽装漏洩穴を塞ぐ）──
test('F-9: forged {type:"base64"} WITHOUT media_type is still masked (metadata location)', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  // media_type が無い {type:"base64"} は本物の Anthropic media source ではなく偽装とみなしマスクする。
  await postJson(server.address().port, '/v1/messages', {
    metadata: { source: { type: 'base64', data: 'sk-ant-AAAAAAAAAAAAAAAAAAAAAA' } },
    messages: [{ role: 'user', content: 'hi' }],
  });
  assert.ok(!cap.body.includes('sk-ant-AAAAAAAAAAAAAAAAAAAAAA'), 'forged base64 without media_type: secret must be masked');
  assert.ok(cap.body.includes('[MASKED:anthropic]'), 'must be replaced with [MASKED:anthropic]');
});

test('D: image block with a forged secret-as-data is stripped whole (secret never reaches upstream)', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  // 画像 content block は data の中身に関わらず丸ごと差し替えるので、data に仕込んだ秘密も上流に届かない。
  await postJson(server.address().port, '/v1/messages', {
    messages: [{
      role: 'user',
      content: [{
        type: 'image',
        source: { type: 'base64', media_type: 'image/png', data: 'sk-ant-AAAAAAAAAAAAAAAAAAAAAA' },
      }],
    }],
  });
  assert.ok(!cap.body.includes('sk-ant-AAAAAAAAAAAAAAAAAAAAAA'), 'forged data dropped together with the image block');
  const fwd = JSON.parse(cap.body);
  assert.strictEqual(fwd.messages[0].content[0].type, 'text', 'replaced by placeholder text block');
});

test('D: even a legitimate base64 image (strict charset) is stripped to a placeholder (DeepSeek is blind to it)', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  const legitimateBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk' +
    'AIza' + 'B'.repeat(600 - 64 - 4) + 'AAAA';
  await postJson(server.address().port, '/v1/messages', {
    messages: [{
      role: 'user',
      content: [{
        type: 'image',
        source: { type: 'base64', media_type: 'image/png', data: legitimateBase64 },
      }],
    }],
  });
  const fwd = JSON.parse(cap.body);
  assert.strictEqual(fwd.messages[0].content[0].type, 'text', 'legitimate image is still replaced by a text placeholder');
  assert.ok(!cap.body.includes(legitimateBase64), 'large base64 image data must not be forwarded to DeepSeek');
});

// ── F-9 仕上げ: BINARY_MIME ホワイトリスト + length > 512 ──
test('F-9 (fin): short AKIA-style base64-charset secret (<=512 chars) is masked despite valid media_type', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  // AKIA + 16大文字 = 20字・[A-Z0-9] のみで base64 charset に収まるが length <= 512 → 除外されずマスク。
  const fakeBase64 = 'AKIAIOSFODNN7EXAMPLE';
  assert.ok(fakeBase64.length <= 512);
  await postJson(server.address().port, '/v1/messages', {
    messages: [{
      role: 'user',
      content: [{
        type: 'image',
        source: { type: 'base64', media_type: 'image/png', data: fakeBase64 },
      }],
    }],
  });
  assert.ok(!cap.body.includes('AKIAIOSFODNN7EXAMPLE'), 'short AKIA-style forged base64 must not pass through raw');
});

test('D: image block is stripped regardless of media_type (forged text/plain image too)', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  // type:'image' なら media_type に関わらず丸ごと差し替えるので、data に仕込んだ google キー模擬も上流に届かない。
  const bigNonBinaryBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk' +
    'AIza' + 'B'.repeat(600 - 64 - 4) + 'AAAA';
  assert.ok(bigNonBinaryBase64.length > 512);
  await postJson(server.address().port, '/v1/messages', {
    messages: [{
      role: 'user',
      content: [{
        type: 'image',
        source: { type: 'base64', media_type: 'text/plain', data: bigNonBinaryBase64 },
      }],
    }],
  });
  assert.ok(!cap.body.includes('AIzaBBBB'), 'forged google key pattern must not reach upstream raw');
  assert.ok(!cap.body.includes(bigNonBinaryBase64), 'image data dropped');
  const fwd = JSON.parse(cap.body);
  assert.strictEqual(fwd.messages[0].content[0].type, 'text', 'replaced by placeholder');
});

test('D: large legitimate base64 image (>512, binary MIME) is stripped and shrinks the forwarded body', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  const largeImageData = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk' +
    'AIza' + 'B'.repeat(600 - 64 - 4) + 'AAAA';
  assert.ok(largeImageData.length > 512);
  assert.ok(/^[A-Za-z0-9+/=]+$/.test(largeImageData));
  await postJson(server.address().port, '/v1/messages', {
    messages: [{
      role: 'user',
      content: [{
        type: 'image',
        source: { type: 'base64', media_type: 'image/png', data: largeImageData },
      }],
    }],
  });
  const fwd = JSON.parse(cap.body);
  assert.strictEqual(fwd.messages[0].content[0].type, 'text', 'large image replaced by placeholder');
  assert.ok(!cap.body.includes(largeImageData), 'large base64 not forwarded');
  assert.ok(cap.body.length < largeImageData.length, 'forwarded body is smaller than the stripped image (token savings)');
});

test('D: a secret hidden in media_type is NOT echoed into the placeholder', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  await postJson(server.address().port, '/v1/messages', {
    messages: [{
      role: 'user',
      content: [{
        type: 'image',
        source: { type: 'base64', media_type: 'sk-ant-AAAAAAAAAAAAAAAAAAAAAA', data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA' },
      }],
    }],
  });
  assert.ok(!cap.body.includes('sk-ant-AAAAAAAAAAAAAAAAAAAAAA'), 'forged media_type secret must not be echoed by the placeholder');
  const fwd = JSON.parse(cap.body);
  const block = fwd.messages[0].content[0];
  assert.strictEqual(block.type, 'text');
  assert.ok(block.text.includes('不明'), 'invalid media_type falls back to 不明');
});

test('D: a MIME-shaped secret in media_type (sk-ant-.../png) is NOT echoed (RED-1 regression)', async () => {
  // RED-1: 旧実装は MIME 形状 regex `^[\w.+-]{1,40}/[\w.+-]{1,40}$` を使い、"sk-ant-…/png" のような
  // ハイフン込み 40 字以下の秘密を「正しい MIME」と誤認して placeholder に生 echo し、upstream に
  // 秘密が到達していた（HEAD の maskText 経路の回帰）。BINARY_MIME ホワイトリスト照合で塞ぐ。
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  await postJson(server.address().port, '/v1/messages', {
    messages: [{
      role: 'user',
      content: [{
        type: 'image',
        source: { type: 'base64', media_type: 'sk-ant-AAAAAAAAAAAAAAAAAAAAAA/png', data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA' },
      }],
    }],
  });
  assert.ok(!cap.body.includes('sk-ant-AAAAAAAAAAAAAAAAAAAAAA'), 'MIME-shaped secret in media_type must NOT reach upstream');
  const fwd = JSON.parse(cap.body);
  const block = fwd.messages[0].content[0];
  assert.strictEqual(block.type, 'text', 'image replaced by placeholder');
  assert.ok(block.text.includes('不明'), 'non-whitelisted media_type falls back to 不明 (not echoed)');
});

test('D: a base64 image nested inside tool_result content is also stripped (deep-walk)', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  const imageData = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA' + 'C'.repeat(600);
  await postJson(server.address().port, '/v1/messages', { messages: [
    { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'x', content: [
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: imageData } },
    ] }] },
  ]});
  assert.ok(!cap.body.includes(imageData), 'nested tool_result image data must not be forwarded');
  const fwd = JSON.parse(cap.body);
  assert.strictEqual(fwd.messages[0].content[0].type, 'tool_result', 'outer structure preserved');
  assert.strictEqual(fwd.messages[0].content[0].content[0].type, 'text', 'nested image replaced by placeholder');
});

test('D: a URL image (source.type=url) is left untouched (only base64 is stripped)', async () => {
  const { server: up, cap } = await startCaptureUpstream();
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  await postJson(server.address().port, '/v1/messages', { messages: [
    { role: 'user', content: [{ type: 'image', source: { type: 'url', url: 'https://example.com/cat.png' } }] },
  ]});
  const fwd = JSON.parse(cap.body);
  const block = fwd.messages[0].content[0];
  assert.strictEqual(block.type, 'image', 'URL image block kept as image');
  assert.strictEqual(block.source.type, 'url');
  assert.strictEqual(block.source.url, 'https://example.com/cat.png', 'URL preserved');
});

test('audit log includes new PII category counts without raw values (§8)', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsg-pii-'));
  const prevLogDir = process.env.AI_SAFE_LOG_DIR;
  process.env.AI_SAFE_LOG_DIR = tmp;
  after(() => { if (prevLogDir === undefined) delete process.env.AI_SAFE_LOG_DIR; else process.env.AI_SAFE_LOG_DIR = prevLogDir; });
  const up = await startUpstream((req,res)=>{ req.resume(); res.writeHead(200,{'content-type':'application/json'}); res.end('{}'); });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  await postJson(server.address().port, '/v1/messages', { messages:[{ role:'user', content:'連絡先 user@example.com' }] });
  await new Promise(r=>setTimeout(r,30));
  const logFile = path.join(tmp, 'secret-scan-events.jsonl');
  const line = fs.readFileSync(logFile, 'utf8').trim().split('\n').pop();
  const ev = JSON.parse(line);
  assert.strictEqual(ev.counts.email, 1, 'email count logged');
  assert.ok(!line.includes('user@example.com'), 'raw PII value must not be logged');
});
