const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs'); const os = require('node:os'); const path = require('node:path');
const { loadDenylist, loadDenylistResult } = require('../denylist.js');

test('loads terms, ignores comments and blank lines', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dl-'));
  const f = path.join(dir, 'denylist.txt');
  fs.writeFileSync(f, '田中商事\n# コメント\n\n  〇〇市△△町1-2-3  \n');
  const terms = loadDenylist(f);
  assert.deepStrictEqual(terms, ['田中商事', '〇〇市△△町1-2-3']);
});

test('returns empty array when file is missing', () => {
  assert.deepStrictEqual(loadDenylist('/no/such/file.txt'), []);
});

// F-4: 「設定あり×読込失敗」と「未設定」を区別する。
test('loadDenylistResult: configured-but-unreadable yields fail-closed sentinel', () => {
  const r = loadDenylistResult('/no/such/configured-denylist.txt', { configured: true });
  assert.strictEqual(Array.isArray(r), false, 'must not be a plain array on fail-closed');
  assert.strictEqual(r.failClosed, true);
});

test('loadDenylistResult: configured-and-readable yields the term array', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dl-cfg-'));
  const f = path.join(dir, 'denylist.txt');
  fs.writeFileSync(f, '田中商事\n');
  const r = loadDenylistResult(f, { configured: true });
  assert.deepStrictEqual(r, ['田中商事']);
});

test('loadDenylistResult: unset (not configured) missing default file = [] (normal)', () => {
  const prev = process.env.DENYLIST_PATH;
  delete process.env.DENYLIST_PATH;
  const prevLog = process.env.AI_SAFE_LOG_DIR;
  process.env.AI_SAFE_LOG_DIR = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'dl-unset2-')), 'logs');
  try {
    assert.deepStrictEqual(loadDenylistResult(), []);
  } finally {
    if (prev === undefined) delete process.env.DENYLIST_PATH; else process.env.DENYLIST_PATH = prev;
    if (prevLog === undefined) delete process.env.AI_SAFE_LOG_DIR; else process.env.AI_SAFE_LOG_DIR = prevLog;
  }
});
