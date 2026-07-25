'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { buildOpenCodeConfig, isSupportedVersion } = require('../opencode-config.js');

test('OpenCode runtime config forces DeepSeek through the loopback inspection gateway', () => {
  const config = buildOpenCodeConfig({ port: 8788, enableWebSearch: false });
  const provider = config.provider['bouncer-deepseek'];

  assert.strictEqual(config.model, 'bouncer-deepseek/deepseek-v4-pro');
  assert.strictEqual(config.small_model, 'bouncer-deepseek/deepseek-v4-flash');
  assert.strictEqual(config.default_agent, 'bouncer');
  assert.strictEqual(config.share, 'disabled');
  assert.deepStrictEqual(config.instructions, ['AGENTS.md']);
  assert.strictEqual(provider.options.baseURL, 'http://127.0.0.1:8788/v1');
  assert.strictEqual(provider.options.apiKey, 'bouncer-local-only');
  assert.ok(!JSON.stringify(config).includes('api.deepseek.com'));
  assert.deepStrictEqual(Object.keys(provider.models).sort(), [
    'deepseek-v4-flash',
    'deepseek-v4-pro',
  ]);
  assert.strictEqual(config.agent.bouncer.model, 'bouncer-deepseek/deepseek-v4-pro');
  assert.strictEqual(config.agent['bouncer-helper'].mode, 'subagent');
  assert.strictEqual(config.agent['bouncer-helper'].model, 'bouncer-deepseek/deepseek-v4-flash');
  assert.strictEqual(config.agent.bouncer.permission.task['*'], 'deny');
  assert.strictEqual(config.agent.bouncer.permission.task['bouncer-helper'], 'allow');
});

test('OpenCode runtime config preserves useful reads while gating mutations and external access', () => {
  const config = buildOpenCodeConfig({ enableWebSearch: false });

  assert.strictEqual(config.permission.edit, 'ask');
  assert.strictEqual(config.permission.external_directory, 'deny');
  assert.strictEqual(config.permission.websearch, 'deny');
  assert.strictEqual(config.permission.webfetch, 'ask');
  assert.strictEqual(config.permission.read['*'], 'allow');
  assert.strictEqual(config.permission.read['*.env'], 'deny');
  assert.strictEqual(config.permission.bash['*'], 'ask');
  assert.strictEqual(config.permission.bash['git status*'], 'allow');
  assert.strictEqual(config.permission.bash['git push*'], 'deny');
  assert.strictEqual(config.permission.bash['rm *'], 'deny');
  assert.strictEqual(config.permission.skill, 'allow');
  assert.strictEqual(config.permission.task, 'allow');
});

test('Exa web search is opt-in and only relaxes websearch to ask', () => {
  const disabled = buildOpenCodeConfig({ enableWebSearch: false });
  const enabled = buildOpenCodeConfig({ enableWebSearch: true });

  assert.strictEqual(disabled.permission.websearch, 'deny');
  assert.strictEqual(enabled.permission.websearch, 'ask');
  assert.deepStrictEqual(enabled.provider, disabled.provider);
  assert.strictEqual(enabled.permission.edit, 'ask');
  assert.strictEqual(enabled.permission.external_directory, 'deny');
});

test('OpenCode minimum supported version is 1.14.24', () => {
  assert.strictEqual(isSupportedVersion('1.14.23'), false);
  assert.strictEqual(isSupportedVersion('1.14.24'), true);
  assert.strictEqual(isSupportedVersion('1.18.4'), true);
  assert.strictEqual(isSupportedVersion('2.0.0-beta.1'), true);
  assert.strictEqual(isSupportedVersion('garbage'), false);
});

test('CLI output is valid JSON and contains no environment secret', () => {
  const script = path.join(__dirname, '..', 'opencode-config.js');
  const output = require('node:child_process').execFileSync(
    process.execPath,
    [script, '--port', '8790'],
    {
      encoding: 'utf8',
      env: { ...process.env, DEEPSEEK_API_KEY: 'must-not-appear' },
    },
  );
  const parsed = JSON.parse(output);
  assert.strictEqual(parsed.provider['bouncer-deepseek'].options.baseURL, 'http://127.0.0.1:8790/v1');
  assert.ok(!output.includes('must-not-appear'));
});

test('installer-facing config output does not write credentials to OpenCode auth storage', () => {
  const config = buildOpenCodeConfig();
  const serialized = JSON.stringify(config);
  const openCodeAuth = path.join(os.homedir(), '.local', 'share', 'opencode', 'auth.json');

  assert.ok(!serialized.includes(openCodeAuth));
  assert.ok(!serialized.includes('DEEPSEEK_API_KEY'));
  assert.ok(!serialized.includes('ANTHROPIC_AUTH_TOKEN'));
});
