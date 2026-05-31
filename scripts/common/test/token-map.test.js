const { test } = require('node:test');
const assert = require('node:assert');
const { createTokenMap } = require('../token-map.js');

test('alloc returns a token and dedupes by value', () => {
  const tm = createTokenMap();
  const t1 = tm.alloc('tokyo@example.com', 'email');
  const t2 = tm.alloc('tokyo@example.com', 'email');
  assert.strictEqual(t1, t2, 'same value → same token');
  assert.match(t1, /^〔R\d+〕$/);
  assert.strictEqual(tm.getOriginal(t1), 'tokyo@example.com');
});

test('distinct values get distinct tokens', () => {
  const tm = createTokenMap();
  const a = tm.alloc('a@x.com', 'email');
  const b = tm.alloc('b@x.com', 'email');
  assert.notStrictEqual(a, b);
});

test('getOriginal returns undefined for unknown token', () => {
  const tm = createTokenMap();
  assert.strictEqual(tm.getOriginal('〔R999〕'), undefined);
});

test('respects max cap (drops oldest)', () => {
  const tm = createTokenMap({ max: 2 });
  const a = tm.alloc('1', 'denylist');
  tm.alloc('2', 'denylist');
  tm.alloc('3', 'denylist'); // evicts '1'
  assert.strictEqual(tm.getOriginal(a), undefined, 'oldest evicted');
});
