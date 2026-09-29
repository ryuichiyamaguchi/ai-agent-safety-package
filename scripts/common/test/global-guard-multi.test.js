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

const madeHomes = [];
function mkHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safety-global-'));
  madeHomes.push(home);
  return home;
}
// 偽 HOME は最後にまとめて片付ける（テストの痕跡を残さない）。
test.after(() => { for (const h of madeHomes) fs.rmSync(h, { recursive: true, force: true }); });

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

// ---------------------------------------------------------------- 安全ガードの固定の置き場
// hook が作業フォルダの中の guard を絶対パスで指していると、作業フォルダを移動・名前変更した
// 瞬間に「AI Safety hook missing」(exit 2) で PC 中の Claude が止まる。v1.19.x からは
// guard 一式を ~/.ai-safety/global/ へ複製し（stage-global-runtime.js）、hook はそちらを指す。
const STAGE_JS = path.join(COMMON, 'stage-global-runtime.js');

// 作業フォルダ（<ws>/.ai-safety/...）と同じ並びを、配布物から組み立てる。
function mkFakeWorkspace(root, osName) {
  const ai = path.join(root, '.ai-safety');
  fs.cpSync(path.join(PKG, 'scripts', osName), path.join(ai, 'hooks', osName), { recursive: true });
  fs.cpSync(COMMON, path.join(ai, 'hooks', 'common'), { recursive: true });
  fs.mkdirSync(path.join(ai, 'policy'), { recursive: true });
  fs.copyFileSync(path.join(PKG, 'policy', 'safety-policy.json'), path.join(ai, 'policy', 'safety-policy.json'));
  fs.cpSync(path.join(PKG, 'configs', 'safety', 'cards'), path.join(ai, 'cards'), { recursive: true });
  return path.join(ai, 'hooks', osName);
}

function stage(home, guardSrc, dest, osName) {
  return run(STAGE_JS, ['--os', osName || 'macos', '--guard-src', guardSrc, '--dest', dest], home);
}

test('固定の置き場: 作業フォルダから guard 一式を複製し、ガードが相対で読むものがそろう', () => {
  const home = mkHome();
  const guardSrc = mkFakeWorkspace(path.join(home, 'ws'), 'macos');
  const dest = path.join(home, '.ai-safety', 'global');
  const r = stage(home, guardSrc, dest);
  assert.strictEqual(r.code, 0, r.out);

  for (const rel of ['hooks/macos/guard-prompt.sh', 'hooks/macos/guard-bash.sh', 'hooks/macos/guard-write.sh',
    'hooks/macos/guard-webfetch.sh', 'hooks/macos/guard-post-output.sh', 'hooks/macos/guard-observe.sh',
    'hooks/macos/lib/safety_policy.sh', 'hooks/macos/lib/explainer.sh',
    'hooks/common/command-judge.js', 'hooks/common/plutil-p.js', 'hooks/common/answer-snapshot.js',
    'hooks/common/gemini-client.js', 'policy/safety-policy.json', 'cards/index.tsv', 'README.txt', 'runtime.json']) {
    assert.ok(fs.existsSync(path.join(dest, rel)), 'ない: ' + rel);
  }
  // ガードは <hooks/macos>/../../policy を同梱ポリシーとして読む。中身が配布物と同一であること。
  assert.deepStrictEqual(fs.readFileSync(path.join(dest, 'policy', 'safety-policy.json')),
    fs.readFileSync(path.join(PKG, 'policy', 'safety-policy.json')));
  // hook は [ -x ] で存在を確かめるので実行権が要る
  assert.ok(fs.statSync(path.join(dest, 'hooks', 'macos', 'guard-bash.sh')).mode & 0o100, '実行権がない');
  // hook 専用の置き場なので、ランチャー・導入スクリプト・テスト・画像素材は持ち込まない
  for (const rel of ['hooks/macos/install.sh', 'hooks/macos/apply-global-guard.sh', 'hooks/macos/launch-claude-safe.sh',
    'hooks/macos/test', 'hooks/common/test', 'hooks/common/assets']) {
    assert.ok(!fs.existsSync(path.join(dest, rel)), '持ち込んでいる: ' + rel);
  }
  const info = JSON.parse(fs.readFileSync(path.join(dest, 'runtime.json'), 'utf8'));
  const pv = JSON.parse(fs.readFileSync(path.join(PKG, 'policy', 'safety-policy.json'), 'utf8')).packageVersion;
  assert.strictEqual(info.packageVersion, pv);
});

test('固定の置き場: 作り直しは丸ごと入れ替わり、一時フォルダ・退避フォルダを残さない', () => {
  const home = mkHome();
  const guardSrc = mkFakeWorkspace(path.join(home, 'ws'), 'macos');
  const dest = path.join(home, '.ai-safety', 'global');
  assert.strictEqual(stage(home, guardSrc, dest).code, 0);
  fs.writeFileSync(path.join(dest, 'stray.txt'), 'old');
  assert.strictEqual(stage(home, guardSrc, dest).code, 0);
  assert.ok(!fs.existsSync(path.join(dest, 'stray.txt')), '古い一式が混ざったまま');
  const leftovers = fs.readdirSync(path.dirname(dest)).filter((n) => n.startsWith('global.'));
  assert.deepStrictEqual(leftovers, [], '一時フォルダ/退避フォルダが残った: ' + leftovers.join(', '));
});

test('固定の置き場: 元が壊れていたら今ある一式を残す（無ければ失敗を返し、hook を向けさせない）', () => {
  const home = mkHome();
  const dest = path.join(home, '.ai-safety', 'global');
  const broken = path.join(home, 'broken', '.ai-safety', 'hooks', 'macos');
  fs.mkdirSync(broken, { recursive: true });
  fs.writeFileSync(path.join(broken, 'guard-bash.sh'), '#!/bin/bash\nexit 0\n');
  // 置き場がまだ無い → 使える一式が無いので 1
  const none = stage(home, broken, dest);
  assert.strictEqual(none.code, 1, none.out);
  assert.ok(!fs.existsSync(dest), '不完全な一式を置いた');
  // 完全な一式がある → 壊れた元では作り直さず、前の一式を残して 0
  const guardSrc = mkFakeWorkspace(path.join(home, 'ws'), 'macos');
  assert.strictEqual(stage(home, guardSrc, dest).code, 0);
  const before = fs.readFileSync(path.join(dest, 'hooks', 'macos', 'guard-bash.sh'));
  const kept = stage(home, broken, dest);
  assert.strictEqual(kept.code, 0, kept.out);
  assert.match(kept.out, /keeping the previous complete runtime/);
  assert.deepStrictEqual(fs.readFileSync(path.join(dest, 'hooks', 'macos', 'guard-bash.sh')), before);
});

test('固定の置き場: Windows 用の一式も作れる（ps1 と lib\\SafetyPolicy.ps1・cards）', () => {
  const home = mkHome();
  const dest = path.join(home, 'rt');
  const r = stage(home, path.join(PKG, 'scripts', 'windows'), dest, 'windows');
  assert.strictEqual(r.code, 0, r.out);
  for (const rel of ['hooks/windows/guard-bash.ps1', 'hooks/windows/guard-prompt.ps1', 'hooks/windows/lib/SafetyPolicy.ps1',
    'hooks/windows/lib/Explainer.ps1', 'hooks/common/command-judge.js', 'policy/safety-policy.json', 'cards/index.tsv']) {
    assert.ok(fs.existsSync(path.join(dest, rel)), 'ない: ' + rel);
  }
  assert.ok(!fs.existsSync(path.join(dest, 'hooks', 'windows', 'install.ps1')));
  assert.ok(!fs.existsSync(path.join(dest, 'hooks', 'windows', 'test')));
  assert.ok(!fs.existsSync(path.join(dest, 'hooks', 'macos')), '別 OS の一式を置いた');
});

// 設定ファイルに書かれた hook コマンドを、Claude Code と同じように実行する。
function fireClaudeHook(settingsPath, event, matcher, payload, home, cwd) {
  const s = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
  const group = s.hooks[event].find((g) => (matcher ? g.matcher === matcher : true));
  const h = group.hooks[0];
  const env = { ...process.env, HOME: home, AI_SAFE_LOG_DIR: path.join(home, 'logs') };
  delete env.AI_SAFE_POLICY;
  const r = spawnSync(h.command, h.args || [], { input: JSON.stringify(payload), encoding: 'utf8', env, cwd });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}

test('作業フォルダを移動・名前変更しても、全体設定の hook は危険コマンドを止め続ける', { skip: process.platform === 'win32' }, () => {
  const home = mkHome();
  const wsRoot = path.join(home, 'Documents', 'my-ai-workspace');
  const guardSrc = mkFakeWorkspace(wsRoot, 'macos');
  const dest = path.join(home, '.ai-safety', 'global');
  assert.strictEqual(stage(home, guardSrc, dest).code, 0);
  const target = path.join(home, '.claude', 'settings.json');
  const src = path.join(PKG, 'configs', 'claude', 'settings.mac.json');
  assert.strictEqual(run(CLAUDE_JS, ['apply', '--source', src, '--target', target, '--os', 'macos',
    '--guard-dir', path.join(dest, 'hooks', 'macos'), '--state', statePath(home)], home).code, 0);
  assert.ok(!fs.readFileSync(target, 'utf8').includes(wsRoot), 'hook が作業フォルダを指している');

  // 受講者が作業フォルダの名前を変えた
  fs.renameSync(wsRoot, path.join(home, 'Documents', 'renamed'));
  const proj = path.join(home, 'proj');
  fs.mkdirSync(path.join(proj, 'somedir'), { recursive: true });
  const bashInput = (command) => ({ hook_event_name: 'PreToolUse', tool_name: 'Bash', cwd: proj, tool_input: { command } });

  const danger = fireClaudeHook(target, 'PreToolUse', 'Bash|PowerShell', bashInput('rm -rf somedir'), home, proj);
  assert.strictEqual(danger.code, 2, '再帰削除が止まらなかった: ' + danger.out);
  assert.match(danger.out, /BLOCKED/);
  assert.doesNotMatch(danger.out, /hook missing/);
  assert.ok(fs.existsSync(path.join(proj, 'somedir')));

  const ok = fireClaudeHook(target, 'PreToolUse', 'Bash|PowerShell', bashInput('ls -la'), home, proj);
  assert.strictEqual(ok.code, 0, '通常のコマンドまで止まった: ' + ok.out);
  const prompt = fireClaudeHook(target, 'UserPromptSubmit', null,
    { hook_event_name: 'UserPromptSubmit', prompt: 'こんにちは', cwd: proj }, home, proj);
  assert.strictEqual(prompt.code, 0, 'プロンプトが止まった（全 Claude セッションが止まる状態）: ' + prompt.out);
});

// ---------------------------------------------------------------- 旧版からの移行（作業フォルダ → 固定の置き場）
test('移行: 作業フォルダを指していた hook は、固定の置き場を指す hook へ張り替わる（重複なし・冪等）', () => {
  const home = mkHome();
  const st = statePath(home);
  const oldDir = '/Users/me/Documents/my-ai-workspace/.ai-safety/hooks/macos';
  const newDir = path.join(home, '.ai-safety', 'global', 'hooks', 'macos');
  const src = path.join(PKG, 'configs', 'claude', 'settings.mac.json');
  const claudeTarget = path.join(home, '.claude', 'settings.json');
  const original = { env: { KEEP: '1' }, hooks: { Stop: [{ hooks: [{ type: 'command', command: '/opt/mine.sh' }] }] } };
  writeFile(claudeTarget, JSON.stringify(original, null, 2) + '\n');
  const before = fs.readFileSync(claudeTarget, 'utf8');
  const codexCfg = path.join(home, '.codex', 'config.toml');
  const codexHooks = path.join(home, '.codex', 'hooks.json');
  const agyTarget = path.join(home, '.gemini', 'settings.json');

  const applyAll = (dir) => {
    assert.strictEqual(run(CLAUDE_JS, ['apply', '--source', src, '--target', claudeTarget, '--os', 'macos',
      '--guard-dir', dir, '--state', st], home).code, 0);
    assert.strictEqual(run(CODEX_JS, ['apply', '--config-target', codexCfg, '--hooks-target', codexHooks,
      '--os', 'macos', '--guard-dir', dir, '--state', st], home).code, 0);
    assert.strictEqual(run(AGY_JS, ['apply', '--target', agyTarget, '--os', 'macos',
      '--guard-dir', dir, '--state', st], home).code, 0);
  };
  applyAll(oldDir); // 旧版の「12」が入れた状態
  const oldClaude = JSON.parse(fs.readFileSync(claudeTarget, 'utf8'));
  applyAll(newDir); // 更新（install の自動反映）
  const texts = () => [claudeTarget, codexHooks, agyTarget].map((p) => fs.readFileSync(p, 'utf8'));
  const once = texts();
  for (const t of once) {
    assert.ok(!t.includes(oldDir), '作業フォルダを指す hook が残った');
    assert.ok(t.includes(newDir), '固定の置き場を指していない');
  }
  const newClaude = JSON.parse(once[0]);
  // 張り替えただけで、hook の数は旧版と同じ（増殖しない）。受講者自身の hook も残る。
  for (const ev of Object.keys(oldClaude.hooks)) {
    assert.strictEqual(newClaude.hooks[ev].length, oldClaude.hooks[ev].length, ev + ' の hook 数が変わった');
  }
  assert.ok(JSON.stringify(newClaude.hooks.Stop).includes('/opt/mine.sh'), '受講者の hook が消えた');
  applyAll(newDir); // もう一度（次の更新）
  assert.deepStrictEqual(texts(), once, '2 回目で内容が変わった（冪等でない）');

  // 解除すると、最初に入れる前（旧版で入れる前）の状態へ戻る
  assert.strictEqual(run(CLAUDE_JS, ['uninstall', '--target', claudeTarget, '--state', st], home).code, 0);
  assert.strictEqual(fs.readFileSync(claudeTarget, 'utf8'), before);
});

test('移行 (Windows): 作業フォルダを指していた powershell.exe の hook も固定の置き場へ張り替わる', () => {
  const home = mkHome();
  const st = statePath(home);
  const src = path.join(PKG, 'configs', 'claude', 'settings.windows.json');
  const target = path.join(home, '.claude', 'settings.json');
  const oldDir = 'C:\\Users\\me\\Documents\\AI作業フォルダ\\.ai-safety\\hooks\\windows';
  const newDir = 'C:\\Users\\me\\.ai-safety\\global\\hooks\\windows';
  for (const dir of [oldDir, newDir, newDir]) {
    assert.strictEqual(run(CLAUDE_JS, ['apply', '--source', src, '--target', target, '--os', 'windows',
      '--guard-dir', dir, '--state', st], home).code, 0);
  }
  const s = JSON.parse(fs.readFileSync(target, 'utf8'));
  const text = JSON.stringify(s);
  assert.ok(!text.includes('AI作業フォルダ'), '作業フォルダを指す hook が残った');
  assert.strictEqual(s.hooks.PreToolUse.length, 3, 'PreToolUse の hook が増殖した');
  assert.strictEqual(s.hooks.UserPromptSubmit.length, 1);
  const cmd = s.hooks.PreToolUse.find((g) => g.matcher === 'Bash|PowerShell').hooks[0].args.slice(-1)[0];
  assert.ok(cmd.includes(newDir + '\\guard-bash.ps1'), cmd);
});
