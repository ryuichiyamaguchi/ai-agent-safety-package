'use strict';
// ダウンロード検疫（com.apple.quarantine）の解除に対する回帰テスト。
//
// 守りたいこと:
//   ZIP をブラウザで受け取ると中身すべてに検疫属性が付き、それはコピーで引き継がれる。
//   そのため install が配置したボタン（スタート/*.command）を押すたびに
//   「開発元を検証できません」で止まり、しかも更新のたびに再発していた。
//   install は自分が配置した配布物に限って検疫を外す。ここが壊れると再発する。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..', '..');
const INSTALL_SH = path.join(root, 'scripts', 'macos', 'install.sh');

function hasQuarantine(file) {
  const r = spawnSync('xattr', ['-p', 'com.apple.quarantine', file], { encoding: 'utf8' });
  return r.status === 0 && !!String(r.stdout || '').trim();
}

test('install は「更新のたびに検疫が戻る」を起こさない', { skip: process.platform !== 'darwin' }, (t) => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'inst-quarantine-'));
  t.after(() => fs.rmSync(workspace, { recursive: true, force: true }));

  // install は HOME 配下（~/.ai-safety/bin と ~/.zshrc）も書き換える。テストで実 HOME を
  // 汚すと、利用者の oc-safe に検証用パスが焼き込まれる事故になる（実際に起こした）。
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'inst-quarantine-home-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const env = { ...process.env, HOME: home };
  const first = spawnSync('bash', [INSTALL_SH, workspace], { env, encoding: 'utf8' });
  assert.strictEqual(first.status, 0, `install(1回目) が失敗: ${first.stdout}\n${first.stderr}`);

  const button = path.join(workspace, 'スタート', '0_Bouncer統合版を起動.command');
  const hook = path.join(workspace, '.ai-safety', 'hooks', 'macos', 'doctor.sh');
  assert.ok(fs.existsSync(button), 'スタートのボタンが配置されること');
  assert.ok(fs.existsSync(hook), 'ガード本体が配置されること');

  // ブラウザ経由で配られた状態を作る（ZIP から展開した直後と同じ）。
  for (const f of [button, hook]) {
    const w = spawnSync('xattr', ['-w', 'com.apple.quarantine', '0081;00000000;Chrome;TESTTEST', f]);
    assert.strictEqual(w.status, 0, `検疫属性を付けられること: ${f}`);
    assert.ok(hasQuarantine(f), `前提として検疫が付いていること: ${f}`);
  }

  // 「6_最新版に更新」に相当する再インストール。
  const second = spawnSync('bash', [INSTALL_SH, workspace], { env, encoding: 'utf8' });
  assert.strictEqual(second.status, 0, `install(2回目) が失敗: ${second.stdout}\n${second.stderr}`);

  assert.ok(!hasQuarantine(button), '更新後、ボタンに検疫が残ってはいけない（毎回ブロックされる原因）');
  assert.ok(!hasQuarantine(hook), '更新後、ガード本体にも検疫を残さない');
});

test('検疫を外す対象は install が配置した場所だけに限る', () => {
  const script = fs.readFileSync(INSTALL_SH, 'utf8');
  assert.match(script, /xattr -dr com\.apple\.quarantine/, '検疫解除を行うこと');
  // 対象は .ai-safety と スタート の 2 か所のみ。ワークスペース全体や $HOME を
  // 対象にすると、受講者が自分で持ち込んだファイルの検疫まで外れてしまう。
  assert.match(script, /for _q in "\$workspace\/\.ai-safety" "\$workspace\/スタート"/,
    '対象は配置済みの配布物 2 か所に限定すること');
  assert.ok(!/xattr -dr com\.apple\.quarantine "\$workspace"\s*$/m.test(script),
    'ワークスペース全体を対象にしてはいけない');
  assert.ok(!/xattr -dr com\.apple\.quarantine "\$HOME"/.test(script),
    'ホーム全体を対象にしてはいけない');
});
