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
