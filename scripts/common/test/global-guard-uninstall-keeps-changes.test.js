'use strict';
// global-guard-uninstall-keeps-changes.test.js — 「13_PC全体の安全設定を解除」が、入れたあとで
// 書き足された設定を消さないことの検査。
//
// PC 全体の安全設定は導入・更新のたびに自動で入る（v1.19.x〜）。入れてから解除までに何か月も
// 空くことがあり、そのあいだに Claude Code / Codex / Gemini 自身や受講者が同じファイルへ
// 書き足す（Codex のフォルダ信頼 [projects."…"]・モデル選択・MCP・プラグインなど）。
// 旧実装は解除でバックアップを丸ごと書き戻す（元が無ければファイルごと消す）ため、
// それらが全部消えていた。いまは:
//   - 入れたときのまま → 従来どおりバックアップから完全に戻す（既存テストが固定）
//   - 書き足されている → このパッケージが足した分だけ取り除き、他は残す（このファイルが固定）
//   - 記録の無い古い状態ファイル → 従来どおり（バックアップから戻す）
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const COMMON = path.resolve(__dirname, '..');
const PKG = path.resolve(COMMON, '..', '..');
const CLAUDE_JS = path.join(COMMON, 'apply-global-guard.js');
const CODEX_JS = path.join(COMMON, 'apply-global-codex.js');
const AGY_JS = path.join(COMMON, 'apply-global-agy.js');
const OPENCODE_JS = path.join(COMMON, 'apply-global-opencode.js');
const SRC = path.join(PKG, 'configs', 'claude', 'settings.mac.json');
const GUARD_DIR = '/Users/me/.ai-safety/global/hooks/macos';

const madeHomes = [];
function mkHome() {
  const h = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safety-keep-'));
  madeHomes.push(h);
  return h;
}
test.after(() => { for (const h of madeHomes) fs.rmSync(h, { recursive: true, force: true }); });

function run(js, args, home) {
  const env = { ...process.env, HOME: home, USERPROFILE: home };
  const r = spawnSync(process.execPath, [js, ...args], { env, encoding: 'utf8' });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}
const st = (home) => path.join(home, '.ai-safety', 'global-guard-state.json');
function writeFile(p, text) { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, text, 'utf8'); }
const readJson = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const editJson = (p, fn) => { const o = readJson(p); fn(o); fs.writeFileSync(p, JSON.stringify(o, null, 2) + '\n'); };

// ---------------------------------------------------------------- Claude
test('Claude: 入れる前に無かったファイルでも、あとから Claude Code が書いた設定は解除で消えない', () => {
  const home = mkHome();
  const target = path.join(home, '.claude', 'settings.json');
  assert.strictEqual(run(CLAUDE_JS, ['apply', '--source', SRC, '--target', target, '--os', 'macos',
    '--guard-dir', GUARD_DIR, '--state', st(home)], home).code, 0);
  editJson(target, (o) => { o.enabledPlugins = { 'x@y': true }; o.model = 'opus'; });

  const u = run(CLAUDE_JS, ['uninstall', '--target', target, '--state', st(home)], home);
  assert.strictEqual(u.code, 0, u.out);
  assert.ok(fs.existsSync(target), 'あとから書かれた設定ごとファイルを消した');
  assert.deepStrictEqual(readJson(target), { enabledPlugins: { 'x@y': true }, model: 'opus' });
});

test('Claude: 受講者の deny・hook・env は残し、このパッケージが足した deny と hook だけ取り除く', () => {
  const home = mkHome();
  const target = path.join(home, '.claude', 'settings.json');
  const original = {
    env: { KEEP: '1' },
    permissions: { allow: ['Bash(ls:*)'], deny: ['Bash(shutdown:*)', 'Read(**/.env)'] },
    hooks: { Stop: [{ hooks: [{ type: 'command', command: '/opt/mine.sh' }] }] },
  };
  writeFile(target, JSON.stringify(original, null, 2) + '\n');
  assert.strictEqual(run(CLAUDE_JS, ['apply', '--source', SRC, '--target', target, '--os', 'macos',
    '--guard-dir', GUARD_DIR, '--state', st(home)], home).code, 0);
  editJson(target, (o) => { o.statusLine = { type: 'command', command: '/opt/status.sh' }; });

  assert.strictEqual(run(CLAUDE_JS, ['uninstall', '--target', target, '--state', st(home)], home).code, 0);
  const after = readJson(target);
  assert.deepStrictEqual(after.statusLine, { type: 'command', command: '/opt/status.sh' }, 'あとからの変更が消えた');
  assert.deepStrictEqual(after.env, original.env);
  assert.deepStrictEqual(after.permissions, original.permissions, 'deny が元に戻っていない');
  assert.deepStrictEqual(after.hooks, original.hooks, 'hook が元に戻っていない');
});

test('Claude: 更新で増えた deny も、解除で取り除ける（足した分を積み上げて記録する）', () => {
  const home = mkHome();
  const target = path.join(home, '.claude', 'settings.json');
  writeFile(target, JSON.stringify({ model: 'opus' }, null, 2) + '\n');
  // 旧版の配布物（deny 1 本少ない）で入れたあと、新しい版で入れ直した
  const oldSrc = path.join(home, 'old-settings.json');
  const pkg = readJson(SRC);
  writeFile(oldSrc, JSON.stringify({ permissions: { deny: pkg.permissions.deny.slice(1) } }));
  assert.strictEqual(run(CLAUDE_JS, ['apply', '--source', oldSrc, '--target', target, '--os', 'macos',
    '--guard-dir', GUARD_DIR, '--state', st(home)], home).code, 0);
  assert.strictEqual(run(CLAUDE_JS, ['apply', '--source', SRC, '--target', target, '--os', 'macos',
    '--guard-dir', GUARD_DIR, '--state', st(home)], home).code, 0);
  editJson(target, (o) => { o.theme = 'dark'; });
  assert.strictEqual(run(CLAUDE_JS, ['uninstall', '--target', target, '--state', st(home)], home).code, 0);
  assert.deepStrictEqual(readJson(target), { model: 'opus', theme: 'dark' }, '新しい版の deny が残った');
});

test('Claude: 記録の無い古い状態ファイルは、従来どおりバックアップから戻す', () => {
  const home = mkHome();
  const target = path.join(home, '.claude', 'settings.json');
  writeFile(target, JSON.stringify({ model: 'sonnet' }, null, 2) + '\n');
  const before = fs.readFileSync(target, 'utf8');
  assert.strictEqual(run(CLAUDE_JS, ['apply', '--source', SRC, '--target', target, '--os', 'macos',
    '--guard-dir', GUARD_DIR, '--state', st(home)], home).code, 0);
  editJson(st(home), (o) => { delete o.claude.writtenSha256; });
  editJson(target, (o) => { o.theme = 'dark'; });
  assert.strictEqual(run(CLAUDE_JS, ['uninstall', '--target', target, '--state', st(home)], home).code, 0);
  assert.strictEqual(fs.readFileSync(target, 'utf8'), before);
});

// ---------------------------------------------------------------- Codex
const MANAGED_LINE = /^(approval_policy|approvals_reviewer|sandbox_mode|hooks|network_access|exclude_tmpdir_env_var|exclude_slash_tmp|inherit|exclude) =/m;

test('Codex: 入れる前に無かった config.toml でも、あとから Codex が書いたフォルダ信頼・モデルは残る', () => {
  const home = mkHome();
  const cfg = path.join(home, '.codex', 'config.toml');
  const hooks = path.join(home, '.codex', 'hooks.json');
  assert.strictEqual(run(CODEX_JS, ['apply', '--config-target', cfg, '--hooks-target', hooks,
    '--os', 'macos', '--guard-dir', GUARD_DIR, '--state', st(home)], home).code, 0);
  // Codex CLI / デスクトップアプリが書き足す形
  fs.writeFileSync(cfg, 'model = "gpt-5.5"\n' + fs.readFileSync(cfg, 'utf8') +
    '\n[projects."/Users/me/proj"]\ntrust_level = "trusted"\n');

  const u = run(CODEX_JS, ['uninstall', '--config-target', cfg, '--hooks-target', hooks, '--state', st(home)], home);
  assert.strictEqual(u.code, 0, u.out);
  const after = fs.readFileSync(cfg, 'utf8');
  assert.strictEqual(after, 'model = "gpt-5.5"\n\n[projects."/Users/me/proj"]\ntrust_level = "trusted"\n');
  assert.doesNotMatch(after, MANAGED_LINE);
  assert.ok(!fs.existsSync(hooks), '入れたときのままの hooks.json は従来どおり消える');
});

test('Codex: 入れる前の値（approval_policy など）へ戻し、自前で作った見出しだけ消す', () => {
  const home = mkHome();
  const cfg = path.join(home, '.codex', 'config.toml');
  const hooks = path.join(home, '.codex', 'hooks.json');
  const original = [
    '# my settings',
    'approval_policy = "never"',
    'model = "gpt-5.5"',
    '',
    '[features]',
    'web_search = true',
    '',
    '[shell_environment_policy]',
    'inherit = "core"',
    '',
    '[tui]',
    'theme = "dark"',
    '',
  ].join('\n');
  writeFile(cfg, original);
  assert.strictEqual(run(CODEX_JS, ['apply', '--config-target', cfg, '--hooks-target', hooks,
    '--os', 'macos', '--guard-dir', GUARD_DIR, '--state', st(home)], home).code, 0);
  fs.appendFileSync(cfg, '\n[projects."/Users/me/proj"]\ntrust_level = "trusted"\n');

  assert.strictEqual(run(CODEX_JS, ['uninstall', '--config-target', cfg, '--hooks-target', hooks,
    '--state', st(home)], home).code, 0);
  const after = fs.readFileSync(cfg, 'utf8');
  for (const line of ['# my settings', 'approval_policy = "never"', 'model = "gpt-5.5"', '[features]',
    'web_search = true', '[shell_environment_policy]', 'inherit = "core"', '[tui]', 'theme = "dark"',
    '[projects."/Users/me/proj"]', 'trust_level = "trusted"']) {
    assert.ok(after.split('\n').includes(line), '残っていない: ' + line + '\n' + after);
  }
  for (const gone of ['approvals_reviewer', 'sandbox_mode', 'hooks = true', '[sandbox_workspace_write]',
    'network_access', 'OPENAI_API_KEY', 'exclude =']) {
    assert.ok(!after.includes(gone), '取り除かれていない: ' + gone + '\n' + after);
  }
});

test('Codex: hooks.json は受講者の hook を残し、このパッケージの hook だけ取り除く', () => {
  const home = mkHome();
  const cfg = path.join(home, '.codex', 'config.toml');
  const hooks = path.join(home, '.codex', 'hooks.json');
  assert.strictEqual(run(CODEX_JS, ['apply', '--config-target', cfg, '--hooks-target', hooks,
    '--os', 'macos', '--guard-dir', GUARD_DIR, '--state', st(home)], home).code, 0);
  editJson(hooks, (o) => { o.hooks.Stop = [{ hooks: [{ type: 'command', command: '/opt/notify.sh' }] }]; });
  assert.strictEqual(run(CODEX_JS, ['uninstall', '--config-target', cfg, '--hooks-target', hooks,
    '--state', st(home)], home).code, 0);
  assert.deepStrictEqual(readJson(hooks), { hooks: { Stop: [{ hooks: [{ type: 'command', command: '/opt/notify.sh' }] }] } });
});

// ---------------------------------------------------------------- agy / OpenCode
test('agy: あとから書かれた認証方式などは残し、足した hook と hooksConfig だけ戻す', () => {
  const home = mkHome();
  const target = path.join(home, '.gemini', 'settings.json');
  writeFile(target, JSON.stringify({ theme: 'GitHub' }, null, 2) + '\n');
  assert.strictEqual(run(AGY_JS, ['apply', '--target', target, '--os', 'macos', '--guard-dir', GUARD_DIR,
    '--state', st(home)], home).code, 0);
  editJson(target, (o) => { o.selectedAuthType = 'oauth-personal'; });
  assert.strictEqual(run(AGY_JS, ['uninstall', '--target', target, '--state', st(home)], home).code, 0);
  assert.deepStrictEqual(readJson(target), { theme: 'GitHub', selectedAuthType: 'oauth-personal' });
});

test('OpenCode: あとから書かれたモデル設定は残し、permission.bash は入れる前の値へ戻す', () => {
  const home = mkHome();
  const dir = path.join(home, '.config', 'opencode');
  const target = path.join(dir, 'opencode.json');
  writeFile(target, JSON.stringify({ permission: { bash: { 'rm *': 'ask', 'ls *': 'allow' } } }, null, 2) + '\n');
  assert.strictEqual(run(OPENCODE_JS, ['apply', '--config-dir', dir, '--state', st(home)], home).code, 0);
  editJson(target, (o) => { o.model = 'deepseek/deepseek-v4-flash'; });
  assert.strictEqual(run(OPENCODE_JS, ['uninstall', '--config-dir', dir, '--state', st(home)], home).code, 0);
  const after = readJson(target);
  assert.strictEqual(after.model, 'deepseek/deepseek-v4-flash');
  assert.deepStrictEqual(after.permission, { bash: { 'rm *': 'ask', 'ls *': 'allow' } });
});

// ---------------------------------------------------------------- 実走（mac の install → 13）
test('実走: 導入 → Codex がフォルダを信頼 → 13 で解除しても、その信頼の記録は消えない', { skip: process.platform === 'win32' }, () => {
  const home = mkHome();
  const ws = path.join(home, 'Documents', 'my-ai-workspace');
  const env = { ...process.env, HOME: home };
  for (const k of ['XDG_CONFIG_HOME', 'AI_SAFE_NO_GLOBAL_GUARD', 'AI_SAFE_GLOBAL_STATE', 'AI_SAFE_GLOBAL_CODEX']) delete env[k];
  // HOME は呼び出しの場所でも明示する（oc-safe.test.js の「HOME 隔離」検査が呼び出し直後を見るため）。
  const i = spawnSync('bash', [path.join(PKG, 'scripts', 'macos', 'install.sh'), '--platform', 'mac', ws],
    { env: { ...env, HOME: home }, encoding: 'utf8', input: '' });
  assert.strictEqual(i.status, 0, (i.stdout || '') + (i.stderr || ''));
  const cfg = path.join(home, '.codex', 'config.toml');
  fs.appendFileSync(cfg, '\n[projects."' + ws + '"]\ntrust_level = "trusted"\n');
  const u = spawnSync('/bin/bash', [path.join(ws, '.ai-safety', 'hooks', 'macos', 'uninstall-global-guard.sh')],
    { env, encoding: 'utf8', input: '' });
  assert.strictEqual(u.status, 0, (u.stdout || '') + (u.stderr || ''));
  const after = fs.readFileSync(cfg, 'utf8');
  assert.strictEqual(after, '[projects."' + ws + '"]\ntrust_level = "trusted"\n');
  assert.ok(!fs.existsSync(path.join(home, '.claude', 'settings.json')), '変更の無い Claude 設定は従来どおり消える');
});
