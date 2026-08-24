'use strict';

// 「最新版に更新」を押した受講者が、固定の公式 Release 資産を検証して導入し、
// 最後に実際に入った版まで確認できることを固定する。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..', '..');

function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}

test('Mac and Windows updaters use the same fixed official Release asset pair', () => {
  const mac = read('scripts/macos/fetch-update.command');
  const win = read('scripts/windows/fetch-update.ps1');

  for (const [name, script] of [['mac', mac], ['win', win]]) {
    assert.match(script, /ryuichiyamaguchi\/ai-agent-safety-package/, `${name}: 公式リポジトリが固定されていない`);
    assert.match(script, /releases\/latest\/download/, `${name}: latest Release を取得していない`);
    assert.match(script, /ai-agent-safety-package\.zip/, `${name}: 固定名 ZIP を取得していない`);
    assert.match(script, /\.sha256/, `${name}: チェックサム資産を取得していない`);
  }
});

test('both updaters verify the checksum before running the installer', () => {
  const mac = read('scripts/macos/fetch-update.command');
  const win = read('scripts/windows/fetch-update.ps1');

  assert.ok(mac.indexOf('expected=') < mac.indexOf('bash "$installer"'), 'mac: SHA照合より先にinstallerを実行している');
  assert.ok(win.indexOf('$expected =') < win.indexOf('& powershell'), 'win: SHA照合より先にinstallerを実行している');
});

test('both updaters report the package version actually installed into the workspace', () => {
  const mac = read('scripts/macos/fetch-update.command');
  const win = read('scripts/windows/fetch-update.ps1');

  assert.match(mac, /\.ai-safety\/policy\/safety-policy\.json/);
  assert.match(mac, /更新された版/);
  assert.match(mac, /\[ "\$installed_version" = "\$package_version" \]/);
  assert.match(win, /\.ai-safety\\policy\\safety-policy\.json/);
  assert.match(win, /更新された版/);
  assert.match(win, /\$installedVersion -ne \$packageVersion/);
});

test('the learner-facing update buttons invoke the updater installed in that workspace', () => {
  const mac = read('workspace-template/スタート/1_安全パッケージを最新版にする.command');
  const win = read('workspace-template/スタート/1_安全パッケージを最新版にする.bat');

  assert.match(mac, /\.ai-safety\/hooks\/macos\/fetch-update\.command/);
  assert.match(win, /\.ai-safety\\hooks\\windows\\fetch-update\.ps1/);
});
