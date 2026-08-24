'use strict';
// v1.16.0（卒業版）の番号再編と「9_AIツールを最新版に更新」に対する回帰テスト。
//
// 守りたいこと:
//   1. スタートフォルダが新番号体系（基本 1..12・上級 1..8+9、重複なし）で揃っている
//   2. AI ツール更新ボタンが mac/win 両方にあり、Codex / Claude Code / OpenCode の
//      3 つとも latest 追従になっている (2026-08-20 に Claude Code の固定を撤廃)
//   3. agy はボタン更新の対象外（公式の自動更新に任せる）
//   4. install が旧名ボタンを掃除する（旧新併存による番号重複を再発させない）。
//      掃除対象は既知の旧名だけで、受講者の自作ファイルは消さない
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..', '..');
const startDir = path.join(root, 'workspace-template', 'スタート');
const read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const readSjis = (rel) =>
  new TextDecoder('shift_jis').decode(fs.readFileSync(path.join(root, rel)));

// ── 1. スタートフォルダの新番号体系 ─────────────────────────────────────
// v1.18.0 再編: スタート直下は「よく使う順の基本 9 個 +（Windows のみ）3 個」に絞り、
// キー・金庫系はサブフォルダ「キーと金庫」へ移した。個別のセーフ起動ボタンは
// 「4_AIを起動する」（統合ランチャー）へ集約し、「（上級）」プレフィックスは全廃。
// 野良 d-claude 退治は診断（9_困ったとき診断）へ統合した。
const EXPECTED_BOTH = [
  '1_安全パッケージを最新版にする',
  '2_AIツールをまとめて入れる',
  '3_じぶんに合うAIを選ぶ',
  '4_AIを起動する',
  '5_Codexデスクトップアプリを起動',
  '6_長時間おまかせモードで起動',
  '7_見守りモニターを起動',
  '8_使い方ガイドを開く',
  '9_困ったとき診断',
];
// Windows 専用ボタン。12 は v1.17.2 新設のアクセス権修復口で、Windows の ACL 固有の
// 事故（v1.17.1 までの install が `USERDOMAIN\USERNAME` という解決できない名前へ権限を
// 与え、`/inheritance:r` と合わさって受講者本人まで締め出していた）からの回復に使う。
// mac は chmod なので同型の事故が起きず、対になる .command は作らない。
const EXPECTED_WIN_ONLY = ['10_PowerShellを開く', '11_作業フォルダを開く', '12_フォルダのアクセス権を直す'];
// サブフォルダ「キーと金庫」（キーの登録・削除と OS 金庫の自由枠）。
const VAULT_DIR = 'キーと金庫';
const EXPECTED_VAULT_BOTH = [
  '1_DeepSeekキーを登録',
  '2_DeepSeekキーを削除',
  '3_AIコーチのキーを登録',
  '4_AIコーチのキーを削除',
  '5_Bufferのキーを登録',
  '6_Bufferのキーを削除',
  '7_金庫に秘密をしまう',
  '8_金庫から秘密を取り出す',
  '9_金庫の秘密を消す',
  '10_コピーした文章から秘密を伏せる',
  '11_伏せた文章を元に戻す',
  '12_PC全体に安全設定を入れる',
  '13_PC全体の安全設定を解除',
];

test('スタートフォルダは新番号体系どおりで、重複・欠番・旧名がない', () => {
  const files = fs.readdirSync(startDir).filter((f) => !f.startsWith('.')).sort();
  const expected = [
    ...EXPECTED_BOTH.map((b) => `${b}.command`),
    ...EXPECTED_BOTH.map((b) => `${b}.bat`),
    ...EXPECTED_WIN_ONLY.map((b) => `${b}.bat`),
    VAULT_DIR,
  ].sort();
  assert.deepStrictEqual(files, expected);

  const vaultFiles = fs.readdirSync(path.join(startDir, VAULT_DIR)).filter((f) => !f.startsWith('.')).sort();
  const vaultExpected = [
    ...EXPECTED_VAULT_BOTH.map((b) => `${b}.command`),
    ...EXPECTED_VAULT_BOTH.map((b) => `${b}.bat`),
  ].sort();
  assert.deepStrictEqual(vaultFiles, vaultExpected);

  // 番号の重複がないこと（直下・キーと金庫それぞれで先頭番号が一意）。
  for (const [label, list] of [['スタート', files], ['キーと金庫', vaultFiles]]) {
    for (const ext of ['command', 'bat']) {
      const nums = list
        .filter((f) => f.endsWith(`.${ext}`))
        .map((f) => {
          const m = f.match(/^(\d+)_/);
          return m ? m[1] : null;
        })
        .filter(Boolean);
      assert.strictEqual(new Set(nums).size, nums.length, `${label}/${ext}: 番号が重複している`);
    }
  }
});

// ── 2. 動作確認済みバージョン表 (SSOT) ──────────────────────────────────
// 2026-08-20 に意味が変わったテスト。以前は「claudeCode は semver で、policy の
// testedClaudeCodeVersion と一致すること」を求めていたが、Claude Code 純正サンドボックスを
// 主防御に据える方針転換にともない**固定インストールを廃止**したので、
//   ・claudeCode は "latest"
//   ・policy には testedClaudeCodeVersion キーが**無い**こと（残っていると版差警告が復活する）
//   ・導入・更新・案内文がすべて @latest を指すこと
// を代わりに固定する。固定版に戻すときは、この期待値ごと意図的に書き換えること。
test('tested-tool-versions.json が SSOT として存在し、全ツールが最新版追従になっている', () => {
  const versions = JSON.parse(read('configs/tested-tool-versions.json'));
  assert.strictEqual(versions.claudeCode, 'latest',
    'Claude Code は最新版追従（2026-08-20 に固定を撤廃）');
  assert.strictEqual(versions.codex, 'latest');
  assert.strictEqual(versions.opencode, 'latest');
  // 最後に実測した版は記録として残す（固定ではないので semver であることだけ見る）。
  assert.match(versions.claudeCodeLastVerified, /^\d+\.\d+\.\d+$/);

  // policy 側にピンが残っていないこと。残っていると launch-claude-safe / 診断 が
  // 「版ちがい」警告を毎回出すドリフトに戻る。
  const policy = JSON.parse(read('policy/safety-policy.json'));
  assert.strictEqual(policy.testedClaudeCodeVersion, undefined,
    'policy に testedClaudeCodeVersion が残っている（固定インストールは 2026-08-20 に撤廃）');

  // 導入・案内文もすべて @latest を指していること（固定版の直書きが残っていないこと）。
  for (const file of [
    'scripts/macos/launch-claude-safe.sh',
    'scripts/windows/launch-claude-safe.ps1',
    '0_AIツールをまとめて入れる-Mac.command',
  ]) {
    const text = read(file);
    assert.ok(text.includes('claude-code@latest'), `${file} が @latest を指していない`);
    assert.ok(!/claude-code@\d+\.\d+\.\d+/.test(text), `${file} に固定版の直書きが残っている`);
  }

  // install が workspace へ配置すること（ボタンの実体が読む場所）。
  assert.match(read('scripts/macos/install.sh'), /tested-tool-versions\.json/);
  assert.match(read('scripts/windows/install.ps1'), /tested-tool-versions\.json/);
});

// ── 3. AI ツール更新スクリプト（mac / win 対称） ─────────────────────────
// 2026-08-20: Claude Code の固定版インストールを撤廃したので、期待値を
// 「pin 版で入れる／latest にしてはいけない」から「3 ツールとも latest 追従」へ変更した。
test('update-ai-tools.sh: Codex/Claude/OpenCode は latest・agy は対象外', () => {
  const sh = read('scripts/macos/update-ai-tools.sh');
  assert.match(sh, /@openai\/codex@latest/);
  assert.match(sh, /opencode-ai@latest/);
  assert.match(sh, /@anthropic-ai\/claude-code@\$claude_pin/, 'Claude Code は SSOT の値で入れること');
  assert.ok(!/claude_pin="\$\(json_value claudeCode\)"[\s\S]{0,400}?Claude Code の更新はスキップ/.test(sh),
    '表が無いときに Claude Code の更新を丸ごとスキップする分岐は撤廃済み（latest にフォールバックする）');
  assert.match(sh, /claude_pin="latest"/, '表が読めないときは latest にフォールバックすること');
  assert.match(sh, /command -v/, '未インストールのツールは存在確認でスキップすること');
  assert.ok(!/npm install -g\s+(agy|antigravity)/i.test(sh), 'agy をボタンから入れ直さないこと');
  assert.match(sh, /agy \(AntiGravity\) はこのボタンでは更新しません/);
  assert.match(sh, /結果まとめ/, '最後にまとめを表示すること');
  assert.match(sh, /9_困ったとき診断/, '失敗時の案内が診断ボタンへ誘導すること');
  assert.match(sh, /スタート\.html の Step 0/, 'npm 不在時は Step 0 へ案内すること');
  assert.ok(!/sudo\s+npm/.test(sh), 'sudo で npm を実行しないこと（案内文で言及するのは可）');
});

test('update-ai-tools.ps1: 内容が mac 版と対称で、PowerShell 5.1 の作法に従う', () => {
  const raw = fs.readFileSync(path.join(root, 'scripts/windows/update-ai-tools.ps1'));
  assert.ok(raw[0] === 0xef && raw[1] === 0xbb && raw[2] === 0xbf, '.ps1 は UTF-8 BOM 付きであること');
  const ps = raw.toString('utf8');
  assert.match(ps, /\r\n/, '.ps1 は CRLF であること');
  assert.match(ps, /@openai\/codex@latest/);
  assert.match(ps, /opencode-ai@latest/);
  assert.match(ps, /@anthropic-ai\/claude-code@/, 'Claude Code は SSOT の値で入れること');
  assert.match(ps, /\$claudePin = "latest"/, '表が読めないときは latest にフォールバックすること');
  assert.ok(!/claude-code@\d+\.\d+\.\d+/.test(ps), '固定版の直書きが残っていないこと');
  assert.match(ps, /Get-Command/, '未インストールのツールは存在確認でスキップすること');
  assert.ok(!/npm install -g\s+(agy|antigravity)/i.test(ps), 'agy をボタンから入れ直さないこと');
  assert.match(ps, /agy \(AntiGravity\) はこのボタンでは更新しません/);
  assert.match(ps, /結果まとめ/, '最後にまとめを表示すること');
  assert.match(ps, /9_困ったとき診断/);
  assert.match(ps, /スタート\.html の Step 0/);
});

// ── 4. ボタン（薄いラッパー）────────────────────────────────────────────
test('2_AIツールをまとめて入れる ボタンが両 OS にあり、実体スクリプトを呼ぶ', () => {
  const cmd = read('workspace-template/スタート/2_AIツールをまとめて入れる.command');
  assert.match(cmd, /\.ai-safety\/hooks\/macos\/update-ai-tools\.sh/);
  assert.match(cmd, /HERE\/\.\./, '自分の場所からワークスペースを解決すること');
  assert.match(cmd, /キーを押すと閉じます/, '終了時にキー入力待ちで閉じること');

  const batBytes = fs.readFileSync(path.join(root, 'workspace-template/スタート/2_AIツールをまとめて入れる.bat'));
  assert.ok(batBytes[0] !== 0xef, '.bat に BOM を付けない');
  const bat = readSjis('workspace-template/スタート/2_AIツールをまとめて入れる.bat');
  assert.match(bat, /chcp 932/, '教室 PC 向けに CP932 で動かすこと');
  assert.match(bat, /\.ai-safety\\hooks\\windows\\update-ai-tools\.ps1/);
  assert.match(bat, /pause/);
  assert.ok(bat.includes('\r\n'), '.bat は CRLF であること');
});

test('mac にも診断ボタンがあり、doctor.sh を呼んで結果を平易に伝える', () => {
  const cmd = read('workspace-template/スタート/9_困ったとき診断.command');
  assert.match(cmd, /\.ai-safety\/hooks\/macos\/doctor\.sh/);
  assert.match(cmd, /読み取り専用/, '何も変更しないことを伝えること');
  assert.match(cmd, /PASS = 正常/, 'PASS/FAIL の見かたを日本語で示すこと');
  assert.match(cmd, /キーを押すと閉じます/);
});

// ── 5. install の旧名掃除 ───────────────────────────────────────────────
test('install は既知の旧名ボタンだけを掃除リストに持つ（両 OS）', () => {
  const sh = read('scripts/macos/install.sh');
  const ps = read('scripts/windows/install.ps1');
  for (const legacy of [
    '0_Bouncer統合版を起動.command',
    '6_最新版に更新.command',
    '7_困ったとき診断.bat',
    '7_野良d-claudeを退治.command',
    '8_PowerShellを開く.bat',
    '9_作業ウィンドウを開く.bat',
    '（上級）10_ccmuxを入れる.command',
    '（上級）11_Bufferのキーを登録.command',
    '（上級）12_プラグインの置き場を開く.command',
    // v1.18.0 再編で旧名になった v1.16〜v1.17 世代のボタン。
    '1_AIをまとめて起動.command',
    '9_AIツールを最新版に更新.command',
    '10_困ったとき診断.command',
    '14_フォルダのアクセス権を直す.bat',
    '（上級）15_長時間おまかせモードで起動.command',
    '（上級）16_金庫に秘密をしまう.command',
    '（上級）18_金庫の秘密を消す.command',
  ]) {
    assert.ok(sh.includes(legacy), `install.sh の掃除リストに無い: ${legacy}`);
    assert.ok(ps.includes(legacy.replace('.command', '.command')), `install.ps1 の掃除リストに無い: ${legacy}`);
  }
  // 現行の名前を誤って掃除対象にしていないこと。
  for (const current of ['4_AIを起動する', '2_AIツールをまとめて入れる', '9_困ったとき診断.command']) {
    assert.ok(!sh.match(new RegExp(`^${current}`, 'm')), `install.sh が現行ボタンを掃除しようとしている: ${current}`);
  }
});

test('install 再実行で旧名ボタンは消え、受講者の自作ファイルは残る', { skip: process.platform !== 'darwin' }, (t) => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'inst-rename-'));
  t.after(() => fs.rmSync(workspace, { recursive: true, force: true }));
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'inst-rename-home-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const env = { ...process.env, HOME: home };
  const INSTALL_SH = path.join(root, 'scripts', 'macos', 'install.sh');

  const first = spawnSync('bash', [INSTALL_SH, workspace], { env, encoding: 'utf8' });
  assert.strictEqual(first.status, 0, `install(1回目) が失敗: ${first.stdout}\n${first.stderr}`);

  // 旧版が配布していた旧名ボタンと、受講者の自作ファイルを混在させる。
  const ws = path.join(workspace, 'スタート');
  fs.writeFileSync(path.join(ws, '0_Bouncer統合版を起動.command'), '#!/bin/bash\n');
  fs.writeFileSync(path.join(ws, '1_AIをまとめて起動.command'), '#!/bin/bash\n');
  fs.writeFileSync(path.join(ws, '（上級）16_金庫に秘密をしまう.command'), '#!/bin/bash\n');
  fs.writeFileSync(path.join(ws, '自分のメモ.txt'), 'これは受講者の自作ファイル\n');

  const second = spawnSync('bash', [INSTALL_SH, workspace], { env, encoding: 'utf8' });
  assert.strictEqual(second.status, 0, `install(2回目) が失敗: ${second.stdout}\n${second.stderr}`);

  assert.ok(!fs.existsSync(path.join(ws, '0_Bouncer統合版を起動.command')), '旧名ボタンが残っている');
  assert.ok(!fs.existsSync(path.join(ws, '1_AIをまとめて起動.command')), 'v1.17 世代の旧名ボタンが残っている');
  assert.ok(!fs.existsSync(path.join(ws, '（上級）16_金庫に秘密をしまう.command')), '旧金庫ボタンが残っている');
  assert.ok(fs.existsSync(path.join(ws, '4_AIを起動する.command')), '新名ボタンが配置されていない');
  assert.ok(fs.existsSync(path.join(ws, '2_AIツールをまとめて入れる.command')), '新ボタンが配置されていない');
  assert.ok(fs.existsSync(path.join(ws, '9_困ったとき診断.command')), 'mac 診断ボタンが配置されていない');
  assert.ok(fs.existsSync(path.join(ws, 'キーと金庫', '7_金庫に秘密をしまう.command')), '金庫サブフォルダが配置されていない');
  assert.ok(fs.existsSync(path.join(ws, '自分のメモ.txt')), '受講者の自作ファイルを消してはいけない');
  assert.ok(fs.existsSync(path.join(workspace, '.ai-safety', 'tested-tool-versions.json')),
    '動作確認済みバージョン表が workspace に配置されること');
});

// ── 6. 統合版メニューの課金条件併記 ──────────────────────────────────
// v1.18.0: メニューの正本はランチャー本体（launch-integrated の menu モード）に集約し、
// スタートのボタンは委譲だけにした（ボタン側の写しが陳腐化した実績があるため）。
// 課金条件の併記と番号→起動先の対応は、ランチャー本体側で検査する。
test('統合版メニューは課金条件を併記し、番号と起動先が一致する', () => {
  const cmd = read('workspace-template/スタート/4_AIを起動する.command');
  assert.match(cmd, /exec bash "\$LAUNCHER" "\$WORKSPACE" menu standard/,
    'mac ボタンはメニューの正本（menu モード）へ委譲すること');
  assert.doesNotMatch(cmd, /最大保護/, '廃止した最大保護モードが復活していないこと');

  const mac = read('scripts/macos/launch-integrated.sh');
  // v1.18.0（2026-08-24 依頼者裁定）: 完全無課金の第一候補は「OpenCode の無料モデル自由選択
  // （--free・送信検査なし）」。AntiGravity は 2 番（こちらも無料）。
  assert.match(mac, /1\) OpenCode（無料モデルを自分で選ぶ）.*完全無課金/, '無課金の入口（OpenCode 無料モデル）があること');
  assert.match(mac, /2\) セーフ AntiGravity.*無料/, 'AntiGravity（2 番・無料）があること');
  assert.match(mac, /3\) OpenCode \+ DeepSeek.*少額チャージ/);
  assert.match(mac, /5\) Claude Code.*課金契約/);
  assert.match(mac, /6\) セーフ Codex.*ChatGPT/);
  // 番号→起動先の対応。
  assert.match(mac, /1\) agent="opencode"; profile="standard"; choose_project; extra="--free"/,
    '無料モデル（1 番）は --free で起動すること');
  assert.match(mac, /4\) agent="d-claude"; profile="standard"/, 'd-claude（4 番）は維持すること');
  assert.match(mac, /5\) agent="claude"; profile="standard"/);
  assert.match(mac, /6\) agent="codex"; profile="standard"/);
  assert.doesNotMatch(mac, /最大保護/, '廃止した最大保護モードが復活していないこと');

  const bat = readSjis('workspace-template/スタート/4_AIを起動する.bat');
  assert.match(bat, /-Agent menu -Profile standard/, 'Windows ボタンはメニューの正本（menu モード）へ委譲すること');
  assert.doesNotMatch(bat, /最大保護/, '廃止した最大保護モードが復活していないこと');

  const win = read('scripts/windows/launch-integrated.ps1');
  assert.match(win, /1\) OpenCode（無料モデルを自分で選ぶ）.*完全無課金/);
  assert.match(win, /2\) セーフ AntiGravity.*無料/);
  assert.match(win, /3\) OpenCode \+ DeepSeek.*少額チャージ/);
  assert.match(win, /'1'  \{ \$Agent = 'opencode'; \$SafetyProfile = 'standard'; \$Free = \$true; \$Project = Select-ProjectFolder \}/,
    '無料モデル（1 番）は -Free で起動すること');
  assert.match(win, /'4'  \{ \$Agent = 'd-claude'; \$SafetyProfile = 'standard' \}/, 'd-claude（4 番）は維持すること');
  assert.match(win, /'5'  \{ \$Agent = 'claude'; \$SafetyProfile = 'standard' \}/);
  assert.match(win, /'6'  \{ \$Agent = 'codex'; \$SafetyProfile = 'standard' \}/);
  assert.doesNotMatch(win, /最大保護/, '廃止した最大保護モードが復活していないこと');
});
