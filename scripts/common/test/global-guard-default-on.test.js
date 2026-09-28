'use strict';
// global-guard-default-on.test.js — 「PC 全体の安全設定」を導入・更新のたびに自動で入れる（既定でオン）
// ことの実走テスト（mac の install.sh を偽 HOME に対して本当に走らせる）。
//
// 固定したいこと:
//   (1) 導入すると、何も押さなくても 4 エンジンの全体設定が入り、hook は作業フォルダではなく
//       ~/.ai-safety/global/ の guard を指す
//   (2) 作業フォルダを移動・名前変更しても、全体設定の hook は危険コマンドを止め続ける
//       （以前は「AI Safety hook missing」で PC 中の Claude が止まっていた）
//   (3) 「キーと金庫/13」で解除すると記録が残り、次の導入・更新では入れ直さない
//   (4) 「キーと金庫/12」を押すと記録が消え、また入る
//   (5) AI_SAFE_NO_GLOBAL_GUARD=1 なら入れない
//   (6) 旧版で入れた「作業フォルダを指す hook」は更新で張り替わり、二重にならず、解除で元に戻る
//
// install は HOME 配下（~/.ai-safety・~/.zshrc・~/.claude など）を書き換える。必ず偽 HOME で動かす。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PKG = path.resolve(__dirname, '..', '..', '..');
const INSTALL_SH = path.join(PKG, 'scripts', 'macos', 'install.sh');
const skip = process.platform === 'win32';

const madeHomes = [];
function mkHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safety-default-on-'));
  madeHomes.push(home);
  return home;
}
test.after(() => { for (const h of madeHomes) fs.rmSync(h, { recursive: true, force: true }); });

function baseEnv(home, extra) {
  const env = { ...process.env, HOME: home, ...(extra || {}) };
  // 実機の設定場所へ漏れないように、全体設定の置き場を変える変数は持ち込まない。
  for (const k of ['XDG_CONFIG_HOME', 'AI_SAFE_GLOBAL_CLAUDE', 'AI_SAFE_GLOBAL_CODEX', 'AI_SAFE_GLOBAL_CODEX_HOOKS',
    'AI_SAFE_GLOBAL_AGY', 'AI_SAFE_GLOBAL_OPENCODE_DIR', 'AI_SAFE_GLOBAL_STATE', 'AI_SAFE_DENY_SRC', 'AI_SAFE_POLICY']) {
    if (!(extra && k in extra)) delete env[k];
  }
  if (!(extra && 'AI_SAFE_NO_GLOBAL_GUARD' in extra)) delete env.AI_SAFE_NO_GLOBAL_GUARD;
  return env;
}

function install(home, ws, extra) {
  const r = spawnSync('bash', [INSTALL_SH, '--platform', 'mac', ws],
    { env: baseEnv(home, extra), encoding: 'utf8', input: '' });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}

function runScript(home, script, extra) {
  const r = spawnSync('/bin/bash', [script], { env: baseEnv(home, extra), encoding: 'utf8', input: '' });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}

const P = (home) => ({
  claude: path.join(home, '.claude', 'settings.json'),
  codexCfg: path.join(home, '.codex', 'config.toml'),
  codexHooks: path.join(home, '.codex', 'hooks.json'),
  agy: path.join(home, '.gemini', 'settings.json'),
  opencode: path.join(home, '.config', 'opencode', 'opencode.json'),
  runtime: path.join(home, '.ai-safety', 'global'),
  optout: path.join(home, '.ai-safety', 'global-guard-optout'),
  state: path.join(home, '.ai-safety', 'global-guard-state.json'),
});

function fireBashHook(home, command, cwd) {
  const s = JSON.parse(fs.readFileSync(P(home).claude, 'utf8'));
  const group = s.hooks.PreToolUse.find((g) => g.matcher === 'Bash|PowerShell');
  const h = group.hooks[0];
  const env = baseEnv(home, { AI_SAFE_LOG_DIR: path.join(home, 'hook-logs') });
  const payload = { hook_event_name: 'PreToolUse', tool_name: 'Bash', cwd, tool_input: { command } };
  const r = spawnSync(h.command, h.args || [], { input: JSON.stringify(payload), encoding: 'utf8', env, cwd });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}

test('既定でオン: 導入するだけで 4 エンジンに入り、hook は ~/.ai-safety/global を指す', { skip }, () => {
  const home = mkHome();
  const ws = path.join(home, 'Documents', 'my-ai-workspace');
  const r = install(home, ws);
  assert.strictEqual(r.code, 0, r.out.slice(-2000));
  const p = P(home);
  assert.match(r.out, /PC 全体の安全設定（最初から入っています）/);
  assert.match(r.out, /13_PC全体の安全設定を解除/);

  const claudeText = fs.readFileSync(p.claude, 'utf8');
  const guardDir = path.join(p.runtime, 'hooks', 'macos');
  for (const g of ['guard-prompt.sh', 'guard-bash.sh', 'guard-write.sh', 'guard-webfetch.sh']) {
    assert.ok(claudeText.includes(path.join(guardDir, g)), 'Claude の hook が固定の置き場を指していない: ' + g);
  }
  assert.ok(!claudeText.includes(ws), 'Claude の hook が作業フォルダを指している');
  assert.ok(JSON.parse(claudeText).permissions.deny.length > 10, 'deny が入っていない');

  const cfg = fs.readFileSync(p.codexCfg, 'utf8');
  assert.match(cfg, /^sandbox_mode = "workspace-write"$/m);
  assert.match(cfg, /^approval_policy = "on-request"$/m);
  const codexHooks = fs.readFileSync(p.codexHooks, 'utf8');
  assert.ok(codexHooks.includes(path.join(guardDir, 'guard-bash.sh')) && !codexHooks.includes(ws));
  const agy = fs.readFileSync(p.agy, 'utf8');
  assert.ok(agy.includes(path.join(guardDir, 'guard-bash.sh')) && !agy.includes(ws));
  assert.strictEqual(JSON.parse(fs.readFileSync(p.opencode, 'utf8')).permission.bash['rm *'], 'deny');

  assert.ok(fs.existsSync(path.join(guardDir, 'guard-bash.sh')), '固定の置き場に guard が無い');
  assert.ok(!fs.existsSync(p.optout), '解除の記録を勝手に作った');
});

test('作業フォルダを移動・名前変更しても、全体設定の hook は rm -rf を止め、通常のコマンドは通す', { skip }, () => {
  const home = mkHome();
  const ws = path.join(home, 'Documents', 'my-ai-workspace');
  assert.strictEqual(install(home, ws).code, 0);
  fs.renameSync(ws, path.join(home, 'Documents', 'AI作業フォルダ'));
  const proj = path.join(home, 'proj');
  fs.mkdirSync(path.join(proj, 'somedir'), { recursive: true });

  const danger = fireBashHook(home, 'rm -rf somedir', proj);
  assert.strictEqual(danger.code, 2, danger.out);
  assert.match(danger.out, /BLOCKED/);
  assert.doesNotMatch(danger.out, /hook missing/);
  assert.ok(fs.existsSync(path.join(proj, 'somedir')));
  const ok = fireBashHook(home, 'ls -la', proj);
  assert.strictEqual(ok.code, 0, ok.out);
});

test('13 で解除すると記録が残り、次の導入・更新では入れ直さない。12 を押すとまた入る', { skip }, () => {
  const home = mkHome();
  const ws = path.join(home, 'Documents', 'my-ai-workspace');
  const p = P(home);
  assert.strictEqual(install(home, ws).code, 0);
  assert.ok(fs.existsSync(p.claude));

  // 13_PC全体の安全設定を解除（ボタンの中身と同じスクリプト）
  const u = runScript(home, path.join(ws, '.ai-safety', 'hooks', 'macos', 'uninstall-global-guard.sh'));
  assert.strictEqual(u.code, 0, u.out);
  assert.ok(fs.existsSync(p.optout), '解除の記録が作られていない');
  assert.ok(!fs.existsSync(p.claude), '解除しても Claude の全体設定が残っている（導入前は無かった）');
  assert.ok(!fs.existsSync(p.codexCfg), '解除しても Codex の全体設定が残っている（導入前は無かった）');

  // 更新（install をもう一度）
  const again = install(home, ws);
  assert.strictEqual(again.code, 0, again.out.slice(-2000));
  assert.match(again.out, /解除されているため、入れ直していません/);
  for (const f of [p.claude, p.codexCfg, p.codexHooks, p.agy, p.opencode]) {
    assert.ok(!fs.existsSync(f), '解除したのに入れ直した: ' + f);
  }

  // 12_PC全体に安全設定を入れる（ボタンの中身と同じスクリプト。確認は AI_SAFE_ASSUME_YES で通す）
  const a = runScript(home, path.join(ws, '.ai-safety', 'hooks', 'macos', 'apply-global-guard.sh'), { AI_SAFE_ASSUME_YES: '1' });
  assert.strictEqual(a.code, 0, a.out);
  assert.ok(!fs.existsSync(p.optout), '12 を押しても解除の記録が消えない');
  assert.ok(fs.readFileSync(p.claude, 'utf8').includes(path.join(p.runtime, 'hooks', 'macos', 'guard-bash.sh')));

  // 12 で入れ直したあとは、更新でも入れ続ける
  const third = install(home, ws);
  assert.strictEqual(third.code, 0);
  assert.match(third.out, /PC 全体の安全設定（最初から入っています）/);
});

test('AI_SAFE_NO_GLOBAL_GUARD=1 なら全体設定には触らない', { skip }, () => {
  const home = mkHome();
  const ws = path.join(home, 'Documents', 'my-ai-workspace');
  const p = P(home);
  const r = install(home, ws, { AI_SAFE_NO_GLOBAL_GUARD: '1' });
  assert.strictEqual(r.code, 0, r.out.slice(-2000));
  assert.match(r.out, /AI_SAFE_NO_GLOBAL_GUARD=1 のため入れませんでした/);
  for (const f of [p.claude, p.codexCfg, p.codexHooks, p.agy, p.opencode, p.runtime, p.state]) {
    assert.ok(!fs.existsSync(f), '触ってしまった: ' + f);
  }
});

test('更新での移行: 旧版が入れた「作業フォルダを指す hook」を張り替え、二重にせず、解除で元に戻る', { skip }, () => {
  const home = mkHome();
  const ws = path.join(home, 'Documents', 'my-ai-workspace');
  const p = P(home);
  // 受講者がもともと持っていた Claude の全体設定
  const original = { env: { MY_VAR: 'keep' }, model: 'opus',
    hooks: { Stop: [{ hooks: [{ type: 'command', command: '/opt/my-stop-hook.sh' }] }] } };
  fs.mkdirSync(path.dirname(p.claude), { recursive: true });
  fs.writeFileSync(p.claude, JSON.stringify(original, null, 2) + '\n');
  const originalText = fs.readFileSync(p.claude, 'utf8');

  // 旧版の状態を再現: 導入（自動反映なし）→ 旧版の「12」と同じく作業フォルダの guard を指して反映
  assert.strictEqual(install(home, ws, { AI_SAFE_NO_GLOBAL_GUARD: '1' }).code, 0);
  const oldGuardDir = path.join(ws, '.ai-safety', 'hooks', 'macos');
  const common = path.join(ws, '.ai-safety', 'hooks', 'common');
  const env = baseEnv(home);
  for (const args of [
    ['apply-global-guard.js', 'apply', '--source', path.join(ws, '.claude', 'settings.json'), '--target', p.claude, '--os', 'macos', '--guard-dir', oldGuardDir],
    ['apply-global-codex.js', 'apply', '--config-target', p.codexCfg, '--hooks-target', p.codexHooks, '--os', 'macos', '--guard-dir', oldGuardDir],
    ['apply-global-agy.js', 'apply', '--target', p.agy, '--os', 'macos', '--guard-dir', oldGuardDir],
  ]) {
    const r = spawnSync(process.execPath, [path.join(common, args[0]), ...args.slice(1)], { env, encoding: 'utf8' });
    assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  }
  const legacy = JSON.parse(fs.readFileSync(p.claude, 'utf8'));
  assert.ok(JSON.stringify(legacy.hooks).includes(oldGuardDir));

  // 更新 2 回（自動反映が張り替える。2 回目で何も変わらない）
  assert.strictEqual(install(home, ws).code, 0);
  const files = [p.claude, p.codexHooks, p.agy, p.codexCfg, p.opencode];
  const once = files.map((f) => fs.readFileSync(f, 'utf8'));
  assert.strictEqual(install(home, ws).code, 0);
  const twice = files.map((f) => fs.readFileSync(f, 'utf8'));
  assert.deepStrictEqual(twice, once, '更新を繰り返すと全体設定が変わる（冪等でない）');

  for (const t of once.slice(0, 3)) {
    assert.ok(!t.includes(oldGuardDir), '作業フォルダを指す hook が残った');
    assert.ok(t.includes(path.join(p.runtime, 'hooks', 'macos')), '固定の置き場を指していない');
  }
  const migrated = JSON.parse(once[0]);
  for (const ev of Object.keys(legacy.hooks)) {
    assert.strictEqual(migrated.hooks[ev].length, legacy.hooks[ev].length, ev + ' の hook が増えた/減った');
  }
  assert.ok(JSON.stringify(migrated.hooks.Stop).includes('/opt/my-stop-hook.sh'), '受講者自身の hook が消えた');
  assert.strictEqual(migrated.env.MY_VAR, 'keep');

  // 旧版の記録のまま解除できる（最初に入れる前の状態へ戻る）
  const u = runScript(home, path.join(ws, '.ai-safety', 'hooks', 'macos', 'uninstall-global-guard.sh'));
  assert.strictEqual(u.code, 0, u.out);
  assert.strictEqual(fs.readFileSync(p.claude, 'utf8'), originalText, '解除で元の設定に戻っていない');
});
