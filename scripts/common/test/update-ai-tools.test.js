'use strict';
// v1.16.0（卒業版）の番号再編と「8_AIツールを最新版に更新」に対する回帰テスト。
//
// 守りたいこと:
//   1. スタートフォルダが新番号体系（基本 1..12・上級 1..8+9、重複なし）で揃っている
//   2. AI ツール更新ボタンが mac/win 両方にあり、Codex/OpenCode は latest、
//      Claude Code は動作確認済み版 (tested-tool-versions.json = SSOT) に固定される
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
const EXPECTED_BOTH = [
  '1_AIをまとめて起動',
  '2_セーフCodexを起動',
  '3_セーフClaudeを起動',
  '4_セーフAntiGravityを起動',
  '5_見守りモニターを起動',
  '6_AIコーチのキーを登録',
  '7_安全パッケージを最新版に更新',
  '8_AIツールを最新版に更新',
  '9_困ったとき診断',
  '10_野良d-claudeを退治',
  '（上級）1_DeepSeekキーを登録',
  '（上級）2_DeepSeek-Claudeを起動', // 山口さん判断 (2026-08-18): d-claude は廃止しない
  '（上級）3_モニターをコンソールで見る',
  '（上級）4_ステータスラインを入れる',
  '（上級）5_危険コマンドをClaude全体で禁止',
  '（上級）6_グローバル禁止を解除',
  '（上級）7_DeepSeekキーを削除',
  '（上級）8_Bufferのキーを登録',
  '（上級）9_プラグインの置き場を開く',
];
const EXPECTED_WIN_ONLY = ['11_PowerShellを開く', '12_作業フォルダを開く'];

test('スタートフォルダは新番号体系どおりで、重複・欠番・旧名がない', () => {
  const files = fs.readdirSync(startDir).filter((f) => !f.startsWith('.')).sort();
  const expected = [
    ...EXPECTED_BOTH.map((b) => `${b}.command`),
    ...EXPECTED_BOTH.map((b) => `${b}.bat`),
    ...EXPECTED_WIN_ONLY.map((b) => `${b}.bat`),
  ].sort();
  assert.deepStrictEqual(files, expected);

  // 番号の重複がないこと（基本・上級それぞれで先頭番号が一意）。
  for (const ext of ['command', 'bat']) {
    const nums = files
      .filter((f) => f.endsWith(`.${ext}`))
      .map((f) => {
        const m = f.match(/^(（上級）)?(\d+)_/);
        return m ? `${m[1] || ''}${m[2]}` : null;
      })
      .filter(Boolean);
    assert.strictEqual(new Set(nums).size, nums.length, `${ext}: 番号が重複している`);
  }
});

// ── 2. 動作確認済みバージョン表 (SSOT) ──────────────────────────────────
test('tested-tool-versions.json が SSOT として存在し、policy の版と一致する', () => {
  const versions = JSON.parse(read('configs/tested-tool-versions.json'));
  assert.match(versions.claudeCode, /^\d+\.\d+\.\d+$/);
  assert.strictEqual(versions.codex, 'latest');
  assert.strictEqual(versions.opencode, 'latest');

  // 既存の SSOT（policy の testedClaudeCodeVersion）と食い違うと診断と更新で別の版を指す。
  const policy = JSON.parse(read('policy/safety-policy.json'));
  assert.strictEqual(versions.claudeCode, policy.testedClaudeCodeVersion,
    'configs/tested-tool-versions.json と policy/safety-policy.json の Claude Code 版が食い違っている');

  // 案内文に焼き込まれた版とも一致していること（値の一致チェック）。
  assert.ok(read('scripts/macos/launch-claude-safe.sh').includes(`claude-code@${versions.claudeCode}`));
  assert.ok(read('scripts/windows/launch-claude-safe.ps1').includes(`claude-code@${versions.claudeCode}`));

  // install が workspace へ配置すること（ボタンの実体が読む場所）。
  assert.match(read('scripts/macos/install.sh'), /tested-tool-versions\.json/);
  assert.match(read('scripts/windows/install.ps1'), /tested-tool-versions\.json/);
});

// ── 3. AI ツール更新スクリプト（mac / win 対称） ─────────────────────────
test('update-ai-tools.sh: Codex/OpenCode は latest・Claude は固定版・agy は対象外', () => {
  const sh = read('scripts/macos/update-ai-tools.sh');
  assert.match(sh, /@openai\/codex@latest/);
  assert.match(sh, /opencode-ai@latest/);
  assert.match(sh, /@anthropic-ai\/claude-code@\$claude_pin/, 'Claude Code は SSOT の pin 版で入れること');
  assert.ok(!/claude-code@latest/.test(sh), 'Claude Code を latest にしてはいけない');
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
  assert.match(ps, /@anthropic-ai\/claude-code@/, 'Claude Code は pin 版で入れること');
  assert.ok(!/claude-code@latest/.test(ps), 'Claude Code を latest にしてはいけない');
  assert.match(ps, /Get-Command/, '未インストールのツールは存在確認でスキップすること');
  assert.ok(!/npm install -g\s+(agy|antigravity)/i.test(ps), 'agy をボタンから入れ直さないこと');
  assert.match(ps, /agy \(AntiGravity\) はこのボタンでは更新しません/);
  assert.match(ps, /結果まとめ/, '最後にまとめを表示すること');
  assert.match(ps, /9_困ったとき診断/);
  assert.match(ps, /スタート\.html の Step 0/);
});

// ── 4. ボタン（薄いラッパー）────────────────────────────────────────────
test('8_AIツールを最新版に更新 ボタンが両 OS にあり、実体スクリプトを呼ぶ', () => {
  const cmd = read('workspace-template/スタート/8_AIツールを最新版に更新.command');
  assert.match(cmd, /\.ai-safety\/hooks\/macos\/update-ai-tools\.sh/);
  assert.match(cmd, /HERE\/\.\./, '自分の場所からワークスペースを解決すること');
  assert.match(cmd, /キーを押すと閉じます/, '終了時にキー入力待ちで閉じること');

  const batBytes = fs.readFileSync(path.join(root, 'workspace-template/スタート/8_AIツールを最新版に更新.bat'));
  assert.ok(batBytes[0] !== 0xef, '.bat に BOM を付けない');
  const bat = readSjis('workspace-template/スタート/8_AIツールを最新版に更新.bat');
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
  ]) {
    assert.ok(sh.includes(legacy), `install.sh の掃除リストに無い: ${legacy}`);
    assert.ok(ps.includes(legacy.replace('.command', '.command')), `install.ps1 の掃除リストに無い: ${legacy}`);
  }
  // 現行の名前を誤って掃除対象にしていないこと。
  for (const current of ['1_AIをまとめて起動', '8_AIツールを最新版に更新', '9_困ったとき診断.command']) {
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
  fs.writeFileSync(path.join(ws, '（上級）10_ccmuxを入れる.command'), '#!/bin/bash\n');
  fs.writeFileSync(path.join(ws, '自分のメモ.txt'), 'これは受講者の自作ファイル\n');

  const second = spawnSync('bash', [INSTALL_SH, workspace], { env, encoding: 'utf8' });
  assert.strictEqual(second.status, 0, `install(2回目) が失敗: ${second.stdout}\n${second.stderr}`);

  assert.ok(!fs.existsSync(path.join(ws, '0_Bouncer統合版を起動.command')), '旧名ボタンが残っている');
  assert.ok(!fs.existsSync(path.join(ws, '（上級）10_ccmuxを入れる.command')), '廃止ボタンが残っている');
  assert.ok(fs.existsSync(path.join(ws, '1_AIをまとめて起動.command')), '新名ボタンが配置されていない');
  assert.ok(fs.existsSync(path.join(ws, '8_AIツールを最新版に更新.command')), '新ボタンが配置されていない');
  assert.ok(fs.existsSync(path.join(ws, '9_困ったとき診断.command')), 'mac 診断ボタンが配置されていない');
  assert.ok(fs.existsSync(path.join(ws, '自分のメモ.txt')), '受講者の自作ファイルを消してはいけない');
  assert.ok(fs.existsSync(path.join(workspace, '.ai-safety', 'tested-tool-versions.json')),
    '動作確認済みバージョン表が workspace に配置されること');
});

// ── 6. 統合版メニューの課金条件併記（選択肢の順序・機能は不変） ──────────
test('統合版メニューは課金条件を併記し、番号と起動先は従来どおり', () => {
  const cmd = read('workspace-template/スタート/1_AIをまとめて起動.command');
  assert.match(cmd, /1\) Codex.*ChatGPT 課金/);
  assert.match(cmd, /2\) Claude.*Claude 課金/);
  assert.match(cmd, /5\) OpenCode.*無課金/);
  // 番号→起動先の対応は不変であること。
  assert.match(cmd, /1\) exec bash "\$LAUNCHER" "\$WORKSPACE" codex standard/);
  assert.match(cmd, /2\) exec bash "\$LAUNCHER" "\$WORKSPACE" claude standard/);
  assert.match(cmd, /7\) exec bash "\$LAUNCHER" "\$WORKSPACE" d-claude standard/, 'd-claude（7 番）は維持すること');

  const bat = readSjis('workspace-template/スタート/1_AIをまとめて起動.bat');
  assert.match(bat, /1 Codex.*ChatGPT 課金/);
  assert.match(bat, /2 Claude.*Claude 課金/);
  assert.match(bat, /5 OpenCode.*無課金/);
  assert.match(bat, /choice \/c 12345678/, '選択肢の数を変えないこと');
  assert.match(bat, /-Agent d-claude -Profile standard/, 'd-claude（7 番）は維持すること');
});
