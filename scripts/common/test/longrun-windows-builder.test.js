'use strict';
// Windows の長時間おまかせモード（launch-longrun.ps1）が作る一時設定の回帰テスト。
//
// launch-longrun.ps1 は設定づくりのプログラムを build-settings.js というファイルに書き出し、
// 「node build-settings.js 元の設定 書き出し先」で実行する。この形では process.argv[1] が
// ファイル自身になる。v1.17.1〜v1.19.5 は argv[1]・argv[2] を読んでいたため、自分自身を JSON と
// して読んで必ず失敗し、Windows の長時間おまかせモード（Claude）は一度も起動できなかった
// （2026-10 受講者 PC で判明）。ここでは .ps1 からプログラムを取り出し、Windows と同じ形で実行する。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..', '..');
const ps1 = fs.readFileSync(path.join(root, 'scripts', 'windows', 'launch-longrun.ps1'), 'utf8').replace(/\r\n/g, '\n');

function builderSource() {
  const m = ps1.match(/\$builder = @'\n([\s\S]*?)\n'@/);
  assert.ok(m, 'launch-longrun.ps1 に $builder のヒア文字列があること');
  return m[1];
}

test('Windows の長時間おまかせモード: 設定づくりのプログラムをファイルとして実行して、正しく作れる', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'longrun-builder-'));
  try {
    const builder = path.join(dir, 'build-settings.js');
    fs.writeFileSync(builder, builderSource());
    const input = path.join(dir, 'settings.windows.json');
    const output = path.join(dir, 'out.json');
    const original = JSON.parse(fs.readFileSync(path.join(root, 'configs', 'claude', 'settings.windows.json'), 'utf8'));
    fs.writeFileSync(input, JSON.stringify(original));

    // launch-longrun.ps1 と同じ呼び方: & node build-settings.js 元の設定 書き出し先
    const r = spawnSync(process.execPath, [builder, input, output], { encoding: 'utf8' });
    assert.strictEqual(r.status, 0, 'プログラムが失敗した: ' + r.stderr);
    const out = JSON.parse(fs.readFileSync(output, 'utf8'));

    const ask = (original.permissions && original.permissions.ask) || [];
    const deny = (original.permissions && original.permissions.deny) || [];
    assert.deepStrictEqual(out.permissions.ask, [], '確認（ask）は空にする');
    for (const rule of [...deny, ...ask]) {
      assert.ok(out.permissions.deny.includes(rule), `deny に残る／移ること: ${rule}`);
    }
    assert.strictEqual(out.permissions.defaultMode, 'acceptEdits');
    assert.strictEqual(out.permissions.disableBypassPermissionsMode, 'disable', '全許可モードは使わせない');
    assert.ok(!out.sandbox || out.sandbox === original.sandbox, 'Windows では sandbox 節を新しく足さない');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('Windows の長時間おまかせモード: プログラムは argv[2]・argv[3] を読む（argv[1] はファイル自身）', () => {
  const src = builderSource();
  assert.match(src, /process\.argv\[2\]/);
  assert.match(src, /process\.argv\[3\]/);
  assert.doesNotMatch(src, /process\.argv\[1\]/);
  assert.match(ps1, /& \$node\.Source \$builderFile \$claudeSettings \$tmpSettings/, '呼び方（ファイルとして実行）と読む番号が合っていること');
});
