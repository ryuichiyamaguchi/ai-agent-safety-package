'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// この検査は「鍵が未登録なら MCP に載せない」を見る。opencode-config は v1.17.0 から
// OS の金庫も参照するので、検査を実行する PC に本物の鍵が登録されていると結果が変わる。
// 検査専用の接頭辞に逃がして、実機の登録状態から切り離す（保存方式は変えない）。
process.env.AI_SAFE_KEYCHAIN_PREFIX = 'ai-safety-test-opencode-config.';
const {
  buildOpenCodeConfig,
  buildEnforcedPermissionEnv,
  buildMcpConfig,
  verifyResolvedConfig,
  parseResolvedConfigOutput,
  isSupportedVersion,
  MCP_SERVERS,
} = require('../opencode-config.js');

// 送信検査 Gateway は呼び出し元認証（起動ごとの乱数トークン）を必須にした。ランチャーは
// 採番したトークンを DS_GATEWAY_TOKEN で渡し、それがそのまま provider の apiKey になる。
// 子プロセスで動く CLI テストにも継承させたいので process.env へ入れる。
const TEST_TOKEN = 'test-gateway-token-0123456789abcdef';
process.env.DS_GATEWAY_TOKEN = TEST_TOKEN;

// 起動前検査は「決定的 deny 床のプラグインが設定に残っているか」も見る。ランチャーは必ず
// --monitor-plugin を渡すので、検査に掛ける設定はこの形で作る（プラグイン抜きの設定は
// 「床を外された設定」そのものなので、検査を通ってはいけない）。
const MONITOR_PLUGIN = '/opt/bouncer/opencode-bouncer-monitor.mjs';
function intactConfig(options = {}) {
  return buildOpenCodeConfig({ monitorPlugin: MONITOR_PLUGIN, ...options });
}

test('OpenCode runtime config forces DeepSeek through the loopback inspection gateway', () => {
  const config = buildOpenCodeConfig({
    port: 8788,
    enableWebSearch: false,
    monitorPlugin: '/opt/bouncer/opencode-bouncer-monitor.mjs',
  });
  const provider = config.provider['bouncer-deepseek'];

  assert.strictEqual(config.model, 'bouncer-deepseek/deepseek-v4-flash');
  assert.strictEqual(config.small_model, 'bouncer-deepseek/deepseek-v4-flash');
  assert.strictEqual(config.default_agent, 'bouncer');
  assert.strictEqual(config.share, 'disabled');
  assert.deepStrictEqual(config.instructions, ['AGENTS.md']);
  assert.strictEqual(provider.options.baseURL, 'http://127.0.0.1:8788/v1');
  // 固定文字列 'bouncer-local-only' は同一 PC の誰でも名乗れたため廃止し、起動ごとの乱数にした。
  assert.strictEqual(provider.options.apiKey, TEST_TOKEN);
  assert.ok(!JSON.stringify(config).includes('bouncer-local-only'));
  assert.ok(!JSON.stringify(config).includes('api.deepseek.com'));
  assert.deepStrictEqual(Object.keys(provider.models).sort(), [
    'deepseek-v4-flash',
    'deepseek-v4-pro',
  ]);
  assert.deepStrictEqual(provider.models['deepseek-v4-pro'].limit, { context: 1048576, output: 393216 });
  assert.deepStrictEqual(provider.models['deepseek-v4-flash'].limit, { context: 1048576, output: 393216 });
  assert.strictEqual(config.agent.bouncer.model, 'bouncer-deepseek/deepseek-v4-flash');
  assert.strictEqual(config.agent['bouncer-helper'].mode, 'subagent');
  assert.strictEqual(config.agent['bouncer-helper'].model, 'bouncer-deepseek/deepseek-v4-flash');
  assert.strictEqual(config.agent.bouncer.permission.task['*'], 'deny');
  assert.strictEqual(config.agent.bouncer.permission.task['bouncer-helper'], 'allow');
  assert.deepStrictEqual(config.plugin, ['file:///opt/bouncer/opencode-bouncer-monitor.mjs']);
});

test('OpenCode runtime config preserves useful reads while gating mutations and external access', () => {
  const config = buildOpenCodeConfig({ enableWebSearch: false });

  // edit は素の 'ask' ではなくパターン表。1 度「常に許可」を押しただけで安全ルールの
  // 置き場（.ai-safety）まで書き換えられる状態を残さないため、そこだけは deny で固定する。
  assert.strictEqual(config.permission.edit['*'], 'ask');
  assert.strictEqual(config.permission.edit['*.ai-safety/**'], 'deny');
  assert.strictEqual(config.permission.edit['**/.ai-safety/**'], 'deny');
  // 作業フォルダの外は既定 deny のまま。開けてあるのは『受講者が自分の道具を増やす置き場』だけ。
  assert.strictEqual(config.permission.external_directory['*'], 'deny');
  assert.strictEqual(config.permission.external_directory['~/.claude/skills/**'], 'allow');
  assert.strictEqual(config.permission.websearch, 'deny');
  assert.strictEqual(config.permission.webfetch, 'ask');
  assert.strictEqual(config.permission.read['*'], 'allow');
  assert.strictEqual(config.permission.read['*.env'], 'deny');
  assert.strictEqual(config.permission.bash['*'], 'ask');
  assert.strictEqual(config.permission.bash['git status*'], 'allow');
  // 2026-08-20: git push は「取り消しにくいが正当用途も多い」ので deny → ask に緩和。
  assert.strictEqual(config.permission.bash['git push*'], 'ask');
  assert.strictEqual(config.permission.bash['rm *'], 'deny');
  assert.deepStrictEqual(config.permission.skill, { '*': 'allow' });
  assert.strictEqual(config.permission.task, 'allow');
});

test('Exa web search is opt-in and only relaxes websearch to ask', () => {
  const disabled = buildOpenCodeConfig({ enableWebSearch: false });
  const enabled = buildOpenCodeConfig({ enableWebSearch: true });

  assert.strictEqual(disabled.permission.websearch, 'deny');
  assert.strictEqual(enabled.permission.websearch, 'ask');
  assert.deepStrictEqual(enabled.provider, disabled.provider);
  assert.strictEqual(enabled.permission.edit['*'], 'ask');
  assert.strictEqual(enabled.permission.edit['**/.ai-safety/**'], 'deny');
  assert.strictEqual(enabled.permission.external_directory['*'], 'deny');
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

// --- 回帰: サブエージェントによる deny 床の格下げ ------------------------------
// OpenCode の権限評価は「最後に一致したルールが勝つ」。エージェント個別 permission は
// グローバルの後ろに連結されるので、helper 側に bash 等を書くと deny 床が丸ごと外れる。
test('bouncer-helper does not override any global permission except tightening task', () => {
  const config = buildOpenCodeConfig({ enableWebSearch: false });
  const helper = config.agent['bouncer-helper'].permission;

  assert.deepStrictEqual(Object.keys(helper), ['task'], 'helper が上書きしてよいのは task だけ');
  assert.strictEqual(helper.task, 'deny');
  for (const key of ['bash', 'edit', 'external_directory', 'webfetch', 'websearch', 'read']) {
    assert.strictEqual(helper[key], undefined, `helper が ${key} を上書きしている`);
  }
});

test('web search opt-in does not reintroduce a helper-level override', () => {
  const helper = buildOpenCodeConfig({ enableWebSearch: true }).agent['bouncer-helper'].permission;
  assert.deepStrictEqual(Object.keys(helper), ['task']);
});

// --- 回帰: 前方一致 allow による無確認実行 --------------------------------------
test('prefix allow list excludes commands that can delete or redirect', () => {
  const bash = buildOpenCodeConfig().permission.bash;

  assert.strictEqual(bash['find*'], undefined, 'find* は -delete / -exec rm で無確認削除できる');
  assert.strictEqual(bash['git log*'], undefined, 'git log* は -p でリダイレクト書き込みに使える');
  assert.strictEqual(bash['ls*'], 'allow');
  assert.strictEqual(bash['git status*'], 'allow');
  assert.strictEqual(bash['git diff*'], 'allow');
});

test('irreversible commands stay denied after the 2026-08-20 relaxation', () => {
  const bash = buildOpenCodeConfig().permission.bash;

  // 取り消せない破壊だけを決定的 deny として残す。
  for (const pattern of ['rm *', 'sudo *', 'git reset --hard*']) {
    assert.strictEqual(bash[pattern], 'deny', `${pattern} が禁止になっていない`);
  }
  // oc-safe は自分自身の再帰起動なので閉じたまま。
  assert.strictEqual(bash['oc-safe*'], 'deny', 'oc-safe* が禁止になっていない');
});

// --- 回帰: 2026-08-21 の再訂正（裸起動は禁止しない）-------------------------------
// 前版で入れた「裸の codex / claude を deny」は行きすぎだったので撤回した（山口さん指示）。
// 素の claude / codex を使いたい受講者がいるため、禁止ではなく「一度だけ確認」にする。
// 安全な起動口（codex-safe / claude-safe）は従来どおり ask のままで、1 つも塞がない。
test('bare codex / claude launches are confirmed once, not forbidden', () => {
  const bash = buildOpenCodeConfig().permission.bash;

  assert.strictEqual(bash['codex*'], 'ask', '裸の codex が禁止に戻っている');
  assert.strictEqual(bash['claude*'], 'ask', '裸の claude が禁止に戻っている');
  assert.strictEqual(bash['codex-safe*'], 'ask', '安全ランチャーが塞がれている');
  assert.strictEqual(bash['claude-safe*'], 'ask', '安全ランチャーが塞がれている');
  // opencode / agy の裸起動は表に載せない（'*': 'ask' に落ちるので同じ扱いになる）。
  assert.strictEqual(bash['opencode*'], undefined);
  assert.strictEqual(bash['agy*'], undefined);
  assert.strictEqual(bash['*'], 'ask');
});

// 無人の長時間おまかせモードだけは、確認に答える人がいないので裸起動を deny 側へ倒す。
test('longrun keeps bare launches denied because nobody can answer the card', () => {
  const bash = buildOpenCodeConfig({ longrun: true }).permission.bash;

  for (const pattern of ['codex*', 'claude*', 'codex-safe*', 'claude-safe*']) {
    assert.strictEqual(bash[pattern], 'deny', `longrun で ${pattern} が禁止になっていない`);
  }
});

// --- 回帰: 2026-08-20 の実用最小限への緩和 --------------------------------------
// 撤廃したもの（curl / wget / chmod -R）が「うっかり戻る」と、また正当用途だけが止まる。
// 戻したくなったときは、この期待値ごと意図的に書き換えること。
test('over-broad denies removed on 2026-08-20 do not come back', () => {
  const bash = buildOpenCodeConfig().permission.bash;

  // curl / wget: パッケージ全体は v1.12.0 で一律 deny を撤廃済みなのに、この経路だけ
  // 残っていた。しかも前方一致グロブなので `cd . && curl` で回避でき、正当用途だけを
  // 止める規則になっていた。リモートコード実行と秘密流出は policy 側が独立して deny する。
  assert.strictEqual(bash['curl *'], undefined, 'curl の全面 deny が復活している');
  assert.strictEqual(bash['wget *'], undefined, 'wget の全面 deny が復活している');
  // chmod -R: `chmod -R u+rwX,go-rwx project`（権限を締める正当操作）まで止めていた。
  // 危険な 777 / a+w / o+w は policy の dangerousCommandRegex が引き続き決定的 deny。
  assert.strictEqual(bash['chmod -R *'], undefined, 'chmod -R の一律 deny が復活している');
  // 公開系は deny ではなく確認制。
  assert.strictEqual(bash['git push*'], 'ask');
  assert.strictEqual(bash['npm publish*'], 'ask');
});

// 壁 A の解消: 安全ランチャーのシムは通り、裸起動は止まる。OpenCode は「最後に一致した
// ルールが勝つ」ので、ask が deny より後ろに並んでいることまで見る（順番が逆だと
// codex-safe が deny に飲まれて安全な形が起動できなくなる）。
test('safe launcher shims are askable and ordered after the bare-binary denies', () => {
  const bash = buildOpenCodeConfig().permission.bash;
  const keys = Object.keys(bash);

  assert.strictEqual(bash['codex-safe*'], 'ask');
  assert.strictEqual(bash['claude-safe*'], 'ask');
  for (const pattern of ['codex-safe*', 'claude-safe*']) {
    assert.ok(
      keys.indexOf(pattern) > keys.indexOf(pattern.replace('-safe', '')),
      `${pattern} が裸の deny より前にあると、最後の一致で打ち消される`,
    );
  }
});

test('deny rules are listed after allow rules so the last match wins', () => {
  const keys = Object.keys(buildOpenCodeConfig().permission.bash);
  const bash = buildOpenCodeConfig().permission.bash;
  const lastAllow = keys.reduce((acc, key, index) => (bash[key] === 'allow' ? index : acc), -1);
  const firstDeny = keys.findIndex((key) => bash[key] === 'deny');

  assert.ok(firstDeny > lastAllow, 'deny が allow より前にあると最後の一致で上書きされる');
});

// --- 回帰: 設定の追加強化 ------------------------------------------------------
test('autoupdate is disabled and built-in primary agents are turned off', () => {
  const config = buildOpenCodeConfig();

  assert.strictEqual(config.autoupdate, false);
  assert.strictEqual(config.agent.build.disable, true);
  assert.strictEqual(config.agent.plan.disable, true);
});

// --- 回帰: 環境変数での二重化 --------------------------------------------------
test('enforced permission env mirrors the config floor, including order', () => {
  const enforced = buildEnforcedPermissionEnv();
  const bash = buildOpenCodeConfig().permission.bash;

  assert.deepStrictEqual(enforced.external_directory, buildOpenCodeConfig().permission.external_directory);
  // 環境変数側と設定側で「同じパターンが同じ判定」であること（deny も ask も）。
  for (const [pattern, action] of Object.entries(enforced.bash)) {
    assert.ok(action === 'deny' || action === 'ask', `${pattern} は deny か ask のみ`);
    assert.strictEqual(bash[pattern], action, `${pattern} が設定側の判定と一致しない`);
  }
  // 環境変数側でも並び順が意味を持つ（最後に一致したルールが勝つ）。ask が deny より
  // 後ろに無いと、環境変数経由で codex-safe が deny に飲まれる。
  const envKeys = Object.keys(enforced.bash);
  const lastEnvDeny = envKeys.reduce((acc, k, i) => (enforced.bash[k] === 'deny' ? i : acc), -1);
  const firstEnvAsk = envKeys.findIndex((k) => enforced.bash[k] === 'ask');
  assert.ok(firstEnvAsk > lastEnvDeny, 'ask が deny より前にあると最後の一致で打ち消される');
  assert.ok(Object.keys(enforced.bash).length >= 8);
});

// --- 回帰: 起動時の権限自己検証 ------------------------------------------------
test('resolved config verification accepts an intact deny floor', () => {
  const config = intactConfig();
  assert.deepStrictEqual(verifyResolvedConfig(config), []);
});

test('resolved config verification rejects a floor weakened by the environment', () => {
  const config = intactConfig();
  config.permission.bash['rm *'] = 'allow';
  config.permission.external_directory = 'allow';

  const problems = verifyResolvedConfig(config);
  assert.ok(problems.some((line) => line.includes('rm *')));
  assert.ok(problems.some((line) => line.includes('作業フォルダの外')));
});

test('resolved config verification rejects an agent that overrides bash', () => {
  const config = intactConfig();
  config.agent['bouncer-helper'].permission.bash = { '*': 'ask' };

  const problems = verifyResolvedConfig(config);
  assert.ok(problems.some((line) => line.includes('bouncer-helper')));
});

test('resolved config verification rejects unreadable input', () => {
  assert.strictEqual(verifyResolvedConfig(null).length, 1);
  assert.ok(verifyResolvedConfig({}).length > 0);
});

test('CLI exposes the enforced permission env and the resolved-config check', () => {
  const script = path.join(__dirname, '..', 'opencode-config.js');
  const { execFileSync } = require('node:child_process');

  const enforced = execFileSync(process.execPath, [script, '--print-permission-env'], { encoding: 'utf8' });
  assert.deepStrictEqual(JSON.parse(enforced), buildEnforcedPermissionEnv());

  const intact = JSON.stringify(intactConfig());
  execFileSync(process.execPath, [script, '--verify-resolved'], { input: intact, encoding: 'utf8' });

  const weakened = intactConfig();
  weakened.permission.bash['rm *'] = 'allow';
  assert.throws(() => execFileSync(
    process.execPath,
    [script, '--verify-resolved'],
    { input: JSON.stringify(weakened), encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] },
  ));
});

test('resolved-config CLI accepts one intact config surrounded by first-run preparation logs', () => {
  const script = path.join(__dirname, '..', 'opencode-config.js');
  const { execFileSync } = require('node:child_process');
  const intact = JSON.stringify(intactConfig(), null, 2);
  const firstRunOutput = [
    '\u001b[2mbun install v1.2.19\u001b[0m',
    '+ @opencode-ai/plugin@1.18.4',
    '',
    intact,
    '',
    '1 package installed',
    '',
  ].join('\r\n');

  execFileSync(
    process.execPath,
    [script, '--verify-resolved'],
    { input: firstRunOutput, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] },
  );
});

test('resolved-config parser accepts JSON attached directly to a non-JSON status line', () => {
  const intact = intactConfig();
  const output = `installing dependencies...\u001b[0m${JSON.stringify(intact)}`;

  assert.deepStrictEqual(parseResolvedConfigOutput(output), intact);
});

test('resolved-config parser tolerates raw mojibake markdown fields from Windows debug config', () => {
  const intact = intactConfig({ enableWebSearch: true });
  intact.agent.sensei = {
    name: 'sensei',
    description: 'ignored',
    mode: 'primary',
    tools: { bash: false, edit: false, task: false },
    prompt: 'ignored',
    options: {},
    permission: {
      bash: 'deny',
      edit: 'deny',
      task: 'deny',
      webfetch: 'deny',
    },
  };

  const brokenCommand = [
    '  "command": {',
    '    "縺ｪ縺翫＠縺ｦ": {',
    '      "description": "繧ｨ繝ｩ繝ｼ譁・,',
    '      "template": "譁・ｭ怜喧縺励◆繝・Φ繝励Ξ,',
    '    }',
    '  },',
  ].join('\r\n');
  let output = JSON.stringify(intact, null, 2).replace('{\n', `{\r\n${brokenCommand}\r\n`);
  output = output.replace(
    '      "prompt": "ignored",',
    '      "prompt": "縺帙ｓ縺帙＞ の長い本文\r\n本文の末尾が生改行のまま出る,',
  );
  output = output.replace(
    '    "description": "ignored",',
    '    "description": "縺帙ｓ縺帙＞ の説明,',
  );

  const parsed = parseResolvedConfigOutput(output);
  assert.deepStrictEqual(verifyResolvedConfig(parsed), []);
  assert.strictEqual(parsed.permission.websearch, 'ask');
  assert.strictEqual(parsed.agent.sensei.permission.bash, 'deny');
});

test('resolved-config parser ignores structured JSON logs and selects the one config object', () => {
  const intact = intactConfig();
  const output = [
    JSON.stringify({ level: 'info', message: 'installing dependencies', detail: { count: 1 } }),
    JSON.stringify(intact),
    JSON.stringify({ level: 'info', message: 'done' }),
  ].join('\r\n');

  assert.deepStrictEqual(parseResolvedConfigOutput(output), intact);
});

test('resolved-config CLI accepts the same first-run output through a Windows UTF-8 file', (t) => {
  const script = path.join(__dirname, '..', 'opencode-config.js');
  const { execFileSync } = require('node:child_process');
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'opencode-resolved-config-'));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const resolvedFile = path.join(temp, 'resolved-config.json');
  const firstRunOutput = [
    '\u001b[2mbun install v1.2.19\u001b[0m',
    '+ @opencode-ai/plugin@1.18.4',
    '',
    JSON.stringify(intactConfig(), null, 2),
    '',
    '1 package installed',
    '',
  ].join('\r\n');
  fs.writeFileSync(resolvedFile, `\ufeff${firstRunOutput}`, 'utf8');

  execFileSync(
    process.execPath,
    [script, '--verify-resolved', resolvedFile],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
  );
});

test('resolved-config CLI rejects ambiguous output containing two config objects', () => {
  const script = path.join(__dirname, '..', 'opencode-config.js');
  const { spawnSync } = require('node:child_process');
  const intact = JSON.stringify(intactConfig());
  const result = spawnSync(
    process.execPath,
    [script, '--verify-resolved'],
    {
      input: `${intact}\n${intact}\n`,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    },
  );

  assert.notStrictEqual(result.status, 0, '設定JSONが複数ある曖昧な出力を受理してはいけない');
  assert.match(result.stderr, /JSONとして読めませんでした/);
});

test('installer-facing config output does not write credentials to OpenCode auth storage', () => {
  const config = buildOpenCodeConfig();
  const serialized = JSON.stringify(config);
  const openCodeAuth = path.join(os.homedir(), '.local', 'share', 'opencode', 'auth.json');

  assert.ok(!serialized.includes(openCodeAuth));
  assert.ok(!serialized.includes('DEEPSEEK_API_KEY'));
  assert.ok(!serialized.includes('ANTHROPIC_AUTH_TOKEN'));
});

// --- M-7: 呼び出し元認証トークンの受け渡し ------------------------------------
test('config generation is fail-closed when the gateway token is missing', () => {
  const saved = process.env.DS_GATEWAY_TOKEN;
  delete process.env.DS_GATEWAY_TOKEN;
  try {
    assert.throws(() => buildOpenCodeConfig({ port: 8788 }), /DS_GATEWAY_TOKEN/);
  } finally {
    process.env.DS_GATEWAY_TOKEN = saved;
  }

  // 明示指定は環境変数より優先される（ランチャーは env で渡す）。
  const explicit = buildOpenCodeConfig({ port: 8788, gatewayToken: 'explicit-token' });
  assert.strictEqual(explicit.provider['bouncer-deepseek'].options.apiKey, 'explicit-token');
});

test('CLI refuses to emit a config without the gateway token', () => {
  const script = path.join(__dirname, '..', 'opencode-config.js');
  const env = { ...process.env };
  delete env.DS_GATEWAY_TOKEN;
  const result = require('node:child_process').spawnSync(
    process.execPath, [script, '--port', '8788'], { encoding: 'utf8', env },
  );
  assert.notStrictEqual(result.status, 0, 'トークン無しでは設定を出力しない');
  assert.strictEqual(result.stdout.trim(), '');
  assert.match(result.stderr, /DS_GATEWAY_TOKEN/);
});

// --- 回帰: 日本語ハーネス（AGENTS.md）の届け方 --------------------------------
// 1.18.4 実測: 隔離設定ディレクトリ直下の AGENTS.md は instructions の指定と関係なく
// 無条件で読み込まれ、OPENCODE_DISABLE_PROJECT_CONFIG=1 では作業フォルダ側の探索が止まる。
// ここに作業フォルダの絶対パスを足すと、Codex 前提で書かれた workspace/AGENTS.md まで
// 同時に届いて OpenCode 用ハーネスと矛盾した指示になるので、相対 1 本のまま触らない。
test('instructions stay pointed at the harness in the isolated config directory', () => {
  const config = buildOpenCodeConfig({ mcpDir: '' });

  assert.deepStrictEqual(config.instructions, ['AGENTS.md']);
  for (const entry of config.instructions) {
    assert.ok(!path.isAbsolute(entry), `作業フォルダ側の指示書を混ぜてはいけない: ${entry}`);
  }
});

// --- 回帰: MCP（検索・画像生成・画像読取）の接続と出し分け ----------------------
function mcpFixture(t, files, { coachKey = '' } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencode-mcp-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  for (const file of files) fs.writeFileSync(path.join(dir, file), '// stub\n');
  if (coachKey) {
    fs.mkdirSync(path.join(dir, '.ai-safety'), { recursive: true });
    fs.writeFileSync(path.join(dir, '.ai-safety', 'gemini-api-key.txt'), `${coachKey}\n`);
  }
  return dir;
}

const ALL_MCP_FILES = MCP_SERVERS.map((server) => server.file);

test('all six zero-dependency MCP servers are wired with absolute node commands', (t) => {
  const dir = mcpFixture(t, ALL_MCP_FILES, { coachKey: 'coach-key' });
  const config = buildOpenCodeConfig({
    mcpDir: dir,
    env: {},
    homeDir: dir,
  });

  assert.deepStrictEqual(Object.keys(config.mcp).sort(), [
    'agy-image', 'codex-image', 'gemini-search', 'gemini-vision', 'playwright', 'pollinations-image',
  ]);
  for (const [name, entry] of Object.entries(config.mcp)) {
    assert.strictEqual(entry.type, 'local', `${name} は local 起動でなければならない`);
    assert.strictEqual(entry.command[0], 'node');
    assert.ok(path.isAbsolute(entry.command[1]), `${name} の実体は絶対パスで渡す`);
    assert.strictEqual(entry.enabled, true);
    // 既定 5000ms では画像生成（20 秒前後）も検索も間に合わない。
    assert.ok(entry.timeout > 5000, `${name} の timeout が既定のままでは間に合わない`);
  }
  assert.ok(config.mcp['agy-image'].timeout >= 180000, 'agy は 1 枚 3 分近くかかる');
  assert.ok(config.mcp['codex-image'].timeout >= 210000, 'GPT-Image-2 は agy よりさらに時間がかかる');
  // MCP ツールの permission キーは <サーバー名>_<ツール名>（1.18.4 実測）。
  assert.strictEqual(config.permission['gemini-search_web_search'], 'ask');
  assert.strictEqual(config.permission['gemini-vision_describe_image'], 'ask');
  assert.strictEqual(config.permission['pollinations-image_generate_image'], 'ask');
  assert.strictEqual(config.permission['agy-image_generate_image_agy'], 'ask');
  assert.strictEqual(config.permission['codex-image_generate_image_gpt'], 'ask');
  assert.strictEqual(config.permission['playwright_*'], 'ask');
});

test('Gemini-backed MCP servers are omitted when the coach API key is missing', (t) => {
  const dir = mcpFixture(t, ALL_MCP_FILES);
  const { mcp, permission } = buildMcpConfig({ mcpDir: dir, env: {}, homeDir: dir });

  assert.deepStrictEqual(Object.keys(mcp).sort(), ['agy-image', 'codex-image', 'playwright', 'pollinations-image']);
  assert.strictEqual(permission['gemini-search_web_search'], undefined);
  assert.strictEqual(permission['gemini-vision_describe_image'], undefined);
});

test('the coach key file is the only thing that enables the Gemini MCP servers', (t) => {
  const dir = mcpFixture(t, ALL_MCP_FILES, { coachKey: 'file-key' });

  const { mcp } = buildMcpConfig({ mcpDir: dir, env: {}, homeDir: dir });
  assert.ok(mcp['gemini-search']);
  assert.ok(mcp['gemini-vision']);

  // 空ファイルは「キーあり」とみなさない。
  fs.writeFileSync(path.join(dir, '.ai-safety', 'gemini-api-key.txt'), '   \n');
  assert.strictEqual(buildMcpConfig({ mcpDir: dir, env: {}, homeDir: dir }).mcp['gemini-search'], undefined);
});

// YELLOW-2: 環境変数の鍵は OpenCode のプロセス環境から消される（ランチャーが
// --print-secret-env の一覧で消す）ので、それを根拠に MCP を登録すると
// 「登録されているのに鍵が届かない MCP」になる。環境変数だけでは登録しない。
test('an environment-only Gemini key never registers the Gemini MCP servers', (t) => {
  const dir = mcpFixture(t, ALL_MCP_FILES);
  const env = { GEMINI_API_KEY: 'env-key', GOOGLE_API_KEY: 'env-key-2' };

  const { mcp, permission } = buildMcpConfig({ mcpDir: dir, env, homeDir: dir });
  assert.deepStrictEqual(Object.keys(mcp).sort(), ['agy-image', 'codex-image', 'playwright', 'pollinations-image']);
  assert.strictEqual(permission['gemini-search_web_search'], undefined);
  assert.strictEqual(permission['gemini-vision_describe_image'], undefined);
});

test('the secret environment list covers the keys the launchers must strip', () => {
  const { SECRET_ENV_VARS } = require('../opencode-config.js');
  for (const name of ['GEMINI_API_KEY', 'GOOGLE_API_KEY', 'DEEPSEEK_API_KEY', 'ANTHROPIC_AUTH_TOKEN']) {
    assert.ok(SECRET_ENV_VARS.includes(name), `${name} が消去対象に入っていない`);
  }
});

test('each MCP server can be switched off individually and missing files are never registered', (t) => {
  const dir = mcpFixture(t, ALL_MCP_FILES, { coachKey: 'coach-key' });
  const env = {
    AI_SAFE_DCLAUDE_SEARCH: '0',
    AI_SAFE_DCLAUDE_IMAGE: '0',
  };
  const { mcp } = buildMcpConfig({ mcpDir: dir, env, homeDir: dir });
  assert.deepStrictEqual(Object.keys(mcp).sort(), ['agy-image', 'codex-image', 'gemini-vision', 'playwright']);

  const partial = mcpFixture(t, ['gemini-search-mcp.js'], { coachKey: 'k' });
  const only = buildMcpConfig({ mcpDir: partial, env: {}, homeDir: partial });
  assert.deepStrictEqual(Object.keys(only.mcp), ['gemini-search']);
});

test('no mcp section is emitted when nothing can be connected', (t) => {
  const dir = mcpFixture(t, []);
  const config = buildOpenCodeConfig({ mcpDir: dir, env: {}, homeDir: dir });
  assert.strictEqual(config.mcp, undefined, '空の mcp を書くと OpenCode 側で無駄な起動が走る');
});

test('MCP wiring never leaks the coach API key into the generated config', (t) => {
  const dir = mcpFixture(t, ALL_MCP_FILES, { coachKey: 'must-not-appear' });
  const config = buildOpenCodeConfig({ mcpDir: dir, env: {}, homeDir: dir });
  assert.ok(config.mcp['gemini-search'], '鍵ファイルがあるので登録はされている');
  assert.ok(!JSON.stringify(config).includes('must-not-appear'));
});

// --- 回帰: read ツールから安全パッケージ本体を読めない --------------------------
// read ツールは bash を通らないので決定的 deny 床（tool.execute.before）が効かない。
// ここで禁止しないものはシェル抜きでそのまま読み出される。実機 1.18.4 で確認済み:
// 修正前は <workspace>/.ai-safety/ のファイル内容がモデルへ渡り、修正後は
// 「rule which prevents you from using this specific tool call」で拒否される。
// 作業フォルダ外の ~/.ai-safety は external_directory: deny が別途止める。
//
// 下の評価器は opencode の「最後に一致したルールが勝つ」を写したもの。パターンの
// 並び順まで含めて壊れていないことを、正規表現の字面ではなく判定結果で見る。
function lastMatchingAction(patterns, filePath) {
  const toRegExp = (glob) => {
    // 単独の '*' は「何にでも当たる」（実機で通常ファイルが読めることから確認）。
    // それ以外の '*' は 1 階層内、'**' は階層をまたぐ、という素直な glob として扱う。
    if (glob === '*') return /^.*$/;
    const escaped = glob.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    const source = escaped.split('**').map((part) => part.split('*').join('[^/]*')).join('.*');
    return new RegExp(`^${source}$`);
  };
  let action;
  for (const [pattern, value] of Object.entries(patterns)) {
    if (toRegExp(pattern).test(filePath)) action = value;
  }
  return action;
}

test('the read tool cannot reach the safety package itself', () => {
  const read = buildOpenCodeConfig().permission.read;
  const ws = '/Users/gakusei/Documents/my-ai-workspace';

  for (const target of [
    `${ws}/.ai-safety/gemini-api-key.txt`,
    `${ws}/.ai-safety/policy/safety-policy.json`,
    `${ws}/.ai-safety/hooks/common/opencode-bouncer-monitor.mjs`,
    `${ws}/.ai-safety`,
  ]) {
    assert.strictEqual(lastMatchingAction(read, target), 'deny', `${target} が読めてしまう`);
  }

  // 既存の .env 禁止と .env.example の例外を壊していないこと。
  assert.strictEqual(lastMatchingAction(read, `${ws}/.env`), 'deny');
  assert.strictEqual(lastMatchingAction(read, `${ws}/.env.example`), 'allow');
  // ふつうの作業ファイルは読めるままであること（読んで説明するのが本業なので）。
  for (const ok of [`${ws}/notes.md`, `${ws}/src/index.js`, `${ws}/safety-notes.md`]) {
    assert.strictEqual(lastMatchingAction(read, ok), 'allow', `${ok} が読めなくなっている`);
  }
});

// --- 回帰: 承認疲れ対策で広げた allow が deny 床をすり抜けない ------------------
test('read-only commands are allowed while write-capable ones stay behind a prompt', () => {
  const bash = buildOpenCodeConfig().permission.bash;

  for (const pattern of ['wc *', 'git branch', 'node -v', 'npm -v', 'python --version']) {
    assert.strictEqual(bash[pattern], 'allow', `${pattern} が allow になっていない`);
  }
  // `git show HEAD:.env` は protectedPathRegex（パス区切り前提）に当たらず床をすり抜けるので
  // allow に入れない。deny 床の正規表現を強めない限り ask のまま。
  assert.strictEqual(bash['git show*'], undefined, 'git show* は .env をコロン参照で読み出せる');
  assert.strictEqual(bash['cat*'], undefined);
  // head * / tail * は `head -n 200 .*` のようにグロブで書かれると床から読み取り先が見えない
  // （3 エンジンとも pass = tri-engine/cases.json の head-glob-dotfiles で実測）。確認ダイアログ
  // すら出ないまま .env の中身がモデルへ渡るので allow から外し、'*': 'ask' に落とす。
  // grep* / rg* を外したのと同じ理由。
  for (const pattern of ['head *', 'tail *']) {
    assert.strictEqual(bash[pattern], undefined, `${pattern} はグロブで .env を読み出せるので allow にしない`);
  }
});

// --- 回帰: 読み取り専用エージェントだけは許し、緩める上書きは弾く ----------------
// 1.18.4 は markdown エージェントの `tools: { bash: false }` を permission.bash = "deny"
// に変換する。ここを一律で弾くと読み取り専用の「せんせい」を置いた瞬間に起動不能になる。
test('an agent may hard-deny bash but may not weaken or carve holes in it', () => {
  const readOnly = intactConfig();
  readOnly.agent.sensei = { mode: 'primary', permission: { bash: 'deny', edit: 'deny' } };
  assert.deepStrictEqual(verifyResolvedConfig(readOnly), []);

  for (const weakened of ['allow', 'ask', { '*': 'allow' }, { '*': 'ask' }, { '*': 'deny', 'ls*': 'allow' }]) {
    const config = intactConfig();
    config.agent.sensei = { mode: 'primary', permission: { bash: weakened } };
    const problems = verifyResolvedConfig(config);
    assert.ok(
      problems.some((line) => line.includes('sensei')),
      `bash=${JSON.stringify(weakened)} は共通ルールの上書きとして弾かれなければならない`,
    );
  }
});
