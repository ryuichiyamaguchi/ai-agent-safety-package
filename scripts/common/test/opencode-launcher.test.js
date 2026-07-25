'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..', '..');

function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}

test('macOS OpenCode launcher enforces config after project config and requires gateway health', () => {
  const script = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  assert.match(script, /OPENCODE_CONFIG_CONTENT/);
  assert.match(script, /OPENCODE_DISABLE_PROJECT_CONFIG/);
  assert.match(script, /OPENCODE_PURE/);
  assert.match(script, /opencode-config\.js/);
  assert.match(script, /DS_GATEWAY_AUTH_FILE/);
  assert.match(script, /api\.deepseek\.com/);
  assert.match(script, /\/healthz/);
  assert.match(script, /1\.14\.24/);
  assert.match(script, /unset OPENCODE_ENABLE_EXA/);
  assert.match(script, /AI_SAFE_DRY_RUN/);
});

test('Windows OpenCode launcher provides the same fail-closed controls', () => {
  const script = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');
  assert.match(script, /OPENCODE_CONFIG_CONTENT/);
  assert.match(script, /OPENCODE_DISABLE_PROJECT_CONFIG/);
  assert.match(script, /OPENCODE_PURE/);
  assert.match(script, /opencode-config\.js/);
  assert.match(script, /DS_GATEWAY_AUTH_FILE/);
  assert.match(script, /api\.deepseek\.com/);
  assert.match(script, /\/healthz/);
  assert.match(script, /1\.14\.24/);
  assert.match(script, /OPENCODE_ENABLE_EXA/);
  assert.match(script, /AI_SAFE_DRY_RUN/);
});

test('Mac and Windows installers place Bouncer and OpenCode skill compatibility paths', () => {
  const mac = read('scripts/macos/install.sh');
  const win = read('scripts/windows/install.ps1');

  assert.match(mac, /bouncer-gateway/);
  assert.match(mac, /\.opencode\/skills/);
  assert.match(mac, /AGENTS\.md/);
  assert.match(win, /bouncer-gateway/);
  assert.match(win, /\.opencode\\skills/);
  assert.match(win, /AGENTS\.md/);
});

test('legacy d-claude launchers remain present as an advanced compatibility route', () => {
  assert.ok(fs.existsSync(path.join(root, 'scripts/macos/deepseek/launch-deepseek-gateway.sh')));
  assert.ok(fs.existsSync(path.join(root, 'scripts/windows/deepseek/launch-deepseek-gateway.ps1')));
  assert.ok(fs.existsSync(path.join(root, 'workspace-template/d-claude.cmd')));
});
