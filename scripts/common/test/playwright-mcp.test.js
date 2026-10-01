'use strict';
// Playwright（ブラウザ自動操作・UIテスト）を OpenCode から使えるようにするローカル MCP の回帰テスト。
//
// ここで守りたいこと:
//   1. Playwright MCP (@playwright/mcp) が local MCP として登録される
//   2. ブラウザ操作・外部アクセスを伴うため、権限は必ず ask になる
//   3. AI_SAFE_DCLAUDE_PLAYWRIGHT=0 で個別に無効化できる
//   4. 設定全体の生成・起動前検証（verifyResolvedConfig）と整合している
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('node:path');

const root = path.join(__dirname, '..', '..', '..');
const { buildMcpConfig, buildOpenCodeConfig, verifyResolvedConfig } = require(path.join(root, 'scripts', 'common', 'opencode-config.js'));

test('Playwright MCP はデフォルトで local MCP として登録され、権限は ask になる', () => {
  const mcpDir = path.join(root, 'scripts', 'common');
  const { mcp, permission } = buildMcpConfig({ mcpDir, env: {} });
  assert.ok(mcp.playwright, 'Playwright MCP が登録されていること');
  assert.strictEqual(mcp.playwright.type, 'local');
  assert.deepStrictEqual(mcp.playwright.command, ['node', path.join(mcpDir, 'playwright-mcp.js')]);
  assert.strictEqual(mcp.playwright.enabled, true);
  assert.strictEqual(mcp.playwright.timeout, 90000);
  assert.strictEqual(permission['playwright_*'], 'ask', 'ブラウザ操作は安全のため ask であること');
});

test('AI_SAFE_DCLAUDE_PLAYWRIGHT=0 で無効化できる', () => {
  const { mcp, permission } = buildMcpConfig({
    mcpDir: path.join(root, 'scripts', 'common'),
    env: { AI_SAFE_DCLAUDE_PLAYWRIGHT: '0' },
  });
  assert.ok(!mcp.playwright, '無効化フラグが効くこと');
  assert.ok(!permission['playwright_*'], '権限も登録されないこと');
});

test('buildOpenCodeConfig で Playwright MCP が含まれ、解決済み検証を通過する', () => {
  const config = buildOpenCodeConfig({
    port: 8788,
    gatewayToken: 'test-token-12345678901234567890123456789012',
    mcpDir: path.join(root, 'scripts', 'common'),
    monitorPlugin: path.join(root, 'scripts', 'common', 'opencode-bouncer-monitor.mjs'),
  });

  assert.ok(config.mcp.playwright, 'OpenCode 設定に Playwright MCP が載っていること');
  assert.strictEqual(config.permission['playwright_*'], 'ask');
  const problems = verifyResolvedConfig(config);
  assert.deepStrictEqual(problems, [], '検証で問題が報告されないこと');
});

// ---------------------------------------------------------------------------
// 起動時にダウンロードしない（教室一斉起動の時間切れ対策・2026-10）
//   5. 事前に入れた版（~/.ai-safety/tools/playwright-mcp）があれば node で直接起動する
//   6. 無ければ「版を固定した」npx で起動する（--prefer-offline で毎回の問い合わせを避ける）
//   7. 版ちがい・壊れた事前導入は使わない
//   8. Windows で Chrome が無いときだけ Edge を使う
// ---------------------------------------------------------------------------
const fs = require('node:fs');
const os = require('node:os');
const pw = require(path.join(root, 'scripts', 'common', 'playwright-mcp.js'));
const commonDir = path.join(root, 'scripts', 'common');

function fakeHome(version, { withCli = true } = {}) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'pw-home-'));
  if (version) {
    const pkgDir = path.join(pw.toolsDir(home), 'node_modules', '@playwright', 'mcp');
    fs.mkdirSync(pkgDir, { recursive: true });
    fs.writeFileSync(path.join(pkgDir, 'package.json'), JSON.stringify({ name: '@playwright/mcp', version }));
    if (withCli) fs.writeFileSync(path.join(pkgDir, 'cli.js'), '');
  }
  return home;
}

test('固定版は tested-tool-versions.json の playwrightMcp から読む', () => {
  const json = JSON.parse(fs.readFileSync(path.join(root, 'configs', 'tested-tool-versions.json'), 'utf8'));
  assert.ok(json.playwrightMcp, 'playwrightMcp が SSOT に書かれていること');
  assert.strictEqual(pw.pinnedVersion(commonDir), json.playwrightMcp);
});

test('事前に入れた版があれば、ネットワークを使わず node で直接起動する', () => {
  const v = pw.pinnedVersion(commonDir);
  const home = fakeHome(v);
  const p = pw.plan({ home, dir: commonDir, platform: 'darwin', env: {} });
  assert.strictEqual(p.mode, 'local');
  assert.strictEqual(p.command, process.execPath);
  assert.strictEqual(p.args[0], path.join(pw.toolsDir(home), 'node_modules', '@playwright', 'mcp', 'cli.js'));
  assert.ok(!p.args.includes('-y'), 'npx を使わないこと');
});

test('事前導入が無ければ、版を固定した npx（--prefer-offline）で起動する', () => {
  const v = pw.pinnedVersion(commonDir);
  const home = fakeHome(null);
  const p = pw.plan({ home, dir: commonDir, platform: 'darwin', env: {} });
  assert.strictEqual(p.mode, 'npx');
  assert.deepStrictEqual(p.args.slice(0, 3), ['--prefer-offline', '-y', `@playwright/mcp@${v}`]);
  assert.ok(!p.args.includes('@playwright/mcp'), '版なし（毎回最新を問い合わせる）指定を使わないこと');
});

test('版ちがい・cli.js の無い（途中で失敗した）事前導入は使わない', () => {
  const v = pw.pinnedVersion(commonDir);
  assert.strictEqual(pw.plan({ home: fakeHome('0.0.1'), dir: commonDir, platform: 'darwin', env: {} }).mode, 'npx');
  assert.strictEqual(pw.plan({ home: fakeHome(v, { withCli: false }), dir: commonDir, platform: 'darwin', env: {} }).mode, 'npx');
});

test('Windows で Chrome が無いときだけ Edge を使う（指定があればそれを優先）', () => {
  assert.deepStrictEqual(pw.browserArgs([], { platform: 'win32', env: {}, hasChrome: false }), ['--browser', 'msedge']);
  assert.deepStrictEqual(pw.browserArgs([], { platform: 'win32', env: {}, hasChrome: true }), []);
  assert.deepStrictEqual(pw.browserArgs(['--browser', 'firefox'], { platform: 'win32', env: {}, hasChrome: false }), []);
  assert.deepStrictEqual(pw.browserArgs([], { platform: 'win32', env: { PLAYWRIGHT_MCP_BROWSER: 'chrome' }, hasChrome: false }), []);
  assert.deepStrictEqual(pw.browserArgs([], { platform: 'darwin', env: {}, hasChrome: false }), []);
  const p = pw.plan({ home: fakeHome(null), dir: commonDir, platform: 'win32', env: {}, hasChrome: false });
  assert.strictEqual(p.command, 'npx.cmd');
  assert.ok(p.args.join(' ').includes('--browser msedge'));
});

test('「AIツールをまとめて入れる」4 本すべてが Playwright を事前に入れる', () => {
  const files = [
    '0_AIツールをまとめて入れる-Mac.command',
    'scripts/macos/update-ai-tools.sh',
    'scripts/windows/update-ai-tools.ps1',
  ];
  for (const f of files) {
    assert.ok(fs.readFileSync(path.join(root, f), 'utf8').includes('playwright-prefetch.js'), `${f} が prefetch を呼ぶこと`);
  }
  const bat = fs.readFileSync(path.join(root, '0_AIツールをまとめて入れる-Windows.bat'));
  assert.ok(bat.includes(Buffer.from('playwright-prefetch.js')), 'Windows の .bat も prefetch を呼ぶこと');
  // .bat は教室PC の文字化けを避けるため CP932 のまま（UTF-8 の BOM が付いていないこと）
  assert.ok(!(bat[0] === 0xef && bat[1] === 0xbb && bat[2] === 0xbf));
});

test('d-claude は MCP の起動待ちを延ばす（利用者の指定は優先）', () => {
  const sh = fs.readFileSync(path.join(root, 'scripts', 'macos', 'launch-claude-safe.sh'), 'utf8');
  assert.ok(sh.includes('export MCP_TIMEOUT="${MCP_TIMEOUT:-90000}"'));
  const ps = fs.readFileSync(path.join(root, 'scripts', 'windows', 'launch-claude-safe.ps1'));
  assert.ok(ps[0] === 0xef && ps[1] === 0xbb && ps[2] === 0xbf, 'launch-claude-safe.ps1 の BOM を保つこと');
  assert.ok(ps.toString('utf8').includes("if (-not $env:MCP_TIMEOUT) { $env:MCP_TIMEOUT = '90000' }"));
});
