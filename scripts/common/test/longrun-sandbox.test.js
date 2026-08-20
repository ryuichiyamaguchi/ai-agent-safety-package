'use strict';
// longrun-sandbox.test.js — 「（上級）15_長時間おまかせモードで起動」の守りを検査する。
//
// v1.17.0 までの設計（誤り）:
//   「壁（OS サンドボックス）が効く環境でしか使わせない」＝ mac の Claude 専用。
//   Windows は理由を出して起動を拒否するだけだった。これは実装側が勝手に安全側へ倒した
//   もので、依頼者の意図と違った。
//
// v1.17.1 の設計（正）:
//   Claude / Codex / OpenCode / agy のすべてで、mac / Windows の両方で使える。
//   各環境で**使える最大限の守り**を効かせる。壁が無い環境では **一度だけ確認**を取る。
//   どの環境でも deny 床・記録・bypassPermissions 封印は外さない。
//
// Claude Code 2.1.236 のバイナリ内文字列で確認した実キー:
//   "Sandbox required but unavailable: "
//   ". Set sandbox.failIfUnavailable=false to allow unsandboxed execution."
// = `sandbox.failIfUnavailable: true` のとき、壁が使えなければ本体側が実行しない。
// 恒久設定には入れず（受講者が通常起動で詰むため）、壁がある経路の一時設定にだけ立てる。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PKG = path.resolve(__dirname, '..', '..', '..');
const SCRIPT = path.join(PKG, 'scripts', 'macos', 'launch-longrun.sh');
const SCRIPT_WIN = path.join(PKG, 'scripts', 'windows', 'launch-longrun.ps1');
const macOnly = process.platform === 'darwin' ? false : 'macOS 専用の経路のため skip';

test('長時間おまかせモードの実体が mac / Windows の両方にある', () => {
  assert.ok(fs.existsSync(SCRIPT), 'mac 実体がない');
  assert.ok(fs.existsSync(SCRIPT_WIN), 'Windows 実体がない');
  assert.ok(!fs.existsSync(path.join(PKG, 'scripts', 'macos', 'launch-claude-longrun.sh')),
    'Claude 専用だった旧実体が残っている');
  assert.ok(!fs.existsSync(path.join(PKG, 'scripts', 'windows', 'launch-claude-longrun.ps1')),
    'Claude 専用だった旧実体が残っている');
});

test('4 エンジンから選べる（Claude 専用に戻っていない）', () => {
  const sh = fs.readFileSync(SCRIPT, 'utf8');
  const ps1 = fs.readFileSync(SCRIPT_WIN, 'utf8');
  for (const src of [sh, ps1]) {
    for (const engine of ['claude', 'codex', 'opencode', 'agy']) {
      assert.ok(src.includes(engine), `エンジン ${engine} の選択肢がない`);
    }
  }
});

test('Windows 版が「起動を拒否するだけ」に戻っていない', () => {
  const ps1 = fs.readFileSync(SCRIPT_WIN, 'utf8');
  assert.ok(ps1.includes('launch-codex-safe.ps1'), 'Windows の Codex 経路がない');
  assert.ok(ps1.includes('launch-agy-safe.ps1'), 'Windows の agy 経路がない');
  assert.ok(ps1.includes('launch-integrated.ps1'), 'Windows の OpenCode 経路がない');
  assert.ok(ps1.includes('disableBypassPermissionsMode'), 'Windows の Claude 経路の封印がない');
  assert.ok(!/いまは Mac でだけ使えます/.test(ps1), 'Windows で起動を拒否する旧仕様が残っている');
});

test('恒久設定（configs/claude/settings.mac.json）には failIfUnavailable を入れない', () => {
  const s = JSON.parse(fs.readFileSync(path.join(PKG, 'configs', 'claude', 'settings.mac.json'), 'utf8'));
  assert.ok(s.sandbox, 'sandbox 節が無い');
  assert.strictEqual(s.sandbox.enabled, true);
  assert.strictEqual(
    Object.prototype.hasOwnProperty.call(s.sandbox, 'failIfUnavailable'), false,
    '恒久設定に failIfUnavailable を入れると通常起動で受講者が詰む');
});

// --- 実測用の作業フォルダ（スタブのランチャーを置いて、渡される引数を回収する） ------
function makeWorkspace(t) {
  const base = path.join(os.homedir(), '.sena-tmp');
  fs.mkdirSync(base, { recursive: true });
  const ws = fs.mkdtempSync(path.join(base, 'longrun-ws-'));
  const bin = fs.mkdtempSync(path.join(base, 'longrun-bin-'));
  t.after(() => {
    fs.rmSync(ws, { recursive: true, force: true });
    fs.rmSync(bin, { recursive: true, force: true });
  });

  const hooks = path.join(ws, '.ai-safety', 'hooks', 'macos');
  fs.mkdirSync(path.join(ws, '.claude'), { recursive: true });
  fs.mkdirSync(path.join(ws, '.ai-safety', 'policy'), { recursive: true });
  fs.mkdirSync(hooks, { recursive: true });
  fs.copyFileSync(path.join(PKG, 'configs', 'claude', 'settings.mac.json'),
    path.join(ws, '.claude', 'settings.json'));
  fs.copyFileSync(path.join(PKG, 'policy', 'safety-policy.json'),
    path.join(ws, '.ai-safety', 'policy', 'safety-policy.json'));

  // 各エンジンのランチャーはスタブに差し替え、渡された引数だけを控える。
  const argsLog = path.join(ws, 'dispatch.txt');
  for (const name of ['launch-codex-safe.sh', 'launch-agy-safe.sh', 'launch-integrated.sh']) {
    fs.writeFileSync(path.join(hooks, name), [
      '#!/usr/bin/env bash',
      `printf '%s %s\\n' ${JSON.stringify(name)} "$*" >> ${JSON.stringify(argsLog)}`,
      'exit 0',
    ].join('\n') + '\n', { mode: 0o755 });
  }
  return { ws, bin, argsLog };
}

function runLongrun({ ws, bin }, engine, input) {
  return spawnSync('bash', [SCRIPT, ws, engine], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
    encoding: 'utf8',
    input,
    timeout: 120000,
  });
}

test('壁がある経路（Claude / mac）: 一時設定に failIfUnavailable=true が立ち、床は緩んでいない',
  { skip: macOnly }, (t) => {
    const env = makeWorkspace(t);
    const captured = path.join(env.ws, 'captured-settings.json');
    // claude スタブ: --settings で渡された一時設定を丸ごと控える。
    fs.writeFileSync(path.join(env.bin, 'claude'), [
      '#!/usr/bin/env bash',
      'if [ "$1" = "--help" ]; then echo "  --permission-mode <mode>"; exit 0; fi',
      'prev=""',
      'for a in "$@"; do',
      '  if [ "$prev" = "--settings" ]; then cp "$a" ' + JSON.stringify(captured) + '; fi',
      '  prev="$a"',
      'done',
      'exit 0',
    ].join('\n') + '\n', { mode: 0o755 });

    const r = runLongrun(env, 'claude', '\n');
    assert.strictEqual(r.status, 0, r.stdout + r.stderr);
    assert.ok(fs.existsSync(captured), '一時設定を回収できなかった:\n' + r.stdout + r.stderr);

    const tmp = JSON.parse(fs.readFileSync(captured, 'utf8'));
    assert.strictEqual(tmp.sandbox.enabled, true);
    assert.strictEqual(tmp.sandbox.autoAllowBashIfSandboxed, true);
    assert.strictEqual(tmp.sandbox.failIfUnavailable, true, '壁の実起動が保証されていない');
    assert.deepStrictEqual(tmp.permissions.ask, [], 'ask は空にする（無人で答えられないため）');
    assert.strictEqual(tmp.permissions.defaultMode, 'acceptEdits');
    assert.strictEqual(tmp.permissions.disableBypassPermissionsMode, 'disable');
    assert.ok(tmp.permissions.deny.length >= 30, 'deny 床が減っている');
    // 恒久設定（作業フォルダの .claude/settings.json）は書き換えない。
    const permanent = JSON.parse(fs.readFileSync(path.join(env.ws, '.claude', 'settings.json'), 'utf8'));
    assert.ok(permanent.permissions.ask.length > 0, '恒久設定の ask が書き換えられている');
    assert.ok(!Object.prototype.hasOwnProperty.call(permanent.sandbox, 'failIfUnavailable'),
      '恒久設定に failIfUnavailable が書き込まれている');
  });

test('壁が無い経路（OpenCode）: 確認が 1 回出て、同意しなければ起動しない',
  { skip: macOnly }, (t) => {
    const env = makeWorkspace(t);
    const r = runLongrun(env, 'opencode', '\n');
    assert.strictEqual(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stdout, /壁.*ありません|壁がありません/, '壁が無いことを伝えていない');
    assert.match(r.stdout, /はい/, '同意を求めていない');
    assert.ok(!fs.existsSync(env.argsLog), '同意していないのに起動している');
  });

test('壁が無い経路（OpenCode）: 同意すると --longrun 付きで統合ランチャーへ渡る',
  { skip: macOnly }, (t) => {
    const env = makeWorkspace(t);
    const r = runLongrun(env, 'opencode', 'はい\n');
    assert.strictEqual(r.status, 0, r.stdout + r.stderr);
    const log = fs.readFileSync(env.argsLog, 'utf8');
    assert.match(log, /launch-integrated\.sh .*opencode standard --longrun/, log);
  });

test('壁がある経路（Codex）: --longrun 付きで Codex ランチャーへ渡る', { skip: macOnly }, (t) => {
  const env = makeWorkspace(t);
  const r = runLongrun(env, 'codex', '\n');
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  const log = fs.readFileSync(env.argsLog, 'utf8');
  assert.match(log, /launch-codex-safe\.sh .*--longrun/, log);
});

test('壁が無い経路（agy）: 同意すると --longrun 付きで agy ランチャーへ渡る', { skip: macOnly }, (t) => {
  const env = makeWorkspace(t);
  const r = runLongrun(env, 'agy', 'はい\n');
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  const log = fs.readFileSync(env.argsLog, 'utf8');
  assert.match(log, /launch-agy-safe\.sh .*--longrun/, log);
});

// --- 各エンジン側が --longrun を「緩める向きへ」使っていないこと ---------------------
test('Codex ランチャー: --longrun でも壁（--sandbox workspace-write）を外さない', () => {
  const sh = fs.readFileSync(path.join(PKG, 'scripts', 'macos', 'launch-codex-safe.sh'), 'utf8');
  assert.match(sh, /longrun=1/);
  assert.match(sh, /approval="never"/);
  assert.match(sh, /--sandbox workspace-write/);
  const ps1 = fs.readFileSync(path.join(PKG, 'scripts', 'windows', 'launch-codex-safe.ps1'), 'utf8');
  assert.match(ps1, /\[switch\]\$LongRun/);
  assert.match(ps1, /\$approval = 'never'/);
  assert.match(ps1, /"--sandbox", "workspace-write"/);
});

test('agy ランチャー: --longrun でも --sandbox を外さない', () => {
  const sh = fs.readFileSync(path.join(PKG, 'scripts', 'macos', 'launch-agy-safe.sh'), 'utf8');
  assert.match(sh, /longrun=1/);
  assert.match(sh, /--sandbox/);
  const ps1 = fs.readFileSync(path.join(PKG, 'scripts', 'windows', 'launch-agy-safe.ps1'), 'utf8');
  assert.match(ps1, /\[switch\]\$LongRun/);
  assert.match(ps1, /"--sandbox"/);
});

test('OpenCode: --longrun でも deny 床は 1 本も減らず、ask は deny 側へ倒れる', () => {
  const mod = require(path.join(PKG, 'scripts', 'common', 'opencode-config.js'));
  const normalDeny = mod.buildEnforcedPermissionEnv(false).bash;
  const longDeny = mod.buildEnforcedPermissionEnv(true).bash;
  for (const [pattern, action] of Object.entries(normalDeny)) {
    if (action !== 'deny') continue;
    assert.strictEqual(longDeny[pattern], 'deny', `deny 床が減っている: ${pattern}`);
  }
  for (const [pattern, action] of Object.entries(normalDeny)) {
    if (action !== 'ask') continue;
    assert.strictEqual(longDeny[pattern], 'deny', `ask だった ${pattern} が deny へ倒れていない`);
  }
  assert.ok(Object.values(longDeny).every((v) => v === 'deny'), 'longrun に ask が残っている');
  assert.strictEqual(mod.buildEnforcedPermissionEnv(true).external_directory, 'deny');
});

test('OpenCode: --longrun でも秘密の読み取り禁止と .ai-safety の書き換え禁止は外さない', () => {
  const mod = require(path.join(PKG, 'scripts', 'common', 'opencode-config.js'));
  const cfg = mod.buildOpenCodeConfig({
    port: 8788, gatewayToken: 'dummy', mcpDir: path.join(os.tmpdir(), 'no-such-mcp-dir'), longrun: true,
  });
  const normal = mod.buildOpenCodeConfig({
    port: 8788, gatewayToken: 'dummy', mcpDir: path.join(os.tmpdir(), 'no-such-mcp-dir'),
  });
  // 読み取り（.env / .ai-safety）の表は longrun でも一字一句同じ。
  assert.deepStrictEqual(cfg.permission.read, normal.permission.read);
  // 書き換えは '*' だけ allow になり、.ai-safety の deny は残る。
  assert.strictEqual(cfg.permission.edit['*'], 'allow');
  for (const [pattern, action] of Object.entries(normal.permission.edit)) {
    if (action !== 'deny') continue;
    assert.strictEqual(cfg.permission.edit[pattern], 'deny', `書き換え禁止が減っている: ${pattern}`);
  }
  // 外部送信は無人で確認できないので deny へ倒す（allow へは絶対に倒さない）。
  assert.strictEqual(cfg.permission.webfetch, 'deny');
  assert.strictEqual(cfg.permission.websearch, 'deny');
  assert.strictEqual(cfg.permission.external_directory, 'deny');
  assert.strictEqual(cfg.share, 'disabled');
});

test('OpenCode: 起動前検査は longrun の設定を通常モードとして受け取ると落とす', () => {
  const mod = require(path.join(PKG, 'scripts', 'common', 'opencode-config.js'));
  const cfg = mod.buildOpenCodeConfig({
    port: 8788, gatewayToken: 'dummy', mcpDir: path.join(os.tmpdir(), 'no-such-mcp-dir'), longrun: true,
  });
  const asNormal = mod.verifyResolvedConfig(cfg);
  assert.ok(asNormal.some((p) => p.includes('自動許可')), '通常モードの検査が longrun を素通ししている');
});
