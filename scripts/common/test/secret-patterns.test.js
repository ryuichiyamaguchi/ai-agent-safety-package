const { test } = require('node:test');
const assert = require('node:assert');
const { maskSecrets } = require('../secret-patterns.js');

test('masks an OpenAI key and reports a count', () => {
  const r = maskSecrets('key=sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX');
  assert.ok(!/sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX/.test(r.masked), 'raw key must be gone');
  assert.ok(/\[MASKED:openai\]/.test(r.masked));
  assert.strictEqual(r.counts.openai, 1);
  assert.strictEqual(r.counts.total, 1);
});

test('masks an Anthropic key as anthropic (more specific wins)', () => {
  const r = maskSecrets('sk-ant-ABCDEFGHIJKLMNOPQRSTUVWX');
  assert.ok(/\[MASKED:anthropic\]/.test(r.masked));
  assert.ok(!/\[MASKED:openai\]/.test(r.masked));
});

test('masks each remaining type', () => {
  const cases = {
    google: 'AIzaABCDEFGHIJKLMNOPQRSTUVWXYZ012',
    aws: 'AKIAABCDEFGHIJKLMNOP',
    github: 'ghp_' + 'a'.repeat(36),
    slack: 'xoxb-1234567890-abcdefghij',
    jwt: 'eyJabc.eyJdef.signature123',
    generic: 'password = hunter2hunter2',
  };
  for (const [type, sample] of Object.entries(cases)) {
    const r = maskSecrets(sample);
    assert.ok(r.counts[type] >= 1, `${type} not detected`);
    assert.ok(!r.masked.includes(sample), `${type} raw value leaked`);
    assert.ok(r.counts.total >= 1, `${type} total`);
  }
});

test('masks PEM private key block markers', () => {
  const r = maskSecrets('-----BEGIN RSA PRIVATE KEY-----\nx\n-----END RSA PRIVATE KEY-----');
  assert.ok(/\[MASKED:private_key_begin\]/.test(r.masked));
  assert.ok(/\[MASKED:private_key_end\]/.test(r.masked));
  assert.strictEqual(r.counts.private_key, 1);
});

test('leaves ordinary text untouched and total=0', () => {
  const r = maskSecrets('クライミングジムの予約を取りたい');
  assert.strictEqual(r.masked, 'クライミングジムの予約を取りたい');
  assert.strictEqual(r.counts.total, 0);
});
