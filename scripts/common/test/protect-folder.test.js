'use strict';
// protect-folder.test.js — 「新しい作業フォルダを安全にする」(上級14) の危険な選択の拒否を検査する。
//
// このボタンは受講者が任意のフォルダを指定できる。ホーム直下やシステムフォルダを選ばれると、
// 「AI が守るべきもの」と「作業対象」の区別が消えて保護そのものが無意味になる。しかも
// install は既存ファイルを触るので、選択の誤りは実害になる。だから **install を呼ぶ前に**
// 止まることを実測する（ここが抜けると、危険な選択がそのまま install まで通る）。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PKG = path.resolve(__dirname, '..', '..', '..');

// 危険判定を通過したフォルダには install まで走りうる。install は HOME 配下
// （~/.ai-safety/bin の起動コマンド・~/.zshrc・~/.claude.json）を書き換えるので、通過しうる
// テストは必ず使い捨ての HOME で動かす（2026-10-02、このテストが利用者の oc-safe などに
// 検証用フォルダを焼き込んでいた。install.sh を直接起動する呼び出しだけを見張る
// oc-safe.test.js の検査では、protect-folder.sh 経由の install に気づけなかった）。
function makeFakeHome() {
  // macOS の tmpdir は /private/var 配下で「システムフォルダ」扱いになるため、実 HOME の
  // ~/.cache の下に作る（受講者が実際に使う「ホームの中の普通のフォルダ」に近い場所）。
  const base = path.join(os.homedir(), '.cache');
  fs.mkdirSync(base, { recursive: true });
  return fs.mkdtempSync(path.join(base, 'asp-protect-folder-home-'));
}

// 実 HOME の ~/.ai-safety/bin（起動コマンドの置き場）を読み込み時点で記録しておき、
// 最後のテストで「変わっていない」ことを確かめる。
const REAL_BIN = path.join(os.homedir(), '.ai-safety', 'bin');
function snapshotBin() {
  const out = {};
  try {
    for (const n of fs.readdirSync(REAL_BIN)) out[n] = fs.readFileSync(path.join(REAL_BIN, n), 'utf8');
  } catch { /* 置き場が無い環境 */ }
  return out;
}
const REAL_BIN_BEFORE = snapshotBin();
const SCRIPT = path.join(PKG, 'scripts', 'macos', 'protect-folder.sh');

function run(target, extraEnv = {}) {
  // AI_SAFE_ASSUME_YES=1 で確認プロンプトは飛ばす。危険判定は確認より前にあるので、
  // 「y を押したら通ってしまう」形になっていないこともここで確認できる。
  const r = spawnSync('bash', [SCRIPT, target], {
    env: { ...process.env, AI_SAFE_ASSUME_YES: '1', ...extraEnv },
    encoding: 'utf8',
    timeout: 60000,
  });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}

test('protect-folder.sh が存在して実行できる', () => {
  assert.ok(fs.existsSync(SCRIPT), SCRIPT + ' がない');
});

test('危険な場所は install を呼ぶ前に拒否される', () => {
  const home = process.env.HOME;
  const cases = [
    ['/', 'ディスク全体'],
    [home, 'ホームフォルダそのもの'],
    [path.join(home, 'Documents'), 'ホーム直下の大箱'],
    [path.join(home, 'Desktop'), 'ホーム直下の大箱'],
    ['/System', 'システムフォルダ'],
    ['/Library', 'システムフォルダ'],
    ['/usr', 'システムフォルダ'],
    ['/Users', '全ユーザー'],
    [PKG, 'パッケージ自身'],
    [path.join(PKG, 'scripts'), 'パッケージの中'],
  ];
  for (const [target, why] of cases) {
    if (!fs.existsSync(target)) continue;
    const r = run(target);
    assert.strictEqual(r.code, 1, `${why} (${target}) が拒否されなかった:\n${r.out}`);
    assert.match(r.out, /対象にできません/, `${target} の拒否理由が出ていない`);
    // install が走っていないこと（install は必ずこの文字列を出す）
    assert.ok(!r.out.includes('Next: .ai-safety'), `${target} で install が走った`);
  }
});

test('存在しないフォルダはエラーになる', () => {
  const missing = path.join(os.tmpdir(), 'ai-safety-no-such-folder-' + Date.now());
  const r = run(missing);
    assert.strictEqual(r.code, 2, r.out);
  assert.match(r.out, /フォルダが見つかりません/);
});

test('普通の空フォルダは危険判定を通過する（install の直前まで進む）', () => {
  // macOS の tmpdir は /private/var 配下 = システムフォルダ扱いになるので、
  // 受講者が実際に作る場所（ホームの中の普通のフォルダ）で試す。
  const home = makeFakeHome();
  try {
    const base = path.join(home, '.sena-tmp');
    fs.mkdirSync(base, { recursive: true });
    const dir = fs.mkdtempSync(path.join(base, 'ai-safety-newfolder-'));
    // AI_SAFE_PACKAGE_ROOT をわざと壊しても、パッケージが自分の置き場から見つかる環境では
    // install まで走る。だから HOME を使い捨てにして、書き換えはその中に閉じ込める。
    const r = spawnSync('bash', [SCRIPT, dir], {
      env: { ...process.env, HOME: home, AI_SAFE_ASSUME_YES: '1', AI_SAFE_PACKAGE_ROOT: '/nonexistent-package' },
      encoding: 'utf8',
      timeout: 60000,
      cwd: os.tmpdir(),
    });
    const out = (r.stdout || '') + (r.stderr || '');
    // パッケージがパスで見つかる環境では 0（install 成功）、そうでなければ 2（案内して中止）。
    // どちらでも「対象にできません」は出てはいけない。
    assert.ok(!out.includes('対象にできません'), '普通のフォルダが危険扱いされた:\n' + out);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// v1.17.0 回帰: 拒否リストの穴（配布前レビューで実測された受理）
//   ・/Volumes/<ボリューム名>  = マウントされたディスク全体（起動ディスクを含む）
//   ・/tmp/<サブフォルダ>       = 一時領域（再起動で消える／サンドボックスが常に書き込みを許す）
// ---------------------------------------------------------------------------

test('マウントされたディスク全体は拒否される', (t) => {
  // /Volumes 直下の実在するボリュームを 1 つ選ぶ（起動ディスクを含む）。
  let vols = [];
  try { vols = fs.readdirSync('/Volumes'); } catch { vols = []; }
  const target = vols.map((v) => path.join('/Volumes', v))
    .find((p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } });
  if (!target) { t.skip('/Volumes 直下にボリュームが無い環境のため skip'); return; }
  const r = run(target);
  assert.strictEqual(r.code, 1, `${target} が拒否されなかった:\n${r.out}`);
  assert.match(r.out, /対象にできません/);
  assert.ok(!r.out.includes('Next: .ai-safety'), `${target} で install が走った`);
});

test('一時領域（/tmp 配下・/private/tmp 配下）は拒否される', () => {
  const made = [];
  const targets = [];
  for (const base of ['/tmp', '/private/tmp', '/var/tmp']) {
    const dir = path.join(base, 'ai-safety-protect-probe-' + process.pid);
    try { fs.mkdirSync(dir, { recursive: true }); made.push(dir); targets.push(dir); } catch { /* 作れなければ試さない */ }
  }
  // ちょうど一致（/tmp 自体）も拒否のままであること。
  targets.push('/tmp');
  try {
    for (const target of targets) {
      const r = run(target);
      assert.strictEqual(r.code, 1, `${target} が拒否されなかった:\n${r.out}`);
      assert.match(r.out, /対象にできません/, `${target} の拒否理由が出ていない`);
      assert.ok(!r.out.includes('Next: .ai-safety'), `${target} で install が走った`);
      // .ai-safety が作られていないこと（実測でここまで進んでいた）。
      if (target !== '/tmp') assert.ok(!fs.existsSync(path.join(target, '.ai-safety')), `${target} に .ai-safety が作られた`);
    }
  } finally {
    for (const d of made) fs.rmSync(d, { recursive: true, force: true });
  }
});

test('確認を取れない実行方法（端末でない標準入力）では中止する', () => {
  const home = makeFakeHome();
  const base = path.join(home, '.sena-tmp');
  fs.mkdirSync(base, { recursive: true });
  const dir = fs.mkdtempSync(path.join(base, 'ai-safety-notty-'));
  try {
    // AI_SAFE_ASSUME_YES を付けない = 明示の同意が無い。stdin はパイプ（端末ではない）。
    // 万一確認を素通りしても install が利用者の HOME を書かないよう、HOME も使い捨てにする。
    const r = spawnSync('bash', [SCRIPT, dir], {
      env: { ...process.env, HOME: home, AI_SAFE_ASSUME_YES: '0' },
      encoding: 'utf8',
      input: '',
      timeout: 60000,
    });
    const out = (r.stdout || '') + (r.stderr || '');
    assert.strictEqual(r.status, 1, '確認なしで進んだ:\n' + out);
    assert.match(out, /中止しました（確認を取れない実行方法です）/);
    assert.ok(!fs.existsSync(path.join(dir, '.ai-safety')), '確認なしで install が走った');
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test('Windows 版も一時領域とドライブ直下を拒否する', () => {
  const ps1 = fs.readFileSync(path.join(PKG, 'scripts', 'windows', 'protect-folder.ps1'), 'utf8');
  assert.match(ps1, /\^\[A-Za-z\]:\$/, 'ドライブ直下の判定が無い');
  assert.match(ps1, /\$env:TEMP/, '%TEMP% を拒否していない');
  assert.match(ps1, /\$env:TMP/, '%TMP% を拒否していない');
  assert.match(ps1, /一時フォルダ/, '一時領域の拒否理由が無い');
  // 対話できない実行方法では確認を飛ばさず中止する
  assert.match(ps1, /確認を取れない実行方法です/);
  assert.doesNotMatch(ps1, /\$skipConfirm = \$Yes -or \(\$env:AI_SAFE_ASSUME_YES -eq "1"\) -or \(-not \[Environment\]::UserInteractive\)/,
    '対話不可を「確認スキップ」に倒したままになっている');
});

// 最後に流れるテスト（node:test はファイル内のトップレベルのテストを順に実行する）。
test('このテストファイルは利用者の ~/.ai-safety/bin を書き換えない', () => {
  const after = snapshotBin();
  const changed = Object.keys({ ...REAL_BIN_BEFORE, ...after })
    .filter((n) => REAL_BIN_BEFORE[n] !== after[n]);
  assert.deepStrictEqual(changed, [], '実 HOME の起動コマンドが書き換えられた: ' + changed.join(', '));
});
