const { test, after } = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { createGateway } = require('../ds-gateway.js');
const { createTokenMap } = require('../token-map.js');

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
  assert.strictEqual(ev.counts.openai, 1);
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
  const token = tm.alloc('a"b\nc', 'denylist');
  const up = await startUpstream((req,res)=>{ req.resume(); res.writeHead(200,{'content-type':'text/event-stream'}); res.end('data: {"t":"' + token + '"}\n\n'); });
  after(()=>up.close());
  const gw = createGateway({ upstream:`http://127.0.0.1:${up.address().port}`, port:0, tokenMap: tm, denylistTerms: [] });
  const server = await gw.listen(); after(()=>server.close());
  let body='';
  await new Promise((resolve,reject)=>{
    const data = Buffer.from(JSON.stringify({ messages:[{role:'user',content:'hi'}] }));
    const r = http.request({host:'127.0.0.1',port:server.address().port,path:'/v1/messages',method:'POST',headers:{'content-type':'application/json','content-length':data.length}},
      (res)=>{ res.on('data',c=>body+=c); res.on('end',resolve); });
    r.on('error',reject); r.end(data);
  });
  const jsonPart = body.split('data: ')[1].trim();
  assert.doesNotThrow(()=>JSON.parse(jsonPart));
  assert.strictEqual(JSON.parse(jsonPart).t, 'a"b\nc');
});
