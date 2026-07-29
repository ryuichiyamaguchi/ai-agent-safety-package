'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..', '..');

function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}

test('macOS OpenCode launcher enforces config after project config and requires gateway health', () => {
  const script = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  assert.match(script, /OPENCODE_CONFIG_CONTENT/);
  assert.match(script, /OPENCODE_DISABLE_PROJECT_CONFIG/);
  assert.match(script, /OPENCODE_PURE/);
  assert.match(script, /opencode-config\.js/);
  assert.match(script, /DS_GATEWAY_AUTH_FILE/);
  assert.match(script, /api\.deepseek\.com/);
  assert.match(script, /\/healthz/);
  assert.match(script, /1\.14\.24/);
  assert.match(script, /unset OPENCODE_ENABLE_EXA/);
  assert.match(script, /AI_SAFE_DRY_RUN/);
});

test('Windows OpenCode launcher provides the same fail-closed controls', () => {
  const script = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');
  assert.match(script, /OPENCODE_CONFIG_CONTENT/);
  assert.match(script, /OPENCODE_DISABLE_PROJECT_CONFIG/);
  assert.match(script, /OPENCODE_PURE/);
  assert.match(script, /opencode-config\.js/);
  assert.match(script, /DS_GATEWAY_AUTH_FILE/);
  assert.match(script, /api\.deepseek\.com/);
  assert.match(script, /\/healthz/);
  assert.match(script, /1\.14\.24/);
  assert.match(script, /OPENCODE_ENABLE_EXA/);
  assert.match(script, /AI_SAFE_DRY_RUN/);
});

// OpenCode 統合ランチャーは OPENCODE_DISABLE_PROJECT_CONFIG=1 で起動するため、
// プロジェクトの .opencode/ はスキャンされない（プローブスキルで実測）。スキルの配布先は
// .ai-safety/dist-skills →（起動時に）$XDG_CONFIG_HOME/opencode/skills/ へ一本化した。
test('Mac and Windows installers place Bouncer and the OpenCode skill source', () => {
  const mac = read('scripts/macos/install.sh');
  const win = read('scripts/windows/install.ps1');

  assert.match(mac, /bouncer-gateway/);
  assert.match(mac, /\.ai-safety\/dist-skills/);
  assert.match(mac, /AGENTS\.md/);
  assert.match(win, /bouncer-gateway/);
  assert.match(win, /\.ai-safety\\dist-skills/);
  assert.match(win, /AGENTS\.md/);
});

// --- 回帰: 環境変数で強制設定を丸ごと無効化される穴 ------------------------------
// OPENCODE_PERMISSION / OPENCODE_TEST_MANAGED_CONFIG_DIR は OPENCODE_CONFIG_CONTENT より
// 後にマージされるため、消したうえで安全な値を入れ直すところまでやらないと塞がらない。
test('both launchers strip the environment variables that can disable the forced config', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  assert.match(mac, /unset OPENCODE_PERMISSION OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_TEST_MANAGED_CONFIG_DIR/);
  assert.match(win, /Remove-Item Env:\\OPENCODE_PERMISSION, Env:\\OPENCODE_CONFIG, Env:\\OPENCODE_CONFIG_DIR, Env:\\OPENCODE_TEST_MANAGED_CONFIG_DIR/);
});

test('both launchers re-assert the deny floor through OPENCODE_PERMISSION', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  assert.match(mac, /--print-permission-env/);
  assert.match(mac, /export OPENCODE_PERMISSION/);
  assert.match(win, /--print-permission-env/);
  assert.match(win, /\$env:OPENCODE_PERMISSION = \$enforced/);
});

// --- 配線が消えていないことの確認 ------------------------------------------------
// 以下はソース上の配線しか見ていない（「本体が起動しないこと」の実動作検証は
// opencode-launcher-runtime.test.js が偽 opencode を使って行う）。
test('both launchers keep the syntax check on the safety plugin wired up', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  assert.match(mac, /node --check "\$MONITOR_PLUGIN"/);
  assert.match(mac, /fail-closed/);
  assert.match(win, /--check \$monitorPlugin/);
  assert.match(win, /fail-closed/);
});

test('both launchers keep the resolved-config check, the ready gate and the watchdog wired up', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  for (const script of [mac, win]) {
    assert.match(script, /debug config/);
    assert.match(script, /--verify-resolved/);
    // 本体を出す前の同期確認（プラグインが実際に載ったか）。
    assert.match(script, /--verify-ready/);
    assert.match(script, /BOUNCER_READY_OK/);
    assert.match(script, /--watchdog/);
    assert.match(script, /opencode-monitor-ready\.json/);
    // 秘密の環境変数とポリシー差し替え変数の消去。
    assert.match(script, /--print-secret-env/);
    assert.match(script, /AI_SAFE_POLICY/);
  }
});

test('both launchers preserve a redacted diagnostic when resolved config parsing fails', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  for (const script of [mac, win]) {
    assert.match(script, /opencode-resolved-config\.failed\.txt/);
    assert.match(script, /REDACTED/);
    assert.match(script, /診断ファイル/);
  }
});

// 「毎回消して置き直す」方式が消すファイル名の一覧。opencode 1.18.4 は設定ディレクトリ直下の
// config.json も設定として読む（実機確認）ので、ここに任意のプラグインや MCP を書かれると
// 起動時に実行される。opencode.json5 / .opencoderc / config.jsonc は読まないので対象外。
test('both launchers wipe config.json as well as the opencode.json family', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  for (const name of ['AGENTS.md', 'opencode.json', 'opencode.jsonc', 'config.json']) {
    assert.ok(mac.includes(`"$OC_CONFIG_DIR/${name}"`), `mac のランチャーが ${name} を消していない`);
    assert.ok(win.includes(`'${name}'`), `Windows のランチャーが ${name} を消していない`);
  }
});

test('both launchers reject an empty generated config', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  assert.match(mac, /\[ -n "\$OPENCODE_CONFIG_CONTENT" \]/);
  assert.match(win, /-not \$env:OPENCODE_CONFIG_CONTENT/);
});

test('the Windows launcher reads the version defensively and cleans up its gateway port', () => {
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  assert.doesNotMatch(win, /\| Select-Object -First 1\)\.Trim\(\)/, 'null に .Trim() を呼ぶと不親切な英語例外になる');
  assert.match(win, /\$null -eq \$versionRaw/);
  assert.match(win, /Remove-Item Env:\\OPENCODE_PERMISSION, Env:\\DS_GATEWAY_PORT/);
});

test('the macOS launcher keeps LF endings and the Windows launcher keeps UTF-8 BOM + CRLF', () => {
  const mac = fs.readFileSync(path.join(root, 'scripts/macos/opencode/launch-opencode-deepseek.sh'));
  const win = fs.readFileSync(path.join(root, 'scripts/windows/opencode/launch-opencode-deepseek.ps1'));

  assert.ok(!mac.includes('\r'), 'sh に CR が混ざっている');
  assert.deepStrictEqual([...win.subarray(0, 3)], [0xef, 0xbb, 0xbf], 'ps1 の UTF-8 BOM が失われている');
  const lf = [...win].filter((byte) => byte === 0x0a).length;
  const crlf = win.toString('binary').split('\r\n').length - 1;
  assert.strictEqual(lf, crlf, 'ps1 に CRLF でない改行が混ざっている');
});

test('legacy d-claude launchers remain present as an advanced compatibility route', () => {
  assert.ok(fs.existsSync(path.join(root, 'scripts/macos/deepseek/launch-deepseek-gateway.sh')));
  assert.ok(fs.existsSync(path.join(root, 'scripts/windows/deepseek/launch-deepseek-gateway.ps1')));
  assert.ok(fs.existsSync(path.join(root, 'workspace-template/d-claude.cmd')));
});
