'use strict';
// oc-safe（どこからでも打てる OpenCode 起動コマンド）の回帰テスト。
//
// 背景: OpenCode は「起動したフォルダ」が作業対象になり、動き出したあとで cd しても
// 移らない（本体仕様）。そのため「作業フォルダの中にプロジェクトごとのフォルダを作って、
// その中で作業する」には、そのフォルダで起動する必要がある。
// oc-safe はそれを 1 行で済ませるためのコマンドで、ccmux / Zed / ターミナルの
// どこから打っても同じように使える（PATH に通す）。
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

test('install が oc-safe を配置し、PATH を通す', { skip: process.platform !== 'darwin' }, (t) => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ocsafe-ws-'));
  const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ocsafe-home-'));
  t.after(() => {
    fs.rmSync(workspace, { recursive: true, force: true });
    fs.rmSync(fakeHome, { recursive: true, force: true });
  });

  const r = spawnSync('bash', [path.join(root, 'scripts', 'macos', 'install.sh'), workspace],
    { env: { ...process.env, HOME: fakeHome }, encoding: 'utf8' });
  assert.strictEqual(r.status, 0, `install 失敗: ${r.stdout}\n${r.stderr}`);

  const oc = path.join(fakeHome, '.ai-safety', 'bin', 'oc-safe');
  assert.ok(fs.existsSync(oc), 'oc-safe が配置されること');
  assert.ok((fs.statSync(oc).mode & 0o111) !== 0, '実行できること');

  const body = fs.readFileSync(oc, 'utf8');
  assert.ok(!body.includes('__WORKSPACE__'), 'ワークスペースのパスが焼き込まれていること');
  assert.ok(body.includes(workspace), '焼き込まれたパスが今回のワークスペースであること');

  const zshrc = fs.readFileSync(path.join(fakeHome, '.zshrc'), 'utf8');
  assert.match(zshrc, /\.ai-safety\/bin/, 'PATH に追加されること');

  // 2 回目の install で PATH 行が重複しない（冪等）。
  const again = spawnSync('bash', [path.join(root, 'scripts', 'macos', 'install.sh'), workspace],
    { env: { ...process.env, HOME: fakeHome }, encoding: 'utf8' });
  assert.strictEqual(again.status, 0);
  const zshrc2 = fs.readFileSync(path.join(fakeHome, '.zshrc'), 'utf8');
  const count = (zshrc2.match(/\.ai-safety\/bin/g) || []).length;
  assert.strictEqual(count, 1, 'PATH 行を毎回足してはいけない');
});

test('oc-safe はプロジェクトフォルダを指定して起動する', { skip: process.platform !== 'darwin' }, (t) => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ocsafe-run-ws-'));
  const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ocsafe-run-home-'));
  t.after(() => {
    fs.rmSync(workspace, { recursive: true, force: true });
    fs.rmSync(fakeHome, { recursive: true, force: true });
  });
  const installed = spawnSync('bash', [path.join(root, 'scripts', 'macos', 'install.sh'), workspace],
    { env: { ...process.env, HOME: fakeHome }, encoding: 'utf8' });
  assert.strictEqual(installed.status, 0, installed.stderr);

  const oc = path.join(fakeHome, '.ai-safety', 'bin', 'oc-safe');
  const project = path.join(workspace, '案件A', 'sub');
  fs.mkdirSync(project, { recursive: true });
  const env = { ...process.env, HOME: fakeHome, AI_SAFE_DRY_RUN: '1' };
  // 判定も表示も物理パスで揃えている（macOS の /var → /private/var 対策）ので、
  // 期待値も実体のパスに合わせる。
  const realWorkspace = fs.realpathSync(workspace);
  const realProject = fs.realpathSync(project);

  // フォルダ名だけで指定できる（oc-safe 案件A）
  const byName = spawnSync(oc, ['案件A'], { env, encoding: 'utf8' });
  assert.strictEqual(byName.status, 0, byName.stderr);
  assert.match(byName.stdout, new RegExp(`project:\\s+${path.join(realWorkspace, '案件A')}`),
    'ワークスペース内の同名フォルダを解決すること');
  // ★ 見守りモニターごと立ち上がる「統合ランチャー」を必ず経由すること。
  // OpenCode のランチャーを直接叩くと、モニターが起動せず画面で見えないまま AI が動く。
  assert.match(byName.stdout, /Bouncer統合版/, '統合ランチャーを経由すること');
  assert.match(byName.stdout, /monitor:\s+enabled/, '見守りモニターが起動対象に入っていること');

  // 引数なしなら「いま開いているフォルダ」
  const byCwd = spawnSync(oc, [], { env, cwd: project, encoding: 'utf8' });
  assert.strictEqual(byCwd.status, 0, byCwd.stderr);
  assert.match(byCwd.stdout, new RegExp(`project:\\s+${realProject}`), 'いる場所で起動すること');

  // 続きから・Web検索と組み合わせられる
  const combo = spawnSync(oc, ['案件A', '--resume'], { env, encoding: 'utf8' });
  assert.strictEqual(combo.status, 0, combo.stderr);
  assert.match(combo.stdout, /session:\s+continue last/);

  // ワークスペースの外は断る（ガードが及ばない場所で AI を動かさない）
  const outside = spawnSync(oc, [], { env, cwd: os.tmpdir(), encoding: 'utf8' });
  assert.notStrictEqual(outside.status, 0, 'ワークスペース外では起動しないこと');
  assert.match(outside.stdout + outside.stderr, /作業フォルダ（my-ai-workspace）の中で使ってください/);
});

test('ランチャーは作業フォルダ（project）を受け取り、そこで OpenCode を起動する', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  assert.match(mac, /--project\) _expect_project=1/, 'mac: --project を受けること');
  assert.match(mac, /cd "\$PROJECT_DIR"/, 'mac: 指定フォルダへ移ってから起動すること');
  assert.match(mac, /作業フォルダはワークスペースの中だけを指定できます/, 'mac: 外は断ること');

  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');
  assert.match(win, /\[string\]\$Project = ""/, 'Windows: -Project を受けること');
  assert.match(win, /Push-Location \$Project/, 'Windows: 指定フォルダへ移ってから起動すること');
  assert.match(win, /作業フォルダはワークスペースの中だけを指定できます/, 'Windows: 外は断ること');
});

test('Windows でも oc-safe が PATH のコマンドとして入る', () => {
  const setup = read('scripts/windows/setup-commands.ps1');
  assert.match(setup, /name = "oc-safe";\s+ps1 = "oc-safe\.ps1"/, 'シム一覧に登録されること');

  const ps1 = read('scripts/windows/oc-safe.ps1');
  assert.match(ps1, /\[Parameter\(Position = 0\)\]/, 'フォルダを位置引数で受けること');
  assert.match(ps1, /-Project \$Folder/, 'ランチャーへ作業フォルダを渡すこと');
  assert.match(ps1, /作業フォルダ \(my-ai-workspace\) の中で使ってください/, '外は断ること');
});

// ★ 実機で踏んだ事故の回帰: oc-safe が OpenCode のランチャーを直接呼んでいたため、
// 見守りモニター（Bouncer の画面）が起動しなかった。モニターを立ち上げるのは統合ランチャーの
// 役目なので、oc-safe は必ずそこを経由する。
test('oc-safe は統合ランチャー（モニターを起動する入口）を経由する', () => {
  const mac = read('scripts/macos/oc-safe.template.sh');
  assert.match(mac, /launch-integrated\.sh/, 'mac: 統合ランチャーを呼ぶこと');
  assert.ok(!/LAUNCHER=.*launch-opencode-deepseek\.sh/.test(mac),
    'mac: OpenCode のランチャーを直接叩かないこと');
  assert.match(mac, /opencode standard/, 'mac: agent と profile を渡すこと');

  const win = read('scripts/windows/oc-safe.ps1');
  assert.match(win, /launch-integrated\.ps1/, 'Windows: 統合ランチャーを呼ぶこと');
  assert.ok(!/\$launcher = Join-Path \$Workspace '\.ai-safety\\\\hooks\\\\windows\\\\opencode/.test(win),
    'Windows: OpenCode のランチャーを直接叩かないこと');
  assert.match(win, /-Agent opencode -SafetyProfile standard/, 'Windows: agent と profile を渡すこと');

  // 統合ランチャー側が作業フォルダを受け取れること
  assert.match(read('scripts/macos/launch-integrated.sh'), /--project=\*/, 'mac 統合: --project= を受けること');
  assert.match(read('scripts/windows/launch-integrated.ps1'), /-Project \$Project/, 'Windows 統合: -Project を渡すこと');
});

// ccmux は Windows 版だけ改造版（ドラッグ&ドロップ、Shift+ホイール遡り、上位階層移動）を
// 配布していて、mac は本家 npm 版しか入れていなかった。mac でも改造版を入れる。
test('mac の ccmux 導入は改造版を取得し、SHA-256 で照合してから配置する', () => {
  const cmd = read('workspace-template/スタート/（上級）10_ccmuxを入れる.command');
  assert.match(cmd, /ccmux-macos-arm64/, 'mac 用の改造版を取得すること');
  assert.match(cmd, /EXPECT_SHA="[0-9a-f]{64}"/, '期待する SHA-256 を焼き込んでいること');
  assert.match(cmd, /shasum -a 256/, '照合してから使うこと');
  assert.match(cmd, /--proto '=https' --proto-redir '=https'/, 'HTTPS 固定で取得すること');
  assert.match(cmd, /xattr -dr com\.apple\.quarantine/, '検疫属性を外して起動できるようにすること');
  // Apple Silicon 以外は改造版バイナリが無いので本家版にフォールバックする。
  assert.match(cmd, /npm install -g ccmux-cli/, 'Intel Mac は本家版で導入すること');

  // MIT ライセンス遵守: 改変内容の記載を実装に追従させる。
  const lic = read('THIRD_PARTY/ccmux-LICENSE.txt');
  assert.match(lic, /上の階層へ移動できる機能を追加/, '改変内容に上位階層移動を記載すること');
});

// 「Bouncer統合版を起動」から OpenCode を選んだとき、作業フォルダを番号で選べるようにする。
// OpenCode は起動したフォルダが作業対象になるので、案件ごとに分けて作業するには
// 起動時にどこで始めるかを決める必要がある（受講者にパスを打たせない形にする）。
test('起動メニューから作業フォルダを番号で選べる（Mac / Windows とも）', () => {
  const cmd = read('workspace-template/スタート/0_Bouncer統合版を起動.command');
  assert.match(cmd, /choose_project/, 'mac: フォルダ選択を持つこと');
  assert.match(cmd, /どのフォルダで作業しますか/, 'mac: 選ばせる文言を出すこと');
  assert.match(cmd, /--project=\$WORKSPACE\/\$_sel/, 'mac: 選んだフォルダを渡すこと');
  // OpenCode の 3 経路（通常 / Web検索 / 続きから）すべてで選べること。
  assert.strictEqual((cmd.match(/choose_project;/g) || []).length, 3, 'mac: OpenCode の 3 経路で呼ぶこと');
  // 変数の直後に日本語が続くと bash 3.2 が変数名を取り違えるので ${} で囲む。
  assert.match(cmd, /「\$\{_sel\}」/, 'mac: 日本語の直前の変数は ${} で囲むこと');

  const batBytes = fs.readFileSync(path.join(root, 'workspace-template/スタート/0_Bouncer統合版を起動.bat'));
  assert.ok(batBytes[0] !== 0xef, '.bat に BOM を付けない');
  const bat = new TextDecoder('shift_jis').decode(batBytes);
  assert.match(bat, /setlocal enabledelayedexpansion/, 'Windows: 連番変数を引くため遅延展開を使うこと');
  assert.match(bat, /:choose_project/, 'Windows: フォルダ選択を持つこと');
  assert.strictEqual((bat.match(/call :choose_project/g) || []).length, 3, 'Windows: OpenCode の 3 経路で呼ぶこと');
  assert.strictEqual((bat.match(/-Project "!PROJECT_DIR!"/g) || []).length, 3, 'Windows: 選んだフォルダを渡すこと');
  assert.match(bat, /どのフォルダで作業しますか/, 'Windows: CP932 のまま日本語が壊れていないこと');
  // 変数名の中で番号を展開するには call を挟む必要がある（!PDIR_!PICK!! は書けない）。
  assert.match(bat, /call set "PSEL=%%PDIR_!PICK!%%"/, 'Windows: 連番変数の引き方が正しいこと');
});

// ★ 実際に起こした事故の回帰テスト。
// 検証用フォルダへ導入し直したせいで oc-safe に焼き込まれた作業フォルダがそちらへ
// 書き換わり、本来の作業フォルダの中に居るのに「外です」と断られた。
// 焼き込み値を優先せず、いま居る場所から上へ .ai-safety を探して判断する。
test('oc-safe は焼き込み値より「いま居る場所」を優先して作業フォルダを決める',
  { skip: process.platform !== 'darwin' }, (t) => {
    const base = fs.mkdtempSync(path.join(os.tmpdir(), 'ocsafe-detect-'));
    t.after(() => fs.rmSync(base, { recursive: true, force: true }));
    const home = path.join(base, 'home');
    fs.mkdirSync(home, { recursive: true });

    const wsA = path.join(base, 'wsA');
    const wsB = path.join(base, 'wsB');
    for (const ws of [wsA, wsB]) {
      const r = spawnSync('bash', [path.join(root, 'scripts', 'macos', 'install.sh'), ws],
        { env: { ...process.env, HOME: home }, encoding: 'utf8' });
      assert.strictEqual(r.status, 0, `install 失敗: ${r.stderr}`);
    }

    const oc = path.join(home, '.ai-safety', 'bin', 'oc-safe');
    // 最後に導入した wsB が焼き込まれている状態。
    assert.match(fs.readFileSync(oc, 'utf8'), new RegExp(`WORKSPACE_BAKED="${wsB}"`),
      '前提: 焼き込み値は最後に導入した方を指す');

    const projA = path.join(wsA, '案件A');
    fs.mkdirSync(projA, { recursive: true });
    const env = { ...process.env, HOME: home, AI_SAFE_DRY_RUN: '1' };

    // 焼き込みは wsB を指しているが、wsA の中に居るので wsA が使われること。
    const inA = spawnSync(oc, [], { env, cwd: projA, encoding: 'utf8' });
    assert.strictEqual(inA.status, 0, `wsA の中で断られている: ${inA.stdout}${inA.stderr}`);
    assert.match(inA.stdout, new RegExp(`workspace:\\s+${fs.realpathSync(wsA)}`),
      '居る側の作業フォルダを使うこと');
    assert.match(inA.stdout, new RegExp(`project:\\s+${fs.realpathSync(projA)}`));

    // どちらの作業フォルダの外でもないなら、これまでどおり断ること。
    const outside = spawnSync(oc, [], { env, cwd: os.tmpdir(), encoding: 'utf8' });
    assert.notStrictEqual(outside.status, 0, '作業フォルダの外では起動しないこと');
  });

// install は HOME 配下（~/.ai-safety/bin と ~/.zshrc）も書き換える。テストがそれを忘れると、
// 利用者の oc-safe に検証用ワークスペースが焼き込まれる（実際に 2 度起こした）。
// 新しいテストが install を実行するようになっても気づけるよう、機械的に見張る。
test('install を実行するテストは必ず HOME を隔離している', () => {
  const dir = path.join(root, 'scripts', 'common', 'test');
  const offenders = [];
  for (const name of fs.readdirSync(dir)) {
    if (!name.endsWith('.test.js')) continue;
    const body = fs.readFileSync(path.join(dir, name), 'utf8');
    // install.sh を子プロセスとして起動している箇所だけを見る（読むだけの参照は対象外）。
    const launches = /(spawnSync|spawn)\(\s*'bash'\s*,\s*\[[^\]]*install\.sh/g;
    let m;
    while ((m = launches.exec(body)) !== null) {
      // 呼び出しから少し先までの範囲に HOME 指定があるかを見る。
      const window = body.slice(m.index, m.index + 400);
      if (!/HOME:/.test(window)) offenders.push(`${name} (offset ${m.index})`);
    }
  }
  assert.deepStrictEqual(offenders, [],
    `install を HOME 隔離なしで実行しているテストがある: ${offenders.join(', ')}`);
});
