'use strict';
// longrun-dclaude.test.js — 長時間おまかせモードで d-claude（DeepSeek で動かす Claude Code）を使えること（v1.19.9）。
//
// 道筋: launch-longrun（5 を選ぶ）→ launch-integrated（d-claude ＋ --longrun / -LongRun。キーの確認・
// DeepSeek へ送ることへの同意・モデルの指定はここでふだんどおり）→ launch-deepseek-gateway（印を引き継ぐ）
// → launch-claude-safe（長時間用の一時設定）。v1.20.0 から d-claude の長時間おまかせモードは dontAsk
// （確認が要る操作は自動で断り、入力を待たない）: ask → deny・全承認は封じたまま・Web 取得と d-claude の
// 補助ツールに許可の規則を足す・作業フォルダの設定は直接読まない（setting-sources から project を外す）・
// mac は壁を必須にし壁の外での実行し直しも禁止・ガードへ長時間の印（AI_SAFE_LONGRUN=1）・AI 判定は必ずオン。
// dontAsk が無い古い Claude Code では acceptEdits。d-claude 用の補助（正直さの指示・補助ツール）はそのまま効かせる。
//
// 本物の Claude Code の代わりに、渡された設定と引数を控える偽物を使う。HOME は使い捨て（本物のホームには触らない）。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PKG = path.resolve(__dirname, '..', '..', '..');
const read = (...p) => fs.readFileSync(path.join(PKG, ...p), 'utf8').replace(/\r\n/g, '\n');
const macOnly = process.platform === 'darwin' ? false : 'macOS 専用の経路のため skip';
const pwshCheck = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8' });
const HAS_PWSH = pwshCheck.status === 0 && process.platform !== 'win32';

// --- 配線（ソースの照合）-----------------------------------------------------------------
test('長時間おまかせモードの選択肢に d-claude があり、統合ランチャーへ長時間の印つきで渡す', () => {
  const sh = read('scripts', 'macos', 'launch-longrun.sh');
  const ps1 = read('scripts', 'windows', 'launch-longrun.ps1');
  assert.match(sh, /5\) engine="d-claude"/);
  assert.match(sh, /launch-integrated\.sh" "\$workspace" d-claude standard --longrun/);
  assert.match(ps1, /'5' \{ \$Engine = 'd-claude' \}/);
  assert.match(ps1, /launch-integrated\.ps1'\) -Workspace \$Workspace -Agent d-claude -SafetyProfile standard -LongRun/);
});

test('統合ランチャーは d-claude にも長時間の印を許し、中継へ渡す（ほかの AI には許さない）', () => {
  const sh = read('scripts', 'macos', 'launch-integrated.sh');
  const ps1 = read('scripts', 'windows', 'launch-integrated.ps1');
  assert.match(sh, /bash "\$gateway" "\$workspace" --longrun/);
  assert.match(sh, /--longrun は OpenCode と d-claude だけ/);
  assert.match(ps1, /if \(\$LongRun\) \{ \$gwArgs \+= '-LongRun' \}/);
  assert.match(ps1, /-LongRun は OpenCode と d-claude だけ/);
});

test('中継は長時間の印を安全起動へ引き継ぐ', () => {
  assert.match(read('scripts', 'macos', 'deepseek', 'launch-deepseek-gateway.sh'), /bash "\$LAUNCH_CLAUDE" "\$WORKSPACE" --longrun/);
  assert.match(read('scripts', 'windows', 'deepseek', 'launch-deepseek-gateway.ps1'), /& \$launchClaude -Workspace \$Workspace -LongRun/);
});

// --- 実際に動かす ---------------------------------------------------------------------------
function makeSandbox(t) {
  const base = path.join(os.homedir(), '.cache');
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, 'asp-longrun-dclaude-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, 'home');
  const ws = path.join(root, 'ws');
  const bin = path.join(root, 'bin');
  for (const d of [home, ws, bin, path.join(ws, '.claude'), path.join(ws, '.ai-safety', 'policy')]) {
    fs.mkdirSync(d, { recursive: true });
  }
  fs.copyFileSync(path.join(PKG, 'policy', 'safety-policy.json'), path.join(ws, '.ai-safety', 'policy', 'safety-policy.json'));
  return { root, home, ws, bin };
}

// 偽の claude: --help には主要フラグを答え、本起動では渡された設定ファイルと引数を控える。
function writeFakeClaude(sb, { dontAsk = true } = {}) {
  const captured = path.join(sb.root, 'captured-settings.json');
  const argsFile = path.join(sb.root, 'captured-args.txt');
  const settingsPathFile = path.join(sb.root, 'captured-settings-path.txt');
  const fake = path.join(sb.bin, 'claude');
  fs.writeFileSync(fake, [
    '#!/usr/bin/env bash',
    dontAsk
      ? `if [ "\${1:-}" = "--help" ]; then echo '  --permission-mode <mode> (choices: "acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan")  --append-system-prompt <p>  --mcp-config <f>'; exit 0; fi`
      : 'if [ "${1:-}" = "--help" ]; then echo "  --permission-mode <mode>  --append-system-prompt <p>  --mcp-config <f>"; exit 0; fi',
    'if [ "${1:-}" = "--version" ]; then echo "2.1.999 (Claude Code)"; exit 0; fi',
    `printf '%s\\n' "$@" > ${JSON.stringify(argsFile)}`,
    `printf '%s' "\${AI_SAFE_LONGRUN:-}" > ${JSON.stringify(argsFile + '.longrun')}`,
    `printf '%s' "\${AI_SAFE_ASSISTED_APPROVAL:-}" > ${JSON.stringify(argsFile + '.assisted')}`,
    'prev=""',
    'for a in "$@"; do',
    `  if [ "$prev" = "--settings" ]; then cp "$a" ${JSON.stringify(captured)}; printf '%s' "$a" > ${JSON.stringify(settingsPathFile)}; fi`,
    '  prev="$a"',
    'done',
    'exit 0',
  ].join('\n') + '\n', { mode: 0o755 });
  return { fake, captured, argsFile, settingsPathFile };
}

function assertLongrunSettings(cap, { wall, mode = 'dontAsk' }) {
  assert.ok(fs.existsSync(cap.captured), '一時設定が渡されていない');
  const s = JSON.parse(fs.readFileSync(cap.captured, 'utf8'));
  assert.deepStrictEqual(s.permissions.ask, [], 'ask は空にする（無人で答えられないため）');
  assert.strictEqual(s.permissions.disableBypassPermissionsMode, 'disable', '全承認は封じたまま');
  assert.notStrictEqual(s.permissions.defaultMode, 'bypassPermissions');
  assert.ok(s.permissions.deny.length >= 30, 'deny 床が減っている');
  for (const rule of ['WebFetch', 'mcp__gemini-search', 'mcp__agy-image', 'mcp__playwright']) {
    assert.ok(s.permissions.allow.includes(rule), `確認なしで使えるようにする許可の規則が無い: ${rule}`);
  }
  assert.ok(s.hooks && s.hooks.PreToolUse && s.hooks.PreToolUse.length > 0, 'ガード（フック）が一時設定に入っていない');
  if (wall) {
    assert.strictEqual(s.sandbox && s.sandbox.failIfUnavailable, true, '壁がある環境なのに壁が必須になっていない');
    assert.strictEqual(s.sandbox.allowUnsandboxedCommands, false, '壁の外での実行し直しを禁止すること');
  }
  const args = fs.readFileSync(cap.argsFile, 'utf8').split('\n');
  const pm = args.indexOf('--permission-mode');
  assert.ok(pm >= 0 && args[pm + 1] === mode, `--permission-mode ${mode} が渡っていない: ` + args.join(' '));
  assert.ok(!args.some((a) => /bypassPermissions|skip-permissions/i.test(a)), '全承認で起動している');
  const ss = args.indexOf('--setting-sources');
  assert.strictEqual(args[ss + 1], 'user,local', '作業フォルダの設定（ask を確認として持つ）を直接読んでいる');
  assert.strictEqual(fs.readFileSync(cap.argsFile + '.longrun', 'utf8'), '1', 'ガードへ長時間の印が渡っていない');
  assert.strictEqual(fs.readFileSync(cap.argsFile + '.assisted', 'utf8'), '1',
    'AI 判定がオフ（許可リストにないコマンドがすべて断られて作業が進まない）');
  assert.ok(args.includes('--append-system-prompt'), 'd-claude の正直さの指示が付いていない（d-claude の補助が外れている）');
  const tmpPath = fs.readFileSync(cap.settingsPathFile, 'utf8');
  assert.ok(!fs.existsSync(tmpPath), '終了後も一時設定が残っている: ' + tmpPath);
}

test('mac: 長時間おまかせモードで 5 を選ぶと、統合ランチャーへ d-claude ＋ --longrun で渡る', { skip: macOnly }, (t) => {
  const sb = makeSandbox(t);
  fs.copyFileSync(path.join(PKG, 'configs', 'claude', 'settings.mac.json'), path.join(sb.ws, '.claude', 'settings.json'));
  const hooks = path.join(sb.ws, '.ai-safety', 'hooks', 'macos');
  fs.mkdirSync(hooks, { recursive: true });
  const log = path.join(sb.root, 'dispatch.txt');
  fs.writeFileSync(path.join(hooks, 'launch-integrated.sh'),
    `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> ${JSON.stringify(log)}\nexit 0\n`, { mode: 0o755 });
  const r = spawnSync('bash', [path.join(PKG, 'scripts', 'macos', 'launch-longrun.sh'), sb.ws], {
    env: { ...process.env, HOME: sb.home, AI_SAFE_SNAPSHOT: 'off' },
    input: '5\nはい\n',
    encoding: 'utf8',
    timeout: 120000,
  });
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /d-claude（DeepSeek）/);
  assert.match(fs.readFileSync(log, 'utf8'), /d-claude standard --longrun/);
});

test('mac: 安全起動は --longrun で長時間用の一時設定を使い、d-claude の補助も外さない', { skip: macOnly }, (t) => {
  const sb = makeSandbox(t);
  fs.copyFileSync(path.join(PKG, 'configs', 'claude', 'settings.mac.json'), path.join(sb.ws, '.claude', 'settings.json'));
  const cap = writeFakeClaude(sb);
  const r = spawnSync('bash', [path.join(PKG, 'scripts', 'macos', 'launch-claude-safe.sh'), sb.ws, '--longrun'], {
    env: { ...process.env, HOME: sb.home, PATH: `${sb.bin}:${process.env.PATH}`, DS_CLAUDE_MODE: '1', AI_SAFE_ASSISTED_APPROVAL: '0' },
    encoding: 'utf8',
    timeout: 120000,
  });
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  assertLongrunSettings(cap, { wall: fs.existsSync('/usr/bin/sandbox-exec') });
  // 恒久設定（作業フォルダの .claude/settings.json）は書き換えない。
  const permanent = JSON.parse(fs.readFileSync(path.join(sb.ws, '.claude', 'settings.json'), 'utf8'));
  assert.ok(permanent.permissions.ask.length > 0, '恒久設定の ask が書き換えられている');
});

test('mac: dontAsk が無い古い Claude Code では、長時間おまかせモードを acceptEdits で起動する', { skip: macOnly }, (t) => {
  const sb = makeSandbox(t);
  fs.copyFileSync(path.join(PKG, 'configs', 'claude', 'settings.mac.json'), path.join(sb.ws, '.claude', 'settings.json'));
  const cap = writeFakeClaude(sb, { dontAsk: false });
  const r = spawnSync('bash', [path.join(PKG, 'scripts', 'macos', 'launch-claude-safe.sh'), sb.ws, '--longrun'], {
    env: { ...process.env, HOME: sb.home, PATH: `${sb.bin}:${process.env.PATH}`, DS_CLAUDE_MODE: '1' },
    encoding: 'utf8',
    timeout: 120000,
  });
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  assertLongrunSettings(cap, { wall: fs.existsSync('/usr/bin/sandbox-exec'), mode: 'acceptEdits' });
});

test('mac: --longrun が無ければ、ふだんの設定と --permission-mode default のまま', { skip: macOnly }, (t) => {
  const sb = makeSandbox(t);
  fs.copyFileSync(path.join(PKG, 'configs', 'claude', 'settings.mac.json'), path.join(sb.ws, '.claude', 'settings.json'));
  const cap = writeFakeClaude(sb);
  const r = spawnSync('bash', [path.join(PKG, 'scripts', 'macos', 'launch-claude-safe.sh'), sb.ws], {
    env: { ...process.env, HOME: sb.home, PATH: `${sb.bin}:${process.env.PATH}`, DS_CLAUDE_MODE: '1' },
    encoding: 'utf8',
    timeout: 120000,
  });
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  const args = fs.readFileSync(cap.argsFile, 'utf8').split('\n');
  assert.strictEqual(args[args.indexOf('--permission-mode') + 1], 'default');
  assert.strictEqual(args[args.indexOf('--setting-sources') + 1], 'user,project,local');
  assert.strictEqual(fs.readFileSync(cap.argsFile + '.longrun', 'utf8'), '', 'ふだんの起動に長時間の印が立っている');
  assert.strictEqual(fs.readFileSync(cap.settingsPathFile, 'utf8'), path.join(sb.ws, '.claude', 'settings.json'));
});

test('Windows（pwsh で検証）: 安全起動は -LongRun で長時間用の一時設定を使い、d-claude の補助も外さない',
  { skip: HAS_PWSH ? false : 'pwsh が無い環境（Windows 実機では CI で確認）' }, (t) => {
    const sb = makeSandbox(t);
    fs.copyFileSync(path.join(PKG, 'configs', 'claude', 'settings.windows.json'), path.join(sb.ws, '.claude', 'settings.json'));
    const cap = writeFakeClaude(sb);
    const r = spawnSync('pwsh', ['-NoProfile', '-File', path.join(PKG, 'scripts', 'windows', 'launch-claude-safe.ps1'), '-Workspace', sb.ws, '-LongRun'], {
      env: { ...process.env, HOME: sb.home, USERPROFILE: sb.home, CLAUDE_BIN: cap.fake, PATH: `${sb.bin}:${process.env.PATH}`, DS_CLAUDE_MODE: '1', AI_SAFE_ASSISTED_APPROVAL: '0' },
      encoding: 'utf8',
      timeout: 120000,
    });
    assert.strictEqual(r.status, 0, r.stdout + r.stderr);
    assertLongrunSettings(cap, { wall: false });
  });
