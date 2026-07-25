'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..', '..');

function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}

test('Windows Bouncer runner binds local services and cleans up only what it started', () => {
  const script = read('bouncer-gateway/scripts/run-local.ps1');
  assert.match(script, /127\.0\.0\.1/);
  assert.match(script, /bouncer-gemma/);
  assert.match(script, /PYTHONPATH/);
  assert.match(script, /finally/);
  assert.match(script, /lms.*unload/i);
  assert.match(script, /server stop/i);
});

test('Windows integrated launcher has standard no-LLM and maximum local-Bouncer profiles', () => {
  const script = read('scripts/windows/launch-integrated.ps1');
  assert.match(script, /ValidateSet\('codex','claude','opencode'\)/);
  assert.match(script, /ValidateSet\('standard','assisted','maximum'\)/);
  assert.match(script, /standard/);
  assert.match(script, /maximum/);
  assert.match(script, /run-local\.ps1/);
  assert.match(script, /127\.0\.0\.1:8787\/bouncer\/health/);
  assert.match(script, /BOUNCER_INTEGRATED_MODE/);
  assert.match(script, /AI_SAFE_DRY_RUN/);
});

test('Windows legacy start buttons route through integrated standard mode', () => {
  const codex = read('workspace-template/スタート/2_セーフCodexを起動.bat');
  const claude = read('workspace-template/スタート/3_セーフClaudeを起動.bat');

  assert.match(codex, /launch-integrated\.ps1/i);
  assert.match(codex, /-Agent codex -Profile standard/i);
  assert.match(claude, /launch-integrated\.ps1/i);
  assert.match(claude, /-Agent claude -Profile standard/i);
});
