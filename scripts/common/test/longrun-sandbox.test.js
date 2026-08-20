'use strict';
// longrun-sandbox.test.js — 「（上級）15_長時間おまかせモードで起動」の壁（サンドボックス）保証。
//
// このモードは「OS の壁があるから承認を省ける」という前提で作ってある。前提が崩れた状態
// （壁を立ち上げられなかった状態）で走ってはいけない。以前は settings.json の
// `sandbox.enabled === true` という**宣言**しか見ておらず、Seatbelt の起動に失敗しても
// ask 空・acceptEdits のまま壁なしで走り得た（配布前レビューの指摘）。
//
// Claude Code 2.1.236 のバイナリ内文字列で確認した実キー:
//   "Sandbox required but unavailable: "
//   ". Set sandbox.failIfUnavailable=false to allow unsandboxed execution."
// = `sandbox.failIfUnavailable: true` のとき、壁が使えなければ本体側が実行しない。
// 恒久設定には入れず（受講者が通常起動で詰むため）、このモードの一時設定にだけ立てる。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PKG = path.resolve(__dirname, '..', '..', '..');
const SCRIPT = path.join(PKG, 'scripts', 'macos', 'launch-claude-longrun.sh');

test('長時間おまかせモードの実体がある', () => {
  assert.ok(fs.existsSync(SCRIPT));
});

test('恒久設定（configs/claude/settings.mac.json）には failIfUnavailable を入れない', () => {
  const s = JSON.parse(fs.readFileSync(path.join(PKG, 'configs', 'claude', 'settings.mac.json'), 'utf8'));
  assert.ok(s.sandbox, 'sandbox 節が無い');
  assert.strictEqual(s.sandbox.enabled, true);
  assert.strictEqual(
    Object.prototype.hasOwnProperty.call(s.sandbox, 'failIfUnavailable'), false,
    '恒久設定に failIfUnavailable を入れると通常起動で受講者が詰む');
});

// 実測: claude をスタブに差し替えて、渡される一時設定の中身を回収する。
test('一時設定に sandbox.failIfUnavailable=true が立つ（壁が立たなければ起動しない）', { skip: process.platform === 'darwin' ? false : 'macOS 専用のモードのため skip' }, (t) => {
  const base = path.join(os.homedir(), '.sena-tmp');
  fs.mkdirSync(base, { recursive: true });
  const ws = fs.mkdtempSync(path.join(base, 'longrun-ws-'));
  const bin = fs.mkdtempSync(path.join(base, 'longrun-bin-'));
  t.after(() => {
    fs.rmSync(ws, { recursive: true, force: true });
    fs.rmSync(bin, { recursive: true, force: true });
  });

  // 最低限の「導入済み作業フォルダ」を用意する。
  fs.mkdirSync(path.join(ws, '.claude'), { recursive: true });
  fs.mkdirSync(path.join(ws, '.ai-safety', 'policy'), { recursive: true });
  fs.copyFileSync(path.join(PKG, 'configs', 'claude', 'settings.mac.json'),
    path.join(ws, '.claude', 'settings.json'));
  fs.copyFileSync(path.join(PKG, 'policy', 'safety-policy.json'),
    path.join(ws, '.ai-safety', 'policy', 'safety-policy.json'));

  // claude スタブ: --settings で渡された一時設定を丸ごと控える。
  const captured = path.join(ws, 'captured-settings.json');
  fs.writeFileSync(path.join(bin, 'claude'), [
    '#!/usr/bin/env bash',
    'if [ "$1" = "--help" ]; then echo "  --permission-mode <mode>"; exit 0; fi',
    'prev=""',
    'for a in "$@"; do',
    '  if [ "$prev" = "--settings" ]; then cp "$a" ' + JSON.stringify(captured) + '; fi',
    '  prev="$a"',
    'done',
    'exit 0',
  ].join('\n') + '\n', { mode: 0o755 });

  const r = spawnSync('bash', [SCRIPT, ws], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
    encoding: 'utf8',
    input: '\n',
    timeout: 120000,
  });
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  assert.ok(fs.existsSync(captured), '一時設定を回収できなかった:\n' + r.stdout + r.stderr);

  const tmp = JSON.parse(fs.readFileSync(captured, 'utf8'));
  assert.strictEqual(tmp.sandbox.enabled, true);
  assert.strictEqual(tmp.sandbox.autoAllowBashIfSandboxed, true);
  assert.strictEqual(tmp.sandbox.failIfUnavailable, true, '壁の実起動が保証されていない');
  // 併せて、既存の床が緩んでいないことも見る（このモードの前提そのもの）。
  assert.deepStrictEqual(tmp.permissions.ask, [], 'ask は空にする（無人で答えられないため）');
  assert.strictEqual(tmp.permissions.defaultMode, 'acceptEdits');
  assert.strictEqual(tmp.permissions.disableBypassPermissionsMode, 'disable');
  assert.ok(tmp.permissions.deny.length >= 30, 'deny 床が減っている');
});
