'use strict';
// v1.19.4（2026-10）: Gemini の混雑対策・画像生成の参考画像・DeepSeek への画像の受け渡しの回帰テスト。
//
// 守りたいこと:
//   1. Gemini（コーチ/判定・画像読取・検索）は混雑(5xx)・時間切れ・権限(403)・上限(429)で予備モデルを試す。
//      キー未登録では試さない。全部だめなときの文言は実際の原因を優先する（403 だけ「キー無効」）。
//   2. 既定モデルは 2026-10-02 の実測で選んだもの（3.5-flash-lite / 検索は 2.5-flash-lite）。
//   3. 参考画像は作業フォルダ内の本物の画像だけ（外・リンク・偽物・枚数超過は理由つきで拒否）。
//   4. codex / agy は参考画像を渡せる。時間切れと未ログインを取り違えない。agy は会話ID のフォルダから拾う。
//   5. Gateway は deepseek-flash 宛てだけ画像を通し、v4-pro・大きすぎる画像・無効化時は従来の差し替え。
const { test, after } = require('node:test');
const assert = require('node:assert');
const nodeHttp = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const TEST_TOKEN = 'test-gateway-token-0123456789abcdef';
process.env.DS_GATEWAY_TOKEN = TEST_TOKEN;
const VISION_CACHE = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-vision-cache-'));
process.env.AI_SAFE_VISION_CACHE_DIR = VISION_CACHE;

const common = path.join(__dirname, '..');
const gemini = require(path.join(common, 'gemini-client.js'));
const vision = require(path.join(common, 'gemini-vision-mcp.js'));
const search = require(path.join(common, 'gemini-search-mcp.js'));
const refs = require(path.join(common, 'image-refs.js'));
const codex = require(path.join(common, 'codex-image-mcp.js'));
const agy = require(path.join(common, 'agy-image-mcp.js'));
const judge = require(path.join(common, 'command-judge.js'));
const { createGateway, visionCapableModel } = require(path.join(common, 'ds-gateway.js'));

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'img-tools-'));
after(() => {
  for (const d of [tmp, VISION_CACHE]) { try { fs.rmSync(d, { recursive: true, force: true }); } catch { /* */ } }
});

// 1x1 の本物の PNG（先頭バイトで画像と判定される）
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');

// ---------------------------------------------------------------------------
// 1-2. Gemini の予備モデルと既定モデル
// ---------------------------------------------------------------------------
test('既定モデル: コーチ/判定/画像読取は 3.5-flash-lite、検索は 2.5-flash-lite（予備 2.5-flash）', () => {
  if (!process.env.AI_SAFE_COACH_MODEL) assert.strictEqual(gemini.COACH_MODEL, 'gemini-3.5-flash-lite');
  if (!process.env.AI_SAFE_COACH_MODEL_FALLBACK) assert.deepStrictEqual(gemini.FALLBACK_MODELS, ['gemini-3.1-flash-lite', 'gemini-2.5-flash-lite']);
  if (!process.env.AI_SAFE_JUDGE_MODEL) assert.strictEqual(judge.JUDGE_MODEL, 'gemini-3.5-flash-lite');
  if (!process.env.AI_SAFE_SEARCH_MODEL) assert.strictEqual(search.SEARCH_MODEL, 'gemini-2.5-flash-lite');
  if (!process.env.AI_SAFE_SEARCH_FALLBACK) assert.deepStrictEqual(search.SEARCH_FALLBACKS, ['gemini-2.5-flash']);
});

function fakeOnce(script) {
  const calls = [];
  const fn = async (prompt, model) => {
    calls.push(model);
    const r = script[calls.length - 1] || script[script.length - 1];
    return typeof r === 'function' ? r(model) : r;
  };
  return { fn, calls };
}
const BUSY = { ok: false, text: gemini.AI_UNAVAILABLE, retryable: true };
const TIMEOUT = { ok: false, text: gemini.AI_UNAVAILABLE, retryable: true, timedOut: true };
const QUOTA = { ok: false, text: gemini.RATE_MSG, retryable: true };
const DENIED = { ok: false, text: gemini.BAD_KEY_MSG, retryable: true };
const OK = { ok: true, text: 'はい' };

test('コーチ: 混雑なら予備モデルへ切り替えて答えを返す', async () => {
  const f = fakeOnce([BUSY, OK]);
  const r = await gemini.runAI('p', { _runOnce: f.fn });
  assert.deepStrictEqual(r, OK);
  assert.deepStrictEqual(f.calls, [gemini.COACH_MODEL, gemini.FALLBACK_MODELS[0]]);
});

test('コーチ: キー未登録では予備を試さない', async () => {
  const f = fakeOnce([{ ok: false, text: gemini.NO_KEY_MSG }]);
  const r = await gemini.runAI('p', { _runOnce: f.fn });
  assert.strictEqual(r.text, gemini.NO_KEY_MSG);
  assert.strictEqual(f.calls.length, 1);
});

test('コーチ: 上限→権限(2.5 系の利用制限)で全滅なら「キー無効」ではなく「上限」と伝える', async () => {
  const f = fakeOnce([QUOTA, DENIED, DENIED]);
  const r = await gemini.runAI('p', { _runOnce: f.fn });
  assert.strictEqual(r.ok, false);
  assert.strictEqual(r.text, gemini.RATE_MSG);
});

test('コーチ: 全部 403 のときだけ「キー無効」', async () => {
  const f = fakeOnce([DENIED]);
  const r = await gemini.runAI('p', { _runOnce: f.fn });
  assert.strictEqual(r.text, gemini.BAD_KEY_MSG);
  assert.strictEqual(f.calls.length, 1 + gemini.FALLBACK_MODELS.length);
});

test('判定: 時間切れでは予備を試さない（fallbackOnTimeout:false）が、すぐ返る失敗では試す', async () => {
  const a = fakeOnce([TIMEOUT, OK]);
  const r1 = await gemini.runAI('p', { _runOnce: a.fn, fallbackOnTimeout: false });
  assert.strictEqual(r1.ok, false);
  assert.strictEqual(a.calls.length, 1);
  const b = fakeOnce([QUOTA, OK]);
  const r2 = await gemini.runAI('p', { _runOnce: b.fn, fallbackOnTimeout: false });
  assert.strictEqual(r2.ok, true);
});

test('画像読取: UNAVAILABLE・時間切れでも予備へ。キー未登録・画像の問題では切り替えない', async () => {
  assert.strictEqual(vision.shouldFallback({ ok: false, status: 503, gstatus: 'UNAVAILABLE' }), true);
  assert.strictEqual(vision.shouldFallback({ ok: false, status: 0, network: true }), true);
  assert.strictEqual(vision.shouldFallback({ ok: false, status: 403, gstatus: 'PERMISSION_DENIED' }), true);
  assert.strictEqual(vision.shouldFallback({ ok: false, status: 0, noKey: true }), false);
  assert.strictEqual(vision.shouldFallback({ ok: false, status: 400, gstatus: 'INVALID_ARGUMENT' }), false);

  const img = path.join(tmp, 'v.png');
  fs.writeFileSync(img, PNG);
  const seen = [];
  const call = async (model) => {
    seen.push(model);
    return seen.length === 1 ? { ok: false, status: 503, gstatus: 'UNAVAILABLE', message: 'x' } : { ok: true, status: 200, text: 'ロボット' };
  };
  const r = await vision.describeImage(img, 'q', call);
  assert.strictEqual(r.isError, false);
  assert.strictEqual(r.text, 'ロボット');
  assert.strictEqual(seen.length, 2);
});

test('検索: 混雑は同じモデルで 1 回やり直し、上限なら予備へ。全滅の文言は原因を伝える', async () => {
  const seen = [];
  const busyThenOk = async (q, model) => {
    seen.push(model);
    return seen.length === 1 ? { ok: false, kind: 'busy', message: 'UNAVAILABLE' } : { ok: true, text: '晴れ', sources: [] };
  };
  const r1 = await search.groundedSearch('q', { once: busyThenOk, delayMs: 1 });
  assert.strictEqual(r1.ok, true);
  assert.deepStrictEqual(seen, [search.SEARCH_MODEL, search.SEARCH_MODEL], '同じモデルでやり直す');

  const seen2 = [];
  const quotaThenOk = async (q, model) => {
    seen2.push(model);
    return seen2.length === 1 ? { ok: false, kind: 'quota', message: 'quota' } : { ok: true, text: 'ok', sources: [] };
  };
  const r2 = await search.groundedSearch('q', { once: quotaThenOk, delayMs: 1 });
  assert.strictEqual(r2.ok, true);
  assert.deepStrictEqual(seen2, [search.SEARCH_MODEL, search.SEARCH_FALLBACKS[0]]);

  const allBusy = async () => ({ ok: false, kind: 'busy', message: 'Gemini 検索に失敗しました（UNAVAILABLE）。' });
  const r3 = await search.groundedSearch('q', { once: allBusy, delayMs: 1 });
  assert.strictEqual(r3.ok, false);
  assert.match(r3.message, /混雑/);

  const nokey = async () => ({ ok: false, kind: 'nokey', message: 'キー未設定' });
  const r4 = await search.groundedSearch('q', { once: nokey, delayMs: 1 });
  assert.strictEqual(r4.message, 'キー未設定');
});

// ---------------------------------------------------------------------------
// 3. 参考画像の検査
// ---------------------------------------------------------------------------
test('参考画像: 作業フォルダ内の本物の画像だけ通す', () => {
  const ws = fs.mkdtempSync(path.join(tmp, 'ws-'));
  const outside = fs.mkdtempSync(path.join(tmp, 'out-'));
  fs.mkdirSync(path.join(ws, '練習'));
  fs.writeFileSync(path.join(ws, '練習', '1_genzai.png'), PNG);
  fs.writeFileSync(path.join(ws, 'fake.png'), 'API_KEY=sk-not-an-image-1234567890');
  fs.writeFileSync(path.join(ws, 'notes.txt'), 'hello');
  fs.writeFileSync(path.join(outside, 'secret.png'), PNG);
  fs.symlinkSync(path.join(outside, 'secret.png'), path.join(ws, 'link.png'));

  const okR = refs.checkReferenceImages(['練習/1_genzai.png'], ws);
  assert.strictEqual(okR.ok, true);
  assert.strictEqual(okR.paths.length, 1);
  assert.ok(okR.paths[0].endsWith(path.join('練習', '1_genzai.png')));

  const bad = (list, re) => {
    const r = refs.checkReferenceImages(list, ws);
    assert.strictEqual(r.ok, false, JSON.stringify(list));
    assert.match(r.message, re);
  };
  bad(['../' + path.basename(outside) + '/secret.png'], /作業フォルダの中/);
  bad([path.join(outside, 'secret.png')], /作業フォルダの中/);
  bad(['link.png'], /外を指しています/);
  bad(['fake.png'], /画像ではありません/);
  bad(['notes.txt'], /PNG/);
  bad(['nothere.png'], /見つかりません/);
  bad(['練習/1_genzai.png', '練習/1_genzai.png', '練習/1_genzai.png', '練習/1_genzai.png', '練習/1_genzai.png'], /4 枚まで/);
  assert.deepStrictEqual(refs.checkReferenceImages(undefined, ws), { ok: true, paths: [] });
});

// ---------------------------------------------------------------------------
// 4. codex / agy
// ---------------------------------------------------------------------------
test('codex: 参考画像は -i で添付し、プロンプトは -- の後ろ（-i の値と取り違えない）', () => {
  const a = codex.codexArgs('描いて', '/w', ['/w/a.png', '/w/b.png']);
  assert.deepStrictEqual(a.slice(-6), ['-i', '/w/a.png', '-i', '/w/b.png', '--', '描いて']);
  assert.ok(a.includes('read-only'), 'sandbox は read-only のまま');
  assert.deepStrictEqual(codex.codexArgs('x', '/w').slice(-2), ['--', 'x']);
});

test('codex / agy: 時間切れなら「ログインの問題ではない」と伝える', () => {
  assert.match(codex.failureMessage({ timedOut: true, stderr: 'codex がタイムアウトしました' }), /時間切れ/);
  assert.doesNotMatch(codex.failureMessage({ timedOut: true, stderr: '' }), /未ログイン|ログインしてください/);
  assert.match(codex.failureMessage({ stderr: 'You have hit your usage limit' }), /generate_image_agy/);
  assert.match(codex.failureMessage({ stderr: 'Not logged in' }), /ログイン/);
  assert.match(agy.failureMessage({ timedOut: true, stderr: '' }), /時間切れ/);
  assert.doesNotMatch(agy.failureMessage({ timedOut: true, stderr: '' }), /未ログイン/);
});

test('待ち時間: codex / agy とも既定 10 分、OpenCode 側はそれより長い', () => {
  const src = (f) => fs.readFileSync(path.join(common, f), 'utf8');
  if (!process.env.AI_SAFE_CODEX_IMAGE_TIMEOUT) assert.match(src('codex-image-mcp.js'), /AI_SAFE_CODEX_IMAGE_TIMEOUT \|\| 600000/);
  if (!process.env.AI_SAFE_AGY_TIMEOUT) assert.match(src('agy-image-mcp.js'), /AI_SAFE_AGY_TIMEOUT \|\| 600000/);
  const { buildMcpConfig } = require(path.join(common, 'opencode-config.js'));
  const { mcp } = buildMcpConfig({ mcpDir: common, env: {} });
  assert.ok(mcp['agy-image'].timeout > 600000);
  assert.ok(mcp['codex-image'].timeout > 600000);
});

test('agy: JSON 出力で会話ID を受け取り、その会話のフォルダだけから拾う', () => {
  assert.deepStrictEqual(agy.agyArgs('p'), ['-p', 'p', '--output-format', 'json']);
  assert.strictEqual(agy.conversationId('{"conversation_id":"4fabf0fa-0a96-4e1d-bf15-082306aa759e","status":"SUCCESS"}'), '4fabf0fa-0a96-4e1d-bf15-082306aa759e');
  assert.strictEqual(agy.conversationId('log line\n{"conversation_id":"abcdef12-3456"}\n'), 'abcdef12-3456');
  assert.strictEqual(agy.conversationId('{"conversation_id":"../../etc"}'), '', 'パスになる値は使わない');
  assert.strictEqual(agy.conversationId('not json'), '');
});

test('画像生成の説明: agy が標準、GPT は ChatGPT 有料プラン向け、どちらも参考画像を受け取れる', () => {
  assert.match(agy.TOOL.description, /標準/);
  assert.match(codex.TOOL.description, /有料プラン/);
  for (const t of [agy.TOOL, codex.TOOL]) {
    assert.ok(t.inputSchema.properties.reference_images, t.name + ' は reference_images を受け取る');
    assert.doesNotMatch(t.description, /DeepSeek は画像を見られない/);
  }
});

// ---------------------------------------------------------------------------
// 5. Gateway の画像の受け渡し
// ---------------------------------------------------------------------------
function startCapture() {
  const cap = { body: null };
  return new Promise((resolve) => {
    const s = nodeHttp.createServer((req, res) => {
      let b = ''; req.on('data', (c) => (b += c)); req.on('end', () => {
        cap.body = b; res.writeHead(200, { 'content-type': 'application/json' }); res.end('{}');
      });
    });
    s.listen(0, '127.0.0.1', () => resolve({ server: s, cap }));
  });
}
function post(port, obj) {
  return new Promise((resolve, reject) => {
    const data = Buffer.from(JSON.stringify(obj));
    const r = nodeHttp.request({ host: '127.0.0.1', port, path: '/v1/messages', method: 'POST',
      headers: { 'content-type': 'application/json', 'content-length': data.length, authorization: `Bearer ${TEST_TOKEN}` } },
    (res) => { let b = ''; res.on('data', (c) => (b += c)); res.on('end', () => resolve({ status: res.statusCode, body: b })); });
    r.on('error', reject); r.end(data);
  });
}
function imageMessage(model, data) {
  return { model, max_tokens: 10, messages: [{ role: 'user', content: [
    { type: 'image', source: { type: 'base64', media_type: 'image/png', data } },
    { type: 'text', text: 'これは何？' },
  ] }] };
}
// 正しい base64（途中に = を含まない）で 512 文字を超える画像データ。PNG の先頭 + 埋め草、長さは 3 の倍数。
const BIG_B64 = Buffer.concat([PNG, Buffer.alloc(900 - PNG.length, 7)]).toString('base64');

test('Gateway: 画像を通すのは deepseek-flash 系だけ', () => {
  for (const m of ['deepseek-flash', 'deepseek-v4-flash', 'deepseek-v4.1-flash', 'deepseek-v4-flash-vision-exp']) assert.strictEqual(visionCapableModel(m), true, m);
  for (const m of ['deepseek-v4-pro', 'claude-sonnet-4', 'deepseek-flashy', '', undefined]) assert.strictEqual(visionCapableModel(m), false, String(m));
});

test('Gateway: deepseek-flash 宛ての画像はそのまま届き、v4-pro 宛ては従来どおり差し替える', async (t) => {
  const { server: up, cap } = await startCapture();
  t.after(() => up.close());
  const gw = createGateway({ upstream: `http://127.0.0.1:${up.address().port}`, port: 0, denylistTerms: [] });
  const server = await gw.listen();
  t.after(() => server.close());
  const port = server.address().port;

  await post(port, imageMessage('deepseek-flash', BIG_B64));
  let sent = JSON.parse(cap.body);
  assert.strictEqual(sent.messages[0].content[0].type, 'image');
  assert.strictEqual(sent.messages[0].content[0].source.data, BIG_B64);

  await post(port, imageMessage('deepseek-v4-pro', BIG_B64));
  sent = JSON.parse(cap.body);
  assert.strictEqual(sent.messages[0].content[0].type, 'text');
  assert.match(sent.messages[0].content[0].text, /画像データは送信していません/);
});

test('Gateway: 形式が怪しい画像・大きすぎる画像は flash 宛てでも送らない', async (t) => {
  const { server: up, cap } = await startCapture();
  t.after(() => up.close());
  const gw = createGateway({ upstream: `http://127.0.0.1:${up.address().port}`, port: 0, denylistTerms: [] });
  const server = await gw.listen();
  t.after(() => server.close());
  const port = server.address().port;

  const weird = imageMessage('deepseek-flash', BIG_B64);
  weird.messages[0].content[0].source.media_type = 'text/plain';
  await post(port, weird);
  assert.strictEqual(JSON.parse(cap.body).messages[0].content[0].type, 'text');

  const notB64 = imageMessage('deepseek-flash', 'sk-ant-' + 'x'.repeat(600));
  await post(port, notB64);
  const sent = JSON.parse(cap.body);
  assert.strictEqual(sent.messages[0].content[0].type, 'text');
  assert.doesNotMatch(cap.body, /sk-ant-x{20}/, '画像と偽った文字列は送らない');

  const huge = imageMessage('deepseek-flash', 'A'.repeat(7 * 1024 * 1024));
  await post(port, huge);
  assert.strictEqual(JSON.parse(cap.body).messages[0].content[0].type, 'text');
});

test('Gateway: AI_SAFE_DS_PASS_IMAGES=0 なら flash 宛てでも送らない', () => {
  const prev = process.env.AI_SAFE_DS_PASS_IMAGES;
  process.env.AI_SAFE_DS_PASS_IMAGES = '0';
  try {
    assert.strictEqual(visionCapableModel('deepseek-flash'), false);
  } finally {
    if (prev === undefined) delete process.env.AI_SAFE_DS_PASS_IMAGES; else process.env.AI_SAFE_DS_PASS_IMAGES = prev;
  }
});
