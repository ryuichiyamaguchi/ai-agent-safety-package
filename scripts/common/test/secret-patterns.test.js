const { test } = require('node:test');
const assert = require('node:assert');
const { maskSecrets, maskText, COUNT_KEYS } = require('../secret-patterns.js');

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

test('masks generic secret in JSON-quoted form', () => {
  const r = maskSecrets('{"password":"hunter2hunter2","api_key":"longsecretvalue123"}');
  assert.ok(!r.masked.includes('hunter2hunter2'));
  assert.ok(!r.masked.includes('longsecretvalue123'));
  assert.ok(r.counts.generic >= 2);
  assert.doesNotThrow(() => JSON.parse(r.masked)); // still valid JSON
});

test('masks the entire private key block including body', () => {
  const r = maskSecrets('-----BEGIN RSA PRIVATE KEY-----\nMIIBhupersecretkeymaterial\n-----END RSA PRIVATE KEY-----');
  assert.ok(/\[MASKED:private_key\]/.test(r.masked));
  assert.ok(!r.masked.includes('MIIBhupersecretkeymaterial'), 'key body leaked');
  assert.strictEqual(r.counts.private_key, 1);
});

test('masks unpaired BEGIN private key marker (fallback)', () => {
  const r = maskSecrets('-----BEGIN RSA PRIVATE KEY-----\nx');
  assert.ok(/\[MASKED:private_key_begin\]/.test(r.masked));
  assert.strictEqual(r.counts.private_key, 1);
});

test('leaves ordinary text untouched and total=0', () => {
  const r = maskSecrets('クライミングジムの予約を取りたい');
  assert.strictEqual(r.masked, 'クライミングジムの予約を取りたい');
  assert.strictEqual(r.counts.total, 0);
});

test('reversible categories use alloc token; hard secrets stay [MASKED]', () => {
  const seen = new Map(); let n = 0;
  const alloc = (v) => { if (seen.has(v)) return seen.get(v); const t = `〔R${++n}〕`; seen.set(v, t); return t; };
  const r = maskText('mail tokyo@example.com key sk-ant-ABCDEFGHIJKLMNOPQRSTUVWX', { alloc, denylistTerms: [] });
  assert.match(r.masked, /〔R\d+〕/);
  assert.ok(!r.masked.includes('tokyo@example.com'));
  assert.ok(r.masked.includes('[MASKED:anthropic]'));
  assert.strictEqual(r.counts.email, 1);
  assert.strictEqual(r.counts.anthropic, 1);
});

test('credit card masked only when Luhn-valid (irreversible)', () => {
  const good = maskText('card 4111111111111111', { denylistTerms: [] });
  assert.ok(good.masked.includes('[MASKED:credit_card]'));
  const bad = maskText('num 4111111111111112', { denylistTerms: [] });
  assert.ok(bad.masked.includes('4111111111111112'), 'invalid card not masked');
});

test('maskSecrets backward-compatible: hard secrets static-masked', () => {
  const r = maskSecrets('sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX');
  assert.ok(r.masked.includes('[MASKED:openai]'));
});

test('numeric PII masked only with nearby context word', () => {
  const withCtx = maskText('電話 090-1234-5678 まで', { alloc: (v)=>`〔R1〕`, denylistTerms: [] });
  assert.ok(!withCtx.masked.includes('090-1234-5678'), 'phone masked when 電話 near');
  const noCtx = maskText('注文番号 090-1234-5678 です', { denylistTerms: [] });
  assert.ok(noCtx.masked.includes('090-1234-5678'), 'no context word → not masked');
});

test('mynumber masked near 個人番号 (irreversible)', () => {
  const r = maskText('個人番号 123456789012 です', { alloc:(v)=>`〔R1〕`, denylistTerms: [] });
  assert.ok(r.masked.includes('[MASKED:mynumber]'), 'mynumber irreversible even with alloc');
  assert.ok(!r.masked.includes('123456789012'));
});

test('denylist substring, case-insensitive, reversible', () => {
  const seen=new Map(); let n=0; const alloc=(v)=>{ if(seen.has(v))return seen.get(v); const t=`〔R${++n}〕`; seen.set(v,t); return t; };
  const r = maskText('担当は 田中商事 の ABC です', { alloc, denylistTerms: ['田中商事','abc'] });
  assert.ok(!r.masked.includes('田中商事'));
  assert.ok(!r.masked.includes('ABC'));
  assert.strictEqual(r.counts.denylist, 2);
  assert.match(r.masked, /〔R\d+〕/);
});

test('multi-char context word straddling the window boundary still gates (M1 fix)', () => {
  // 電話(2文字)+19文字 → phone offset=21, 窓先頭=1 が語の途中。旧 slice 実装は取りこぼしたが重なり判定で near。
  const r = maskText('電話' + 'x'.repeat(19) + '090-1234-5678', { alloc: (v)=>`〔R1〕`, denylistTerms: [] });
  assert.ok(!r.masked.includes('090-1234-5678'), '電話 straddling boundary must gate');
  const far = maskText('電話' + 'x'.repeat(60) + '090-1234-5678', { denylistTerms: [] });
  assert.ok(far.masked.includes('090-1234-5678'), 'far context word must NOT gate');
});

test('denylist never matches inside an emitted reversible token (C2)', () => {
  const seen = new Map(); let n = 0;
  const alloc = (v) => { if (seen.has(v)) return seen.get(v); const t = `〔R${++n}〕`; seen.set(v, t); return t; };
  // email→〔R1〕。denylist 'R1' はトークン内部に出現するが保護され二重置換しない。
  const r = maskText('連絡先 user@example.com', { alloc, denylistTerms: ['R1'] });
  const tokens = r.masked.match(/〔R\d+〕/g) || [];
  assert.strictEqual(tokens.length, 1, 'exactly one token (no double-wrap)');
  assert.ok(!r.masked.includes('〔〔'), 'no nested token corruption');
  assert.strictEqual(r.counts.denylist, 0, 'denylist must not fire inside token body');
});

test('email regex is ReDoS-safe on adversarial input', () => {
  const evil1 = 'a'.repeat(50000) + '@' + 'a'.repeat(50000);
  const evil2 = 'x@' + 'a.'.repeat(40000);
  const t0 = process.hrtime.bigint();
  maskText(evil1, { denylistTerms: [] });
  maskText(evil2, { denylistTerms: [] });
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  assert.ok(ms < 1000, `email masking must stay fast (was ${ms}ms)`);
});
