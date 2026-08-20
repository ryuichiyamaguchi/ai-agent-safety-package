'use strict';
// global-guard-multi.test.js — 「この PC 全体に最低限の安全設定を入れる」(上級5) が
// 4 エンジン（Claude Code / Codex / agy(Gemini) / OpenCode）へ入れる設定の検査。
//
// ここで守りたい不変条件は 1 つだけ:
//   **受講者が既に持っている設定を 1 つも壊さない。**
// グローバル設定は「もともと動いていた環境」そのものなので、壊すと安全パッケージが
// 原因で仕事が止まる。だから各エンジンについて
//   (a) 安全設定がちゃんと入る
//   (b) 無関係な既存キー / セクションが 1 つも消えない・変わらない
//   (c) 解除すると元のバイト列へ戻る
//   (d) 壊れた設定ファイルには触らない（スキップ = exit 3）
// を実測する。偽の HOME（一時フォルダ）だけを触るので、実機の設定には影響しない。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const COMMON = path.resolve(__dirname, '..');
const PKG = path.resolve(COMMON, '..', '..');
const AGY_JS = path.join(COMMON, 'apply-global-agy.js');
const OPENCODE_JS = path.join(COMMON, 'apply-global-opencode.js');
const CODEX_JS = path.join(COMMON, 'apply-global-codex.js');
const CLAUDE_JS = path.join(COMMON, 'apply-global-guard.js');

function mkHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safety-global-'));
  return home;
}

// 偽 HOME でスクリプトを走らせる。state / backups も偽 HOME の中に閉じ込める。
function run(js, args, home) {
  const env = { ...process.env, HOME: home, USERPROFILE: home };
  const r = spawnSync(process.execPath, [js, ...args], { env, encoding: 'utf8' });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}

function statePath(home) { return path.join(home, '.ai-safety', 'global-guard-state.json'); }

function writeFile(p, text) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, text, 'utf8');
}

// ---------------------------------------------------------------- agy / Gemini
test('agy: 既存の ~/.gemini/settings.json の他のキーを壊さず hooks だけ足す', () => {
  const home = mkHome();
  const target = path.join(home, '.gemini', 'settings.json');
  const original = {
    theme: 'GitHub',
    selectedAuthType: 'oauth-personal',
    mcpServers: { myTool: { command: 'node', args: ['/opt/my-tool.js'] } },
    hooks: { BeforeAgent: [{ command: '/usr/local/bin/my-own-hook.sh' }] },
    contextFileName: 'AGENTS.md',
  };
  writeFile(target, JSON.stringify(original, null, 2) + '\n');
  const before = fs.readFileSync(target, 'utf8');

  const r = run(AGY_JS, ['apply', '--target', target, '--os', 'macos',
    '--guard-dir', '/ws/.ai-safety/hooks/macos', '--state', statePath(home)], home);
  assert.strictEqual(r.code, 0, r.out);

  const after = JSON.parse(fs.readFileSync(target, 'utf8'));
  // (b) 無関係な既存キーが 1 つも変わらない
  assert.strictEqual(after.theme, 'GitHub');
  assert.strictEqual(after.selectedAuthType, 'oauth-personal');
  assert.strictEqual(after.contextFileName, 'AGENTS.md');
  assert.deepStrictEqual(after.mcpServers, original.mcpServers);
  // 受講者自身の hook も残っている
  const beforeAgentCmds = after.hooks.BeforeAgent.map((h) => h.command);
  assert.ok(beforeAgentCmds.some((c) => c.includes('my-own-hook.sh')), '既存 hook が消えた');
  // (a) 安全設定が入る（絶対パスで）
  assert.strictEqual(after.hooksConfig.enabled, true);
  assert.ok(beforeAgentCmds.some((c) => c.includes('/ws/.ai-safety/hooks/macos/guard-prompt.sh')));
  const toolCmds = after.hooks.BeforeTool.map((h) => `${h.toolName}:${h.command}`);
  assert.ok(toolCmds.some((c) => c.startsWith('run_shell_command:') && c.includes('guard-bash.sh')));
  assert.ok(toolCmds.some((c) => c.startsWith('write_file:') && c.includes('guard-write.sh')));
  assert.ok(toolCmds.some((c) => c.startsWith('web_fetch:') && c.includes('guard-webfetch.sh')));
  assert.ok(after.hooks.AfterModel.some((h) => h.command.includes('guard-post-output.sh')));

  // (c) 解除で元のバイト列に戻る
  const u = run(AGY_JS, ['uninstall', '--target', target, '--state', statePath(home)], home);
  assert.strictEqual(u.code, 0, u.out);
  assert.strictEqual(fs.readFileSync(target, 'utf8'), before, '解除で元に戻っていない');
});

test('agy: 二重適用しても guard hook が増殖しない', () => {
  const home = mkHome();
  const target = path.join(home, '.gemini', 'settings.json');
  writeFile(target, JSON.stringify({ theme: 'Default' }, null, 2) + '\n');
  const args = ['apply', '--target', target, '--os', 'macos',
    '--guard-dir', '/ws/.ai-safety/hooks/macos', '--state', statePath(home)];
  assert.strictEqual(run(AGY_JS, args, home).code, 0);
  const once = JSON.parse(fs.readFileSync(target, 'utf8'));
  assert.strictEqual(run(AGY_JS, args, home).code, 0);
  const twice = JSON.parse(fs.readFileSync(target, 'utf8'));
  assert.deepStrictEqual(twice.hooks, once.hooks, '2 回目で hook が重複した');
});

test('agy: 適用前に存在しなかったときは解除でファイルごと消える', () => {
  const home = mkHome();
  const target = path.join(home, '.gemini', 'settings.json');
  assert.strictEqual(run(AGY_JS, ['apply', '--target', target, '--os', 'macos',
    '--guard-dir', '/ws/g', '--state', statePath(home)], home).code, 0);
  assert.ok(fs.existsSync(target));
  assert.strictEqual(run(AGY_JS, ['uninstall', '--target', target, '--state', statePath(home)], home).code, 0);
  assert.ok(!fs.existsSync(target), '適用前に無かったファイルが残っている');
});

test('agy: 壊れた JSON には触らずスキップする (exit 3)', () => {
  const home = mkHome();
  const target = path.join(home, '.gemini', 'settings.json');
  const broken = '{ "theme": "GitHub",,, }';
  writeFile(target, broken);
  const r = run(AGY_JS, ['apply', '--target', target, '--os', 'macos',
    '--guard-dir', '/ws/g', '--state', statePath(home)], home);
  assert.strictEqual(r.code, 3, r.out);
  assert.strictEqual(fs.readFileSync(target, 'utf8'), broken, '壊れたファイルを書き換えた');
});

test('agy: Windows では powershell.exe 経由の絶対パスになる', () => {
  const home = mkHome();
  const target = path.join(home, '.gemini', 'settings.json');
  assert.strictEqual(run(AGY_JS, ['apply', '--target', target, '--os', 'windows',
    '--guard-dir', 'C:\\ws\\.ai-safety\\hooks\\windows', '--state', statePath(home)], home).code, 0);
  const after = JSON.parse(fs.readFileSync(target, 'utf8'));
  const cmd = after.hooks.BeforeAgent[0].command;
  assert.ok(cmd.startsWith('powershell.exe -NoProfile -ExecutionPolicy Bypass -File '), cmd);
  assert.ok(cmd.includes('C:\\ws\\.ai-safety\\hooks\\windows\\guard-prompt.ps1'), cmd);
});

// ---------------------------------------------------------------- OpenCode
test('OpenCode: 既存 opencode.json の他のキーを壊さず permission.bash だけ足す', () => {
  const home = mkHome();
  const dir = path.join(home, '.config', 'opencode');
  const target = path.join(dir, 'opencode.json');
  const original = {
    $schema: 'https://opencode.ai/config.json',
    model: 'anthropic/claude-sonnet-4',
    theme: 'tokyonight',
    mcp: { myServer: { type: 'local', command: ['node', 'x.js'] } },
    permission: {
      edit: 'ask',
      bash: { 'ls *': 'allow', 'my-tool *': 'allow' },
    },
  };
  writeFile(target, JSON.stringify(original, null, 2) + '\n');
  const before = fs.readFileSync(target, 'utf8');

  const r = run(OPENCODE_JS, ['apply', '--config-dir', dir, '--state', statePath(home)], home);
  assert.strictEqual(r.code, 0, r.out);

  const after = JSON.parse(fs.readFileSync(target, 'utf8'));
  // (b) 無関係な既存キーが 1 つも変わらない
  assert.strictEqual(after.$schema, original.$schema);
  assert.strictEqual(after.model, original.model);
  assert.strictEqual(after.theme, original.theme);
  assert.deepStrictEqual(after.mcp, original.mcp);
  assert.strictEqual(after.permission.edit, 'ask');
  // 受講者自身の bash ルールも残る
  assert.strictEqual(after.permission.bash['ls *'], 'allow');
  assert.strictEqual(after.permission.bash['my-tool *'], 'allow');
  // (a) 最小 deny / ask が入る
  const { buildEnforcedPermissionEnv } = require('../opencode-config.js');
  const enforced = buildEnforcedPermissionEnv().bash;
  for (const [k, v] of Object.entries(enforced)) {
    assert.strictEqual(after.permission.bash[k], v, `${k} が ${v} になっていない`);
  }
  // 並び順: deny(codex*) より ask(codex-safe*) が後ろ（最後に一致したルールが勝つため）
  const keys = Object.keys(after.permission.bash);
  assert.ok(keys.indexOf('codex-safe*') > keys.indexOf('codex*'), 'codex-safe* が codex* より前にある');
  assert.ok(keys.indexOf('claude-safe*') > keys.indexOf('claude*'), 'claude-safe* が claude* より前にある');
  // 既存キーは本パッケージ分より前（本パッケージ側が必ず勝つ）
  assert.ok(keys.indexOf('ls *') < keys.indexOf('rm *'));

  // (c) 解除で元のバイト列に戻る
  const u = run(OPENCODE_JS, ['uninstall', '--config-dir', dir, '--state', statePath(home)], home);
  assert.strictEqual(u.code, 0, u.out);
  assert.strictEqual(fs.readFileSync(target, 'utf8'), before, '解除で元に戻っていない');
});

test('OpenCode: 既存が opencode.jsonc ならそちらに追従する', () => {
  const home = mkHome();
  const dir = path.join(home, '.config', 'opencode');
  const jsonc = path.join(dir, 'opencode.jsonc');
  writeFile(jsonc, JSON.stringify({ model: 'x/y' }, null, 2) + '\n');
  const r = run(OPENCODE_JS, ['apply', '--config-dir', dir, '--state', statePath(home)], home);
  assert.strictEqual(r.code, 0, r.out);
  assert.ok(!fs.existsSync(path.join(dir, 'opencode.json')), 'opencode.json を新規に作ってしまった');
  const after = JSON.parse(fs.readFileSync(jsonc, 'utf8'));
  assert.strictEqual(after.model, 'x/y');
  assert.strictEqual(after.permission.bash['sudo *'], 'deny');
});

test('OpenCode: コメント付き .jsonc には触らずスキップする (exit 3)', () => {
  const home = mkHome();
  const dir = path.join(home, '.config', 'opencode');
  const jsonc = path.join(dir, 'opencode.jsonc');
  const body = '{\n  // 自分用のメモ\n  "model": "x/y"\n}\n';
  writeFile(jsonc, body);
  const r = run(OPENCODE_JS, ['apply', '--config-dir', dir, '--state', statePath(home)], home);
  assert.strictEqual(r.code, 3, r.out);
  assert.strictEqual(fs.readFileSync(jsonc, 'utf8'), body, 'コメント付き設定を書き換えた');
});

test('OpenCode: permission.bash が文字列でも壊さず表に直す', () => {
  const home = mkHome();
  const dir = path.join(home, '.config', 'opencode');
  const target = path.join(dir, 'opencode.json');
  writeFile(target, JSON.stringify({ permission: { bash: 'allow' } }, null, 2) + '\n');
  assert.strictEqual(run(OPENCODE_JS, ['apply', '--config-dir', dir, '--state', statePath(home)], home).code, 0);
  const after = JSON.parse(fs.readFileSync(target, 'utf8'));
  assert.strictEqual(after.permission.bash['*'], 'allow');
  assert.strictEqual(after.permission.bash['rm *'], 'deny');
  const keys = Object.keys(after.permission.bash);
  assert.ok(keys.indexOf('*') < keys.indexOf('rm *'), '包括 allow が deny より後ろにある（deny が無効化される）');
});

// ---------------------------------------------------------------- Codex (TOML)
test('Codex: 既存 config.toml の profiles / mcp_servers を 1 行も壊さない', () => {
  const home = mkHome();
  const cfg = path.join(home, '.codex', 'config.toml');
  const hooks = path.join(home, '.codex', 'hooks.json');
  const original = [
    '# 自分用の設定',
    'model = "gpt-5.5"',
    'model_reasoning_effort = "high"',
    '',
    '[profiles.work]',
    'model = "gpt-5.5-codex"',
    'approval_policy = "never"',
    '',
    '[mcp_servers.playwright]',
    'command = "npx"',
    'args = ["-y", "@playwright/mcp@latest"]',
    '',
    '[tui]',
    'theme = "dark"',
    '',
  ].join('\n');
  writeFile(cfg, original);
  const before = fs.readFileSync(cfg, 'utf8');

  const r = run(CODEX_JS, ['apply', '--config-target', cfg, '--hooks-target', hooks,
    '--os', 'macos', '--guard-dir', '/ws/g', '--state', statePath(home)], home);
  assert.strictEqual(r.code, 0, r.out);

  const after = fs.readFileSync(cfg, 'utf8');
  // (b) 管理キー以外の行が 1 行も消えていない
  for (const line of ['model = "gpt-5.5"', 'model_reasoning_effort = "high"',
    '[profiles.work]', 'model = "gpt-5.5-codex"', 'approval_policy = "never"',
    '[mcp_servers.playwright]', 'command = "npx"',
    'args = ["-y", "@playwright/mcp@latest"]', '[tui]', 'theme = "dark"']) {
    assert.ok(after.includes(line), `既存の行が消えた: ${line}`);
  }
  // (a) 安全設定が入る。依頼者裁定どおり通信は開けたまま（network_access = true）。
  assert.match(after, /^sandbox_mode = "workspace-write"$/m);
  assert.match(after, /^approval_policy = "on-request"$/m);
  assert.match(after, /network_access = true/);
  assert.match(after, /OPENAI_API_KEY/);
  // profiles.work の approval_policy = "never" はプロファイル内なので書き換わっていない
  assert.ok(after.includes('[profiles.work]'));
  const workSection = after.slice(after.indexOf('[profiles.work]'));
  assert.match(workSection.split(/\n\[/)[0], /approval_policy = "never"/);

  // (c) 解除で元のバイト列に戻る
  const u = run(CODEX_JS, ['uninstall', '--config-target', cfg, '--hooks-target', hooks,
    '--state', statePath(home)], home);
  assert.strictEqual(u.code, 0, u.out);
  assert.strictEqual(fs.readFileSync(cfg, 'utf8'), before, '解除で元に戻っていない');
});

// ---------------------------------------------------------------- Claude Code
test('Claude: 既存 ~/.claude/settings.json の env / allow を壊さず deny と hooks を足す', () => {
  const home = mkHome();
  const target = path.join(home, '.claude', 'settings.json');
  const original = {
    env: { MY_VAR: 'keep-me' },
    model: 'opus',
    statusLine: { type: 'command', command: '/opt/my-statusline.sh' },
    permissions: { allow: ['Bash(ls:*)'], deny: ['Bash(shutdown:*)'] },
  };
  writeFile(target, JSON.stringify(original, null, 2) + '\n');
  const before = fs.readFileSync(target, 'utf8');

  const src = path.join(PKG, 'configs', 'claude', 'settings.mac.json');
  const r = run(CLAUDE_JS, ['apply', '--source', src, '--target', target, '--os', 'macos',
    '--guard-dir', '/ws/.ai-safety/hooks/macos', '--state', statePath(home)], home);
  assert.strictEqual(r.code, 0, r.out);

  const after = JSON.parse(fs.readFileSync(target, 'utf8'));
  assert.deepStrictEqual(after.env, original.env);
  assert.strictEqual(after.model, 'opus');
  assert.deepStrictEqual(after.statusLine, original.statusLine);
  assert.deepStrictEqual(after.permissions.allow, original.permissions.allow);
  // 既存 deny は先頭に残り、パッケージ分が後ろに union される
  assert.strictEqual(after.permissions.deny[0], 'Bash(shutdown:*)');
  assert.ok(after.permissions.deny.length > 1, 'deny が追加されていない');
  assert.ok(JSON.stringify(after.hooks).includes('/ws/.ai-safety/hooks/macos/guard-bash.sh'));

  const u = run(CLAUDE_JS, ['uninstall', '--target', target, '--state', statePath(home)], home);
  assert.strictEqual(u.code, 0, u.out);
  assert.strictEqual(fs.readFileSync(target, 'utf8'), before, '解除で元に戻っていない');
});

// ---------------------------------------------------------------- 4 エンジン同時
test('4 エンジンを 1 回で入れて 1 回で戻せる（記録は入れた分だけ）', () => {
  const home = mkHome();
  const st = statePath(home);
  const claudeTarget = path.join(home, '.claude', 'settings.json');
  const codexCfg = path.join(home, '.codex', 'config.toml');
  const codexHooks = path.join(home, '.codex', 'hooks.json');
  const agyTarget = path.join(home, '.gemini', 'settings.json');
  const ocDir = path.join(home, '.config', 'opencode');
  const src = path.join(PKG, 'configs', 'claude', 'settings.mac.json');

  assert.strictEqual(run(CLAUDE_JS, ['apply', '--source', src, '--target', claudeTarget,
    '--os', 'macos', '--guard-dir', '/ws/g', '--state', st], home).code, 0);
  assert.strictEqual(run(CODEX_JS, ['apply', '--config-target', codexCfg, '--hooks-target', codexHooks,
    '--os', 'macos', '--guard-dir', '/ws/g', '--state', st], home).code, 0);
  assert.strictEqual(run(AGY_JS, ['apply', '--target', agyTarget, '--os', 'macos',
    '--guard-dir', '/ws/g', '--state', st], home).code, 0);
  assert.strictEqual(run(OPENCODE_JS, ['apply', '--config-dir', ocDir, '--state', st], home).code, 0);

  const state = JSON.parse(fs.readFileSync(st, 'utf8'));
  assert.deepStrictEqual(Object.keys(state).sort(),
    ['agy', 'claude', 'codexConfig', 'codexHooks', 'opencode']);

  assert.strictEqual(run(CLAUDE_JS, ['uninstall', '--target', claudeTarget, '--state', st], home).code, 0);
  assert.strictEqual(run(CODEX_JS, ['uninstall', '--config-target', codexCfg,
    '--hooks-target', codexHooks, '--state', st], home).code, 0);
  assert.strictEqual(run(AGY_JS, ['uninstall', '--target', agyTarget, '--state', st], home).code, 0);
  assert.strictEqual(run(OPENCODE_JS, ['uninstall', '--config-dir', ocDir, '--state', st], home).code, 0);

  // すべて「適用前は存在しなかった」ので、解除でファイルごと消える
  for (const p of [claudeTarget, codexCfg, codexHooks, agyTarget,
    path.join(ocDir, 'opencode.json')]) {
    assert.ok(!fs.existsSync(p), `解除後も残っている: ${p}`);
  }
  assert.deepStrictEqual(JSON.parse(fs.readFileSync(st, 'utf8')), {});
});
