// explainer.test.js — 見守りモニター用の解説エンジン（scripts/common/explainer.js）の検査。
//
// v1.19.0 で bash（explainer.sh）と PowerShell（Explainer.ps1）の二重実装をこの 1 本にまとめた。
// ここで固定すること:
//   (1) 正解表（fixtures/explainer-golden.json）どおりの説明文。旧 bash 版と突き合わせて作った
//   (2) 両 OS 共通の答え合わせ表（fixtures/explainer-parity.tsv）: 警告の有無・安心文の有無・対象
//   (3) 統合のときに直した挙動（>& / >| の行き先、2>&1 などのつなぎ替え、$(...) の場所、引用符の中の空白、
//       now.html にカードの管理用の行を出さない）
//   (4) now.md / now.html の書き出しと、モニターが読むクラス名
// 正解表の作り直し: node scripts/common/test/explainer.test.js --update-golden（差分は必ず目で確認する）
'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const REPO = path.resolve(__dirname, '..', '..', '..');
const JS = path.join(REPO, 'scripts', 'common', 'explainer.js');
const ex = require(JS);
const CARDS = path.join(REPO, 'configs', 'safety', 'cards');
const GOLDEN = path.join(__dirname, 'fixtures', 'explainer-golden.json');
const PARITY = path.join(__dirname, 'fixtures', 'explainer-parity.tsv');

if (process.argv.includes('--update-golden')) {
  const g = JSON.parse(fs.readFileSync(GOLDEN, 'utf8'));
  g.cases = g.cases.map((c) => ({ command: c.command, ...ex.explainCommand(c.command) }));
  fs.writeFileSync(GOLDEN, JSON.stringify(g, null, 1) + '\n');
  console.log('updated', g.cases.length);
  process.exit(0);
}

function tmpdir() { return fs.mkdtempSync(path.join(os.tmpdir(), 'explainer-')); }
function hook(command) { return JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command } }); }

test('正解表どおりの説明文（旧 bash 版と突き合わせ済みの 539 件）', () => {
  const g = JSON.parse(fs.readFileSync(GOLDEN, 'utf8'));
  assert.ok(g.cases.length >= 500, 'golden が少なすぎる');
  const bad = [];
  for (const c of g.cases) {
    const got = ex.explainCommand(c.command);
    for (const f of ['whatdo', 'icon', 'danger']) {
      if (got[f] !== c[f]) bad.push(`${JSON.stringify(c.command)} ${f}: expected ${JSON.stringify(c[f])} got ${JSON.stringify(got[f])}`);
    }
  }
  assert.deepStrictEqual(bad, []);
});

test('両 OS 共通の答え合わせ表（explainer-parity.tsv）', () => {
  const lines = fs.readFileSync(PARITY, 'utf8').split('\n');
  let n = 0;
  for (const line of lines) {
    if (line === '' || line.startsWith('#')) continue;
    const [cmd, , danger, readonly, hint] = line.split('\t');
    const e = ex.explainCommand(cmd);
    assert.strictEqual(e.danger ? 'true' : 'false', danger, `danger [${cmd}]`);
    assert.strictEqual(/しません|読むだけ/.test(e.whatdo) ? 'true' : 'false', readonly, `readonly [${cmd}] W=${e.whatdo}`);
    if (hint) assert.ok(e.whatdo.includes(hint), `hint [${hint}] not in [${e.whatdo}]`);
    n++;
  }
  assert.ok(n > 10);
});

test('誤った安心ゼロ: 読むだけの単純コマンドだけに安心文を出す', () => {
  for (const c of ['ls', 'cat foo.txt', 'wc foo', 'Get-ChildItem C:\\Temp', 'type foo.txt', 'head -n 5 foo']) {
    assert.match(ex.explainCommand(c).whatdo, /しません/, c);
  }
  for (const c of ['cat foo > out.txt', 'cat foo | findstr x', 'cat foo; ls', 'cat foo.txt;', 'sudo cat foo', 'sudo\tcat foo',
    'Remove-Item -Recurse build', 'cat foo\ntouch x', 'cat foo\rtouch x', 'cat $(echo hi)', 'ls 2>&1', 'find . -name x']) {
    assert.doesNotMatch(ex.explainCommand(c).whatdo, /しません|読むだけ/, c);
  }
});

test('統合で直した点: >& / >>& / >| の行き先を読む', () => {
  assert.strictEqual(ex.explainCommand('echo x >& /tmp/a.txt').whatdo.startsWith('/tmp/a.txt にファイルを書き込み'), true);
  assert.strictEqual(ex.explainCommand('echo x >>& /tmp/a.txt').whatdo.startsWith('/tmp/a.txt にファイルを追記'), true);
  assert.strictEqual(ex.explainCommand('ls >| ~/.zshrc').whatdo.startsWith('~/.zshrc にファイルを書き込み'), true);
  assert.strictEqual(ex.explainCommand('echo x >&/tmp/b.txt').whatdo.startsWith('/tmp/b.txt に'), true);
});

test('統合で直した点: 2>&1 や 1>&2 のつなぎ替えはファイルへの書き込みにしない', () => {
  const e = ex.explainCommand('echo hello 1>&2');
  assert.strictEqual(e.icon, '📄');
  assert.match(e.whatdo, /画面に文字を表示/);
  assert.doesNotMatch(ex.explainCommand('ls 3>&1 1>&2').whatdo, /にファイルを/);
});

test('統合で直した点: $(...) や `...` で場所が決まるときは「現在のフォルダ」と言わない', () => {
  for (const c of ['cat $(cmd_var)', 'ls $(whoami)', 'ls `whoami`', 'cat `printf x`']) {
    const e = ex.explainCommand(c);
    assert.doesNotMatch(e.whatdo, /現在のフォルダ/, c);
    assert.match(e.whatdo, /埋め込まれたコマンドの結果/, c);
    assert.match(e.danger, /埋め込まれています/, c);
  }
});

test('統合で直した点: 引用符の中の空白で対象の名前がずれない', () => {
  assert.match(ex.explainCommand('ls "dir with space"/x').whatdo, /^dir with space\/x の中の/);
  assert.match(ex.explainCommand('cat "my file.txt"').whatdo, /^my file\.txt の中身/);
  assert.match(ex.explainCommand('cat ~/.e""nv').whatdo, /^~\/\.env の中身/);
});

test('カード索引: 大文字小文字を区別しない（Windows の小文字表記でも専用カードを選ぶ）', () => {
  assert.strictEqual(ex.lookupCard(CARDS, 'bash', 'invoke-webrequest https://x').cardId, 'bash-network-exfil');
  assert.strictEqual(ex.lookupCard(CARDS, 'bash', 'rm -rf build').cardId, 'bash-rm-recursive');
  assert.strictEqual(ex.lookupCard(CARDS, 'webfetch', 'localhost').cardId, 'webfetch-private-network');
  assert.strictEqual(ex.lookupCard(CARDS, 'bash', 'ls').cardId, 'default-bash');
});

test('CLI explain: now.md / now.html を書き、カード名と危険度を返す（管理用の行は本文に出さない）', () => {
  const dir = tmpdir();
  try {
    const r = spawnSync(process.execPath, [JS, 'explain', '--mode', 'bash', '--log-dir', dir, '--cards-dir', CARDS],
      { input: hook('rm -rf build && echo <b>hi</b>'), encoding: 'utf8' });
    assert.strictEqual(r.status, 0);
    assert.strictEqual(r.stdout.trim(), 'bash-rm-recursive\thigh');
    const html = fs.readFileSync(path.join(dir, 'now.html'), 'utf8');
    const md = fs.readFileSync(path.join(dir, 'now.md'), 'utf8');
    assert.match(html, /<pre class="action-cmd">rm -rf build &amp;&amp; echo &lt;b&gt;hi&lt;\/b&gt;<\/pre>/);
    assert.match(html, /<p class="whatdo-body">build を削除しようとしています。/);
    assert.match(html, /<p class="whatdo-danger">⚠️ フォルダごとの完全削除/);
    assert.doesNotMatch(html, /<p>---<\/p>|<p>risk: /);
    assert.doesNotMatch(html, /<b>hi<\/b>/);
    assert.match(md, /card=bash-rm-recursive/);
    assert.match(md, /🗑 これは何をする？/);
    assert.doesNotMatch(md, /^title: /m);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('CLI placeholder: 既にある now.html は上書きしない', () => {
  const dir = tmpdir();
  try {
    spawnSync(process.execPath, [JS, 'placeholder', '--log-dir', dir]);
    assert.match(fs.readFileSync(path.join(dir, 'now.html'), 'utf8'), /見守り中です/);
    fs.writeFileSync(path.join(dir, 'now.html'), 'REAL');
    spawnSync(process.execPath, [JS, 'placeholder', '--log-dir', dir]);
    assert.strictEqual(fs.readFileSync(path.join(dir, 'now.html'), 'utf8'), 'REAL');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('CLI は壊れた入力でも止まらない（表示専用）', () => {
  const dir = tmpdir();
  try {
    const r = spawnSync(process.execPath, [JS, 'explain', '--mode', 'bash', '--log-dir', dir, '--cards-dir', path.join(dir, 'none')],
      { input: '{not json', encoding: 'utf8' });
    assert.strictEqual(r.status, 0);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('observe モード: 本文を出さずツール名と場所だけ', () => {
  const dir = tmpdir();
  try {
    const raw = JSON.stringify({ tool_name: 'Task', tool_input: { prompt: 'ひみつの依頼内容' } });
    spawnSync(process.execPath, [JS, 'explain', '--mode', 'observe', '--log-dir', dir, '--cards-dir', CARDS], { input: raw });
    const md = fs.readFileSync(path.join(dir, 'now.md'), 'utf8');
    assert.match(md, /AI が Task を使おうとしています/);
    assert.match(md, /subagent\/task 作成/);
    assert.doesNotMatch(md, /ひみつの依頼内容/);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('mac の見張り: node が無いときは簡易表示に切り替わる', { skip: process.platform === 'win32' ? 'mac 専用' : false }, () => {
  const dir = tmpdir();
  try {
    const script = `set -u; log_dir(){ printf '%s\\n' "${dir}"; }; audit_log(){ :; }; export MODE=bash RAW_INPUT='${hook('echo <x> > 出力.txt').replace(/'/g, "'\\''")}'; source "${path.join(REPO, 'scripts/macos/lib/explainer.sh')}"; explain`;
    spawnSync('bash', ['-c', script], { env: { ...process.env, AI_SAFE_EXPLAINER_NODE: '/nonexistent/node' } });
    const md = fs.readFileSync(path.join(dir, 'now.md'), 'utf8');
    const html = fs.readFileSync(path.join(dir, 'now.html'), 'utf8');
    assert.match(md, /card=fallback/);
    assert.match(md, /echo <x> > 出力\.txt/);
    assert.match(html, /echo &lt;x&gt; &gt; 出力\.txt/);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
