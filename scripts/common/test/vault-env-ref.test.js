'use strict';
// 自由枠の住所 aisafety://user/<名前> と、.env 差し替えの回帰。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PREFIX = `ai-safety-test-${process.pid}.`;
process.env.AI_SAFE_KEYCHAIN_PREFIX = PREFIX;
const SECRET_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-envref-'));
process.env.AI_SAFE_SECRET_DIR = SECRET_DIR;

const store = require('../secret-store.js');
const canVault = process.platform === 'darwin' && store.available();
const skipVault = canVault ? false : 'OS の金庫を使えない環境のため skip';

test('userRef / parseUserRef は名前を往復し、不正な住所は拒否する', () => {
  assert.strictEqual(store.userRef('openai'), 'aisafety://user/openai');
  assert.strictEqual(store.parseUserRef('aisafety://user/openai'), 'openai');
  assert.strictEqual(store.parseUserRef('  aisafety://user/openai  '), 'openai');
  assert.strictEqual(store.parseUserRef('aisafety://user/../x'), null);
  assert.strictEqual(store.parseUserRef('aisafety://user/foo.bar'), null);
  assert.strictEqual(store.parseUserRef('op://ai-safety/Gemini/credential'), null);
  assert.strictEqual(store.parseUserRef('sk-real-key'), null);
  assert.throws(() => store.userRef('../x'), /invalid user secret name/);
});

test('parseEnvFile は KEY=value と引用符とコメントを読み、コマンド置換はしない', () => {
  const parsed = store.parseEnvFile([
    '# comment',
    'OPENAI_API_KEY=aisafety://user/openai',
    "QUOTED='aisafety://user/メモ'",
    'EXPORT_OK=plain',
    'export FROM_EXPORT=aisafety://user/x',
    'BAD NAME=nope',
    'not-an-assignment',
    '',
  ].join('\n'));
  assert.strictEqual(parsed.OPENAI_API_KEY, 'aisafety://user/openai');
  assert.strictEqual(parsed.QUOTED, 'aisafety://user/メモ');
  assert.strictEqual(parsed.FROM_EXPORT, 'aisafety://user/x');
  assert.strictEqual(parsed.EXPORT_OK, 'plain');
  assert.strictEqual(parsed['BAD NAME'], undefined);
});

test('applyEnvRefs は不正な aisafety:// を欠落として fail-closed する', () => {
  const { resolved, missing } = store.applyEnvRefs({
    A: 'aisafety://user/../x',
    B: 'literal-not-a-ref',
  });
  assert.strictEqual(resolved.B, 'literal-not-a-ref');
  assert.strictEqual(resolved.A, undefined);
  assert.strictEqual(missing.length, 1);
  assert.strictEqual(missing[0].reason, 'invalid-ref');
});

test('--user-ref は住所だけを出し、値は出さない', () => {
  const bin = path.join(__dirname, '..', 'secret-store.js');
  const r = spawnSync(process.execPath, [bin, '--user-ref', 'openai'], { encoding: 'utf8' });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.strictEqual(r.stdout.trim(), 'aisafety://user/openai');
});

test('--run は住所を本物に差し替えて子プロセスへ渡し、標準出力に本物を出さない', {
  skip: skipVault,
}, () => {
  const name = `envref${process.pid}`;
  const secret = 'TEST-SECRET-do-not-print-xyz';
  try {
    store.userSet(name, secret);
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'envref-run-'));
    const envFile = path.join(dir, '.env');
    fs.writeFileSync(envFile, `DEMO_KEY=aisafety://user/${name}\n`);
    const bin = path.join(__dirname, '..', 'secret-store.js');
    const r = spawnSync(process.execPath, [
      bin, '--run', '--env-file', envFile, '--',
      process.execPath, '-e', 'process.stdout.write(process.env.DEMO_KEY === process.argv[1] ? "ok" : "bad")',
      secret,
    ], { encoding: 'utf8' });
    assert.strictEqual(r.status, 0, r.stderr + r.stdout);
    assert.strictEqual(r.stdout, 'ok');
    assert.doesNotMatch(r.stdout + r.stderr, new RegExp(secret));
  } finally {
    try { store.userRemove(name); } catch { /* ignore */ }
  }
});

test('--run は金庫に無い住所で fail-closed し、コマンドを起動しない', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'envref-miss-'));
  const envFile = path.join(dir, '.env');
  fs.writeFileSync(envFile, 'DEMO_KEY=aisafety://user/doesnotexistxyz\n');
  const marker = path.join(dir, 'ran.txt');
  const bin = path.join(__dirname, '..', 'secret-store.js');
  const r = spawnSync(process.execPath, [
    bin, '--run', '--env-file', envFile, '--',
    process.execPath, '-e', `require("fs").writeFileSync(${JSON.stringify(marker)}, "ran")`,
  ], { encoding: 'utf8' });
  assert.notStrictEqual(r.status, 0);
  assert.ok(!fs.existsSync(marker), '欠落なのに子プロセスが走った');
  assert.match(r.stderr, /見つかりません/);
});
