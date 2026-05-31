const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { maskSecrets } = require('../secret-patterns.js');

const FIXTURE = path.join(__dirname, 'fixtures', 'secrets-sample.txt');
const RAW_SECRETS = [
  'sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX',
  'sk-ant-ABCDEFGHIJKLMNOPQRSTUVWX',
  'AIzaABCDEFGHIJKLMNOPQRSTUVWXYZ012',
  'AKIAABCDEFGHIJKLMNOP',
  'ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'xoxb-1234567890-abcdefghij',
  'eyJabc.eyJdef.signature123',
  'hunter2hunter2',
];

test('JS masks every raw secret in the fixture', () => {
  const raw = fs.readFileSync(FIXTURE, 'utf8');
  const { masked } = maskSecrets(raw);
  for (const s of RAW_SECRETS) {
    assert.ok(!masked.includes(s), `JS leaked: ${s}`);
  }
});

test('bash secret-scan.sh masks the same fixture (parity)', (t) => {
  const sh = path.join(__dirname, '..', '..', 'macos', 'secret-scan.sh');
  if (!fs.existsSync(sh)) { t.skip('secret-scan.sh not available'); return; }
  let out;
  try {
    out = execFileSync('bash', [sh, '--mask', '--quiet', FIXTURE], { encoding: 'utf8' });
  } catch (e) {
    out = (e.stdout || '').toString();
  }
  for (const s of RAW_SECRETS) {
    assert.ok(!out.includes(s), `bash leaked: ${s}`);
  }
});
