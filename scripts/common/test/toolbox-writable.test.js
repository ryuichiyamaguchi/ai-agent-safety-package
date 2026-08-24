// =============================================================
// toolbox-writable.test.js — 「道具の置き場は開ける／設定そのものは閉じたまま」の回帰テスト
//
// なぜこれがあるか（2026-08-21 受講生からの実機クレーム）:
//   「Claude Code にグローバルのスキルを導入してと頼んだら『ワークスペース外への書き込みは
//     禁止されているのでできません』と言われた」
// v1.16 までは「作業フォルダの中だけで使う」前提だったが、v1.17 で「PC 全体に最低限の安全
// 設定を入れる」「新しい作業フォルダを安全にする」を入れたことで、その前提が外れている。
// 卒業後に自分の環境を育てられないのは講座の目的に反するため、受講者が自分の道具（スキル・
// コマンド）を増やすための置き場だけを開けた。
//
// ⚠️ このテストが固定しているのは「開けたこと」だけではない。同じ数だけ「閉じたままである
// こと」を固定している。開けたのは『置き場』で、『設定そのもの』（~/.claude/settings.json ・
// ~/.codex/config.toml ・ ~/.gemini/settings.json ・ ~/.config/opencode/opencode.json(c) ・
// ~/.ai-safety/ ・ ~/.deepseek-claude/）は従来どおり書き込み禁止でなければならない。
// AI が自分への指示と安全設定そのものを書き換えられてはいけない、というのがこの線引きの
// 理由なので、片側だけ通るようになったらこのテストが FAIL する。
//
// 3 エンジン横断（bash のリダイレクト経路）の同じ線引きは tri-engine/cases.json の
// 「道具の置き場は開ける／設定そのものは閉じたまま」グループが見る。こちらは
// Write/Edit ツール経路（guard-write）と、設定生成側（opencode-config.js）を見る。
//
// 実行: node --test scripts/common/test/toolbox-writable.test.js
// =============================================================
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');

const REPO = path.resolve(__dirname, '..', '..', '..');
const POLICY = JSON.parse(fs.readFileSync(path.join(REPO, 'policy', 'safety-policy.json'), 'utf8'));

// 受講者が自分の道具を増やすための置き場（＝書き込みが通らなければならない）。
const TOOLBOX_WRITES = [
  '{HOME}/.claude/skills/my-skill/SKILL.md',
  '{HOME}/.claude/commands/hello.md',
  '{HOME}/.codex/prompts/hello.md',
  '{HOME}/.codex/skills/my-skill/SKILL.md',
  '{HOME}/.gemini/commands/hello.toml',
  '{HOME}/.gemini/skills/my-skill/SKILL.md',
  '{HOME}/.config/opencode/command/hello.md',
  '{HOME}/.config/opencode/skills/my-skill/SKILL.md',
];

// 設定そのもの・鍵・パッケージ本体（＝引き続き止まらなければならない）。
const CONFIG_WRITES = [
  '{HOME}/.claude/settings.json',
  '{HOME}/.claude/settings.local.json',
  '{HOME}/.codex/config.toml',
  '{HOME}/.gemini/settings.json',
  '{HOME}/.config/opencode/opencode.json',
  '{HOME}/.config/opencode/opencode.jsonc',
  // opencode のプラグインは opencode 本体のプロセス内で動く JS で、決定的 deny 床
  // （opencode-bouncer-monitor.mjs）そのものを無効化できる。意図的に『設定』側に置く。
  '{HOME}/.config/opencode/plugin/evil.mjs',
  '{HOME}/.ai-safety/policy/safety-policy.json',
  '{HOME}/.ai-safety/hooks/macos/guard-write.sh',
  '{HOME}/.deepseek-claude/auth',
  '{HOME}/.zshrc',
  // 免除の踏み台防止。置き場を経由した相対参照で設定本体へ届いてはいけない。
  '{HOME}/.claude/skills/../settings.json',
];

function subst(list, home) {
  return list.map((p) => p.replace('{HOME}', home));
}

// --- ポリシー（SSOT）そのもの ------------------------------------------------

test('ポリシー: 免除表がある。開けているのは置き場だけで、設定そのものは 1 つも当たらない', () => {
  const patterns = POLICY.toolboxWritablePathRegex;
  assert.ok(Array.isArray(patterns) && patterns.length > 0,
    'toolboxWritablePathRegex が空です（免除ゼロ＝受講生が道具を増やせない状態に戻っています）');
  const compiled = patterns.map((p) => new RegExp(p, 'i'));
  const hits = (value) => compiled.some((re) => re.test(value));

  for (const target of subst(TOOLBOX_WRITES, '/Users/example')) {
    assert.ok(hits(target), `道具の置き場が免除表に当たりません: ${target}`);
  }
  for (const target of subst(CONFIG_WRITES, '/Users/example')) {
    if (target.includes('/../')) continue; // .. の扱いは各エンジン側の責務（下で見る）
    assert.ok(!hits(target), `設定そのものが免除表に当たっています（開けてはいけない）: ${target}`);
  }
});

test('ポリシー: 設定そのものは書き込み保護（redirectProtectedPathRegex）に当たり続けている', () => {
  const redirect = POLICY.redirectProtectedPathRegex.map((p) => new RegExp(p, 'i'));
  const protectedPath = POLICY.protectedPathRegex.map((p) => new RegExp(p, 'i'));
  for (const target of subst(CONFIG_WRITES, '/Users/example')) {
    const hit = redirect.some((re) => re.test(target)) || protectedPath.some((re) => re.test(target));
    assert.ok(hit, `書き込み保護から漏れています: ${target}`);
  }
});

// --- OpenCode の決定的 deny 床 -------------------------------------------------

test('OpenCode 床: 置き場への書き込みは通り、設定そのものは止まる', async () => {
  const mod = await import(path.join(REPO, 'scripts', 'common', 'opencode-bouncer-monitor.mjs'));
  const Bouncer = mod.default || mod.BouncerApprovalMonitor;
  const { loadDenyFloor, denyReason, isToolboxWritablePath } = Bouncer;
  const floor = loadDenyFloor([path.join(REPO, 'policy', 'safety-policy.json')]);
  assert.strictEqual(floor.ok, true, '床を読み込めていません');
  assert.ok(floor.toolboxWritable.length > 0, '免除表が床に載っていません');

  for (const target of subst(TOOLBOX_WRITES, '/Users/example')) {
    assert.ok(isToolboxWritablePath(target, floor), `免除されていません: ${target}`);
    assert.strictEqual(denyReason(`echo hi > ${target}`, floor), null,
      `道具の置き場への書き込みが止められました: ${target}`);
  }
  for (const target of subst(CONFIG_WRITES, '/Users/example')) {
    assert.ok(denyReason(`echo evil > ${target}`, floor) !== null,
      `設定そのものへの書き込みが通ってしまいました: ${target}`);
  }
});

test('OpenCode 床: .. を含むパスは免除しない（免除の踏み台にさせない）', async () => {
  const mod = await import(path.join(REPO, 'scripts', 'common', 'opencode-bouncer-monitor.mjs'));
  const Bouncer = mod.default || mod.BouncerApprovalMonitor;
  const floor = Bouncer.loadDenyFloor([path.join(REPO, 'policy', 'safety-policy.json')]);
  for (const target of [
    '/Users/example/.claude/skills/../settings.json',
    '/Users/example/.claude/skills/../../.ai-safety/policy/safety-policy.json',
    'C:\\Users\\example\\.claude\\skills\\..\\settings.json',
  ]) {
    assert.strictEqual(Bouncer.isToolboxWritablePath(target, floor), false, target);
  }
});

// --- OpenCode の設定生成側 -----------------------------------------------------

test('OpenCode 設定: external_directory は読み取り開放（catch-all allow）でも置き場の allow と `..` 封じを保つ', () => {
  const mod = require(path.join(REPO, 'scripts', 'common', 'opencode-config.js'));
  const rules = mod.buildOpenCodeConfig({
    port: 8788, gatewayToken: 'dummy', mcpDir: path.join(os.tmpdir(), 'no-such-mcp-dir'),
  }).permission.external_directory;
  const keys = Object.keys(rules);
  // 最後に一致したルールが勝つので、catch-all は必ず先頭・`..` 封じ deny は必ず末尾にあること。
  assert.strictEqual(keys[0], '*', 'catch-all が先頭にありません');
  // 2026-08-24: 読み取り開放。書き込みの確認は edit 表（'*': ask）が担う。
  assert.strictEqual(rules['*'], 'allow');
  assert.strictEqual(keys[keys.length - 1], '**/../**', '`..` 封じが末尾にありません');
  assert.strictEqual(rules['**/../**'], 'deny');
  for (const dir of ['~/.claude/skills/**', '~/.claude/commands/**', '~/.codex/prompts/**',
    '~/.codex/skills/**', '~/.gemini/commands/**', '~/.gemini/skills/**',
    '~/.config/opencode/command/**', '~/.config/opencode/skills/**']) {
    assert.strictEqual(rules[dir], 'allow', `置き場が開いていません: ${dir}`);
  }
  // 設定そのもの・プラグイン・エージェント定義は開けない。
  for (const dir of Object.keys(rules)) {
    assert.ok(!/plugin|agents?\//.test(dir), `開けてはいけない場所が開いています: ${dir}`);
  }
});

test('OpenCode 設定: edit 表は各 CLI の設定そのものを deny で閉じている（longrun でも）', () => {
  const mod = require(path.join(REPO, 'scripts', 'common', 'opencode-config.js'));
  for (const longrun of [false, true]) {
    const edit = mod.enforcedEditRules(longrun);
    for (const file of ['~/.claude/settings.json', '~/.codex/config.toml',
      '~/.gemini/settings.json', '~/.config/opencode/opencode.json',
      '~/.config/opencode/opencode.jsonc']) {
      assert.strictEqual(edit[file], 'deny', `longrun=${longrun}: ${file} が deny ではありません`);
    }
    assert.strictEqual(edit['**/.ai-safety/**'], 'deny');
  }
});

// --- Write/Edit ツール経路（本物のガードを起動する） ----------------------------

function macVerdict(target, home) {
  const payload = JSON.stringify({
    hook_event_name: 'PreToolUse',
    tool_name: 'Write',
    cwd: path.join(home, 'workspace'),
    tool_input: { file_path: target, content: 'hello' },
  });
  const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-toolbox-'));
  const result = spawnSync('bash', [path.join(REPO, 'scripts', 'macos', 'guard-write.sh')], {
    input: payload,
    encoding: 'utf8',
    env: { ...process.env, AI_SAFE_LOG_DIR: path.join(logDir, 'logs') },
  });
  fs.rmSync(logDir, { recursive: true, force: true });
  if (result.status === 2) return String(result.stderr).includes('FATAL') ? 'fatal' : 'block';
  if (result.status !== 0) return `error(${result.status})`;
  return String(result.stdout).includes('"permissionDecision":"ask"') ? 'ask' : 'pass';
}

test('mac guard-write: 置き場は確認なしで通り、設定そのものは止まる', { skip: process.platform !== 'darwin' ? 'macOS 専用' : false }, () => {
  const home = '/Users/example';
  for (const target of subst(TOOLBOX_WRITES, home)) {
    assert.strictEqual(macVerdict(target, home), 'pass',
      `道具の置き場への書き込みが通りませんでした: ${target}`);
  }
  for (const target of subst(CONFIG_WRITES, home)) {
    assert.strictEqual(macVerdict(target, home), 'block',
      `設定そのものへの書き込みが止まりませんでした: ${target}`);
  }
});

function hasPwsh() {
  try {
    execFileSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], {
      encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'ignore'],
    });
    return true;
  } catch {
    return false;
  }
}

function winVerdict(target, cwd) {
  const payload = JSON.stringify({
    hook_event_name: 'PreToolUse',
    tool_name: 'Write',
    cwd,
    tool_input: { file_path: target, content: 'hello' },
  });
  const td = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-toolbox-ps-'));
  const inputFile = path.join(td, 'input.json');
  fs.writeFileSync(inputFile, payload, 'utf8');
  // ⚠️ `-File` + 標準入力で渡すこと（win-verdicts.ps1 と同じ形）。`-Command` で
  // PowerShell のパイプラインに流すと Read-HookInput が読む標準入力には届かず、
  // 入力ゼロのまま allow で終わる＝テストが素通りする。
  const result = spawnSync('pwsh',
    ['-NoProfile', '-File', path.join(REPO, 'scripts', 'windows', 'guard-write.ps1')], {
      input: fs.readFileSync(inputFile),
      encoding: 'utf8',
      env: { ...process.env, AI_SAFE_LOG_DIR: path.join(td, 'logs') },
    });
  fs.rmSync(td, { recursive: true, force: true });
  if (result.status === 2) return String(result.stderr).includes('FATAL') ? 'fatal' : 'block';
  if (result.status !== 0) return `error(${result.status}) ${String(result.stderr).slice(0, 200)}`;
  return String(result.stdout).includes('"permissionDecision":"ask"') ? 'ask' : 'pass';
}

test('Windows guard-write: 置き場は確認なしで通り、設定そのものは止まる', { skip: hasPwsh() ? false : 'pwsh がありません' }, () => {
  // Windows 実機でなくても pwsh があれば判定ロジックは同じものが走る。
  // パスの見た目を Windows 形にすると Resolve-SafePath が非 Windows で解決できないため、
  // ここでは POSIX 形のホームで見る（免除表は両方の区切り文字に当たるよう書いてある）。
  const home = '/Users/example';
  const cwd = '/Users/example/workspace';
  for (const target of subst(TOOLBOX_WRITES, home)) {
    assert.strictEqual(winVerdict(target, cwd), 'pass',
      `道具の置き場への書き込みが通りませんでした: ${target}`);
  }
  for (const target of subst(CONFIG_WRITES, home)) {
    assert.strictEqual(winVerdict(target, cwd), 'block',
      `設定そのものへの書き込みが止まりませんでした: ${target}`);
  }
});

// --- Claude Code の permissions ------------------------------------------------

test('Claude 設定: 置き場は Edit(...) で allow、設定そのものは Edit(...) で deny', () => {
  for (const file of ['settings.mac.json', 'settings.windows.json']) {
    const settings = JSON.parse(
      fs.readFileSync(path.join(REPO, 'configs', 'claude', file), 'utf8'),
    );
    const allow = settings.permissions.allow;
    const deny = settings.permissions.deny;
    for (const rule of ['Edit(~/.claude/skills/**)', 'Edit(~/.claude/commands/**)',
      'Edit(~/.codex/prompts/**)', 'Edit(~/.codex/skills/**)',
      'Edit(~/.gemini/commands/**)', 'Edit(~/.gemini/skills/**)',
      'Edit(~/.config/opencode/command/**)', 'Edit(~/.config/opencode/skills/**)']) {
      assert.ok(allow.includes(rule), `${file}: ${rule} が allow にありません`);
    }
    for (const rule of ['Edit(~/.claude/settings.json)', 'Edit(~/.claude.json)',
      'Edit(~/.codex/config.toml)', 'Edit(~/.gemini/settings.json)',
      'Edit(~/.config/opencode/opencode.json)', 'Edit(~/.config/opencode/opencode.jsonc)',
      'Edit(**/.ai-safety/**)', 'Edit(**/.deepseek-claude/**)']) {
      assert.ok(deny.includes(rule), `${file}: ${rule} が deny にありません`);
    }
    // Claude Code はファイル書き込みの権限照合に Edit(path) しか使わない。
    // Write(path) を書いても参照されないので、置き場の許可が Write(...) で書かれていたら落とす。
    for (const rule of [...allow, ...deny]) {
      assert.ok(!/^Write\(.+\)$/.test(rule),
        `${file}: Write(path) 形式のルールは Claude Code に参照されません: ${rule}`);
    }
  }
});
