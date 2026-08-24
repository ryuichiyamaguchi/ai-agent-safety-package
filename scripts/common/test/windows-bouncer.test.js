'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..', '..');

function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}

// v1.17.0: ローカル LLM（Gemma）必須の「最大保護モード」と、その検査 Gateway
// (bouncer-gateway/) は廃止した。受講生の PC ではほぼ動かせないのにメニューに
// 出ていたため。ここでは「消えたまま戻ってこないこと」も一緒に見る。
test('Windows integrated launcher has standard and assisted profiles only', () => {
  const script = read('scripts/windows/launch-integrated.ps1');
  // v1.18.0: 対話メニュー（課金プラン順）をランチャー本体へ集約したので 'menu' が増えた。
  assert.match(script, /ValidateSet\('menu','codex','claude','opencode','d-claude'\)/);
  assert.match(script, /ValidateSet\('standard','assisted'\)/);
  assert.match(script, /standard/);
  assert.doesNotMatch(script, /maximum/);
  assert.doesNotMatch(script, /run-local\.ps1/);
  assert.doesNotMatch(script, /8787/);
  assert.doesNotMatch(script, /BOUNCER_INTEGRATED_MODE/);
  assert.match(script, /AI_SAFE_DRY_RUN/);
  assert.match(script, /'d-claude:standard'/);
  assert.match(script, /launch-deepseek-safe[.]ps1/);
  assert.match(script, /deepseek\\launch-deepseek-gateway[.]ps1/);
  assert.match(script, /ANTHROPIC_AUTH_TOKEN/);
  assert.match(script, /ANTHROPIC_MODEL = 'deepseek-v4-flash'/);
  assert.match(script, /ANTHROPIC_DEFAULT_OPUS_MODEL = 'deepseek-v4-flash'/);
  assert.match(script, /ANTHROPIC_DEFAULT_SONNET_MODEL = 'deepseek-v4-flash'/);
  assert.match(script, /ANTHROPIC_DEFAULT_HAIKU_MODEL = 'deepseek-v4-flash'/);
  assert.match(script, /CLAUDE_CODE_SUBAGENT_MODEL = 'deepseek-v4-flash'/);
  assert.match(script, /CLAUDE_CODE_EFFORT_LEVEL = 'max'/);
});

test('integrated launchers pin cwd to the workspace before starting any agent', () => {
  // スタート等 workspace 外のフォルダから起動すると、Claude Code は cwd を
  // CLAUDE_PROJECT_DIR にしてフックを cwd\.ai-safety\... から解決するため、
  // ガード欠落(fail-closed)で全プロンプトがブロックされる(2026-08-03 学校実機)。
  const win = read('scripts/windows/launch-integrated.ps1');
  assert.match(win, /Set-Location -LiteralPath \$Workspace/);
  // Set-Location はエージェント起動(dry-run 分岐含む)より前に置くこと。
  // v1.18.0: メニュー集約で agy / longrun への委譲分岐（dry-run で exit する）が
  // Set-Location より前にできたため、本編の dry-run 分岐（最後の出現）と比べる。
  assert.ok(
    win.indexOf('Set-Location -LiteralPath $Workspace') < win.lastIndexOf('AI_SAFE_DRY_RUN'),
    'Set-Location must run before agents launch');
  const mac = read('scripts/macos/launch-integrated.sh');
  assert.match(mac, /^cd "\$workspace"$/m);
});

// v1.18.0: 個別のセーフ起動ボタン（2_セーフCodex / 3_セーフClaude）は
// 「4_AIを起動する」に集約された。起動経路が統合ランチャー標準モードを
// 通ることは変わらず固定する。
test('Windows start button routes through integrated standard mode', () => {
  // v1.18.0: ボタンはメニューの正本（launch-integrated.ps1 の menu モード）へ委譲する。
  // 選択肢の写しをボタン側に持つと陳腐化する（AntiGravity 無しの旧メニューが残った実績）。
  const menu = read('workspace-template/スタート/4_AIを起動する.bat');
  assert.match(menu, /launch-integrated\.ps1/i);
  assert.match(menu, /-Agent menu -Profile standard/i);

  const script = read('scripts/windows/launch-integrated.ps1');
  assert.match(script, /\$Agent = 'codex'; \$SafetyProfile = 'standard'/);
  assert.match(script, /\$Agent = 'claude'; \$SafetyProfile = 'standard'/);
});

test('Mac and Windows integrated menus expose d-claude as a monitored option', () => {
  const mac = read('scripts/macos/launch-integrated.sh');
  const win = read('scripts/windows/launch-integrated.ps1');
  assert.match(mac, /d-claude.*DeepSeek/i);
  assert.match(mac, /agent="d-claude"; profile="standard"/);
  assert.match(win, /d-claude.*DeepSeek/i);
  assert.match(win, /\$Agent = 'd-claude'; \$SafetyProfile = 'standard'/);
});

test('Windows integrated d-claude dry-run reports monitor and send inspection', (t) => {
  const probe = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()'], { encoding: 'utf8' });
  if (probe.error && probe.error.code === 'ENOENT') {
    t.skip('pwsh is not installed on this host');
    return;
  }
  assert.equal(probe.status, 0, probe.stderr);
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'windows-integrated-d-claude-'));
  const fakeProfile = fs.mkdtempSync(path.join(os.tmpdir(), 'windows-integrated-d-claude-profile-'));
  try {
    const result = spawnSync('pwsh', [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', path.join(root, 'scripts', 'windows', 'launch-integrated.ps1'),
      '-Workspace', workspace,
      '-Agent', 'd-claude',
      '-Profile', 'standard',
    ], {
      env: { ...process.env, USERPROFILE: fakeProfile, AI_SAFE_DRY_RUN: '1' },
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /agent:\s+d-claude/);
    assert.match(result.stdout, /monitor:\s+enabled/);
    assert.match(result.stdout, /127[.]0[.]0[.]1:8788.*send inspection/);
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
    fs.rmSync(fakeProfile, { recursive: true, force: true });
  }
});
