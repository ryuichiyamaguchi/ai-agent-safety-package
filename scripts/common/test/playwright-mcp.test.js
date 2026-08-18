'use strict';
// Playwright（ブラウザ自動操作・UIテスト）を OpenCode から使えるようにするローカル MCP の回帰テスト。
//
// ここで守りたいこと:
//   1. Playwright MCP (@playwright/mcp) が local MCP として登録される
//   2. ブラウザ操作・外部アクセスを伴うため、権限は必ず ask になる
//   3. AI_SAFE_DCLAUDE_PLAYWRIGHT=0 で個別に無効化できる
//   4. 設定全体の生成・起動前検証（verifyResolvedConfig）と整合している
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('node:path');

const root = path.join(__dirname, '..', '..', '..');
const { buildMcpConfig, buildOpenCodeConfig, verifyResolvedConfig } = require(path.join(root, 'scripts', 'common', 'opencode-config.js'));

test('Playwright MCP はデフォルトで local MCP として登録され、権限は ask になる', () => {
  const mcpDir = path.join(root, 'scripts', 'common');
  const { mcp, permission } = buildMcpConfig({ mcpDir, env: {} });
  assert.ok(mcp.playwright, 'Playwright MCP が登録されていること');
  assert.strictEqual(mcp.playwright.type, 'local');
  assert.deepStrictEqual(mcp.playwright.command, ['node', path.join(mcpDir, 'playwright-mcp.js')]);
  assert.strictEqual(mcp.playwright.enabled, true);
  assert.strictEqual(mcp.playwright.timeout, 90000);
  assert.strictEqual(permission['playwright_*'], 'ask', 'ブラウザ操作は安全のため ask であること');
});

test('AI_SAFE_DCLAUDE_PLAYWRIGHT=0 で無効化できる', () => {
  const { mcp, permission } = buildMcpConfig({
    mcpDir: path.join(root, 'scripts', 'common'),
    env: { AI_SAFE_DCLAUDE_PLAYWRIGHT: '0' },
  });
  assert.ok(!mcp.playwright, '無効化フラグが効くこと');
  assert.ok(!permission['playwright_*'], '権限も登録されないこと');
});

test('buildOpenCodeConfig で Playwright MCP が含まれ、解決済み検証を通過する', () => {
  const config = buildOpenCodeConfig({
    port: 8788,
    gatewayToken: 'test-token-12345678901234567890123456789012',
    mcpDir: path.join(root, 'scripts', 'common'),
    monitorPlugin: path.join(root, 'scripts', 'common', 'opencode-bouncer-monitor.mjs'),
  });

  assert.ok(config.mcp.playwright, 'OpenCode 設定に Playwright MCP が載っていること');
  assert.strictEqual(config.permission['playwright_*'], 'ask');
  const problems = verifyResolvedConfig(config);
  assert.deepStrictEqual(problems, [], '検証で問題が報告されないこと');
});
