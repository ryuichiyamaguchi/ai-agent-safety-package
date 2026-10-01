'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.join(__dirname, '..', '..', '..');
const vision = require(path.join(root, 'scripts', 'common', 'gemini-vision-mcp.js'));

test('detectImageMime は PNG/JPEG を認め、テキストを拒否する', () => {
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]);
  const text = Buffer.from('GEMINI_API_KEY=secret-value-here');
  assert.strictEqual(vision.detectImageMime(png), 'image/png');
  assert.strictEqual(vision.detectImageMime(jpeg), 'image/jpeg');
  assert.strictEqual(vision.detectImageMime(text), null);
});

test('readImage は非画像ファイルを Google に送らず拒否する', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vision-read-'));
  const envPath = path.join(dir, '.env');
  fs.writeFileSync(envPath, 'DEEPSEEK_API_KEY=sk-test-not-real\n');
  try {
    const r = vision.readImage(envPath);
    assert.strictEqual(r.ok, false);
    assert.match(r.message, /対応画像ファイル/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('tools/list は describe_image を 1 個返す', async () => {
  let sent = null;
  const orig = process.stdout.write;
  process.stdout.write = (chunk) => { sent = String(chunk); return true; };
  try {
    await vision.handle({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} });
  } finally {
    process.stdout.write = orig;
  }
  const msg = JSON.parse(sent);
  assert.strictEqual(msg.result.tools[0].name, 'describe_image');
});

test('キー未設定の案内は専用ボタンを指す（旧平文パスを案内しない）', () => {
  const src = fs.readFileSync(path.join(root, 'scripts', 'common', 'gemini-vision-mcp.js'), 'utf8');
  assert.match(src, /キーと金庫\/3_AIコーチのキーを登録/);
  assert.doesNotMatch(src, /gemini-api-key\.txt/);
});

test('404・429・混雑(5xx)・通信エラーは fallback 対象、認証エラーなどは対象外', () => {
  assert.strictEqual(vision.shouldFallback({ ok: false, status: 404, gstatus: 'NOT_FOUND' }), true);
  assert.strictEqual(vision.shouldFallback({ ok: false, status: 429, gstatus: 'RESOURCE_EXHAUSTED' }), true);
  assert.strictEqual(vision.shouldFallback({ ok: false, status: 503, gstatus: 'UNAVAILABLE' }), true);
  assert.strictEqual(vision.shouldFallback({ ok: false, status: 401, gstatus: 'UNAUTHENTICATED' }), false);
  assert.strictEqual(vision.shouldFallback({ ok: true, status: 200 }), false);
});

test('honesty prompt: 画像は 1 回だけ見る・送信していない案内のときは describe_image・画像生成は agy が標準', () => {
  const t = fs.readFileSync(path.join(root, 'scripts', 'common', 'deepseek-honesty-prompt.txt'), 'utf8');
  assert.match(t, /image_path/);
  assert.match(t, /describe_image/);
  assert.match(t, /generate_image_agy/);
  assert.match(t, /reference_images/);
  // 2026-10: 「あなたは画像を直接見られない」と書くと deepseek-flash でも Gemini に 9 回説明させに行った
  assert.doesNotMatch(t, /あなたは画像を直接見られない/);
});
