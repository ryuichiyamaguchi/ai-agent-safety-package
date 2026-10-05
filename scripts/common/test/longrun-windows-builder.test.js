'use strict';
// 長時間おまかせモードの一時設定づくり（scripts/common/longrun-claude-settings.js）の回帰テスト。
//
// 経緯: launch-longrun.ps1 は以前、設定づくりのプログラムを build-settings.js というファイルに書き出し、
// 「node build-settings.js 元の設定 書き出し先」で実行していた。この形では process.argv[1] がファイル
// 自身になる。v1.17.1〜v1.19.5 は argv[1]・argv[2] を読んでいたため、自分自身を JSON として読んで必ず
// 失敗し、Windows の長時間おまかせモード（Claude）は一度も起動できなかった（2026-10 受講者 PC で判明・
// v1.19.6 で修正）。v1.19.9 で、mac / Windows / d-claude の長時間おまかせモードが使う同じ変換を
// scripts/common/longrun-claude-settings.js にまとめた。ここでは、それを各ランチャーと同じ呼び方
// （ファイルとして実行）で動かして確かめる。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..', '..');
const BUILDER = path.join(root, 'scripts', 'common', 'longrun-claude-settings.js');
const read = (...p) => fs.readFileSync(path.join(root, ...p), 'utf8').replace(/\r\n/g, '\n');

function runBuilder(settingsName, extra = []) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'longrun-builder-'));
  try {
    const input = path.join(dir, 'settings.json');
    const output = path.join(dir, 'out.json');
    const original = JSON.parse(read('configs', 'claude', settingsName));
    // Windows の PowerShell 5.1 が書いた JSON は先頭に BOM が付くことがある。付いていても読めること。
    fs.writeFileSync(input, '\uFEFF' + JSON.stringify(original));
    const r = spawnSync(process.execPath, [BUILDER, input, output, ...extra], { encoding: 'utf8' });
    assert.strictEqual(r.status, 0, 'プログラムが失敗した: ' + r.stderr);
    return { original, out: JSON.parse(fs.readFileSync(output, 'utf8')) };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function assertFloor(original, out) {
  const ask = (original.permissions && original.permissions.ask) || [];
  const deny = (original.permissions && original.permissions.deny) || [];
  assert.deepStrictEqual(out.permissions.ask, [], '確認（ask）は空にする');
  for (const rule of [...deny, ...ask]) {
    assert.ok(out.permissions.deny.includes(rule), `deny に残る／移ること: ${rule}`);
  }
  assert.strictEqual(out.permissions.defaultMode, 'acceptEdits');
  assert.strictEqual(out.permissions.disableBypassPermissionsMode, 'disable', '全許可モードは使わせない');
}

test('Windows の設定から、ファイルとして実行して正しく作れる（壁は足さない）', () => {
  const { original, out } = runBuilder('settings.windows.json');
  assertFloor(original, out);
  assert.ok(!out.sandbox || JSON.stringify(out.sandbox) === JSON.stringify(original.sandbox),
    'Windows では sandbox 節を新しく足さない（宣言だけして守れているように見せない）');
});

test('mac の設定に --wall を付けると、壁を必須にする（failIfUnavailable）', () => {
  const { original, out } = runBuilder('settings.mac.json', ['--wall']);
  assertFloor(original, out);
  assert.strictEqual(out.sandbox.enabled, true);
  assert.strictEqual(out.sandbox.autoAllowBashIfSandboxed, true);
  assert.strictEqual(out.sandbox.failIfUnavailable, true, '壁の実起動が保証されていない');
});

test('--bypass（d-claude の長時間おまかせモード）: 全承認の封印を外し、壁の外での実行し直しは禁止', () => {
  const { original, out } = runBuilder('settings.mac.json', ['--wall', '--bypass']);
  const deny = (original.permissions && original.permissions.deny) || [];
  for (const rule of deny) assert.ok(out.permissions.deny.includes(rule), `deny に残ること: ${rule}`);
  assert.deepStrictEqual(out.permissions.ask, []);
  assert.strictEqual(out.permissions.defaultMode, 'bypassPermissions');
  assert.ok(!('disableBypassPermissionsMode' in out.permissions));
  assert.strictEqual(out.sandbox.failIfUnavailable, true);
  assert.strictEqual(out.sandbox.allowUnsandboxedCommands, false);
  assert.deepStrictEqual(out.hooks, original.hooks, 'ガード（フック）はそのまま');
});

test('引数は「元の設定 書き出し先」の 2 つを読む（argv[1] はファイル自身）', () => {
  const src = read('scripts', 'common', 'longrun-claude-settings.js');
  assert.match(src, /process\.argv\.slice\(2\)/);
  assert.doesNotMatch(src, /process\.argv\[1\]/);
});

test('ランチャーは共通の変換を使い、同じ変換を中に書き直していない', () => {
  const ps1 = read('scripts', 'windows', 'launch-longrun.ps1');
  const sh = read('scripts', 'macos', 'launch-longrun.sh');
  assert.match(ps1, /longrun-claude-settings\.js/);
  assert.match(ps1, /& \$node\.Source \$lrBuilder \$claudeSettings \$tmpSettings/, 'Windows: ファイルとして実行する呼び方');
  assert.doesNotMatch(ps1, /\$builder = @'/, 'Windows: 変換を中に書いたヒア文字列が残っている');
  assert.match(sh, /longrun-claude-settings\.js/);
  assert.doesNotMatch(sh, /p\.defaultMode = "acceptEdits"/, 'mac: 変換を中に書いたものが残っている');
  // d-claude の長時間おまかせモード（launch-claude-safe の --longrun / -LongRun）も同じ変換を使う。
  assert.match(read('scripts', 'windows', 'launch-claude-safe.ps1'), /longrun-claude-settings\.js/);
  assert.match(read('scripts', 'macos', 'launch-claude-safe.sh'), /longrun-claude-settings\.js/);
});
