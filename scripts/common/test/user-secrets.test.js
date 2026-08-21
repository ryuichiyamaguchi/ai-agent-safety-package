// 自由枠（受講生が名前を付けてしまう秘密）の検査。
//
// 方針は secret-store.test.js と同じ。金庫のモックは作らず、macOS では本物の
// キーチェーンをテスト専用の service 接頭辞 "ai-safety-test-<pid>." で使い、必ず後始末する。
// 実キー（ai-safety.gemini など）には一切触らない。
// macOS 以外 / 金庫が使えない環境では、金庫に触るテストだけを skip する
// （名前の検査と索引の検査は金庫が要らないので、どの OS でも走る）。
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const PREFIX = `ai-safety-test-${process.pid}.`;
process.env.AI_SAFE_KEYCHAIN_PREFIX = PREFIX;
// 索引ファイル（と Windows の DPAPI ファイル）の置き場もテスト専用に差し替える。
const SECRET_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-usersecrets-'));
process.env.AI_SAFE_SECRET_DIR = SECRET_DIR;

const store = require('../secret-store.js');

const canVault = process.platform === 'darwin' && store.available();
const skipVault = canVault ? false : 'OS の金庫を使えない環境のため skip（Windows DPAPI は Windows 実機で検証）';

const MADE = [];
function track(name) { if (MADE.indexOf(name) === -1) MADE.push(name); return name; }
function cleanupUser() {
  for (const n of MADE) { try { store.userRemove(n); } catch { /* ignore */ } }
  MADE.length = 0;
  try { fs.rmSync(store.userIndexPath(), { force: true }); } catch { /* ignore */ }
}

// ---- 名前のバリデーション（金庫に触らないのでどの OS でも走る） -------------
test('正しい名前は通る（英数字・かな・カタカナ・漢字・長音符・ハイフン・アンダースコア）', () => {
  const ok = [
    'note-token',
    'note_token',
    'メモ',
    'ノートのカギ',
    '合言葉',
    'コーヒー',           // 長音符
    'a',
    'あ'.repeat(40),      // ちょうど 40 文字
    'X1',
  ];
  for (const n of ok) assert.strictEqual(store.isValidUserName(n), true, `通るべき名前が弾かれた: ${n}`);
});

test('危ない名前・壊れた名前は必ず弾く', () => {
  const ng = [
    '',                 // 空文字
    '   ',              // 空白だけ
    'a b',              // 空白入り
    '../x',             // パス traversal
    '..',
    '.',
    'a/b',              // ディレクトリ区切り
    'a\\b',             // Windows のディレクトリ区切り
    'user.foo',         // 自由枠の接頭辞を偽装する形（"." を許さないので弾かれる）
    'foo.dpapi',
    'a\u0000b',         // 制御文字（NUL）
    'a\u001bb',         // 制御文字（ESC。端末への injection 防止）
    'a\nb',             // 改行（索引が 1 行 1 件なので致命的）
    'a\tb',
    'あ'.repeat(41),    // 41 文字
    'gemini!',          // 記号
    'a;b',
    'a$b',
    'a`b',
    'a*b',
    null,
    undefined,
    123,
  ];
  for (const n of ng) {
    assert.strictEqual(store.isValidUserName(n), false, `弾くべき名前が通った: ${JSON.stringify(n)}`);
  }
});

test('不正な名前は userSet / userGet / userRemove のどれでも例外になる', () => {
  for (const fn of [() => store.userSet('../x', 'v'), () => store.userGet('a/b'), () => store.userRemove('user.foo')]) {
    assert.throws(fn, /invalid user secret name/);
  }
});

// ---- 固定枠を壊していないこと --------------------------------------------
test('固定枠の窓口は従来どおり（固定表にない名前は受け付けない）', () => {
  assert.throws(() => store.get('unknown-secret'), /unknown secret name/);
  assert.throws(() => store.set('unknown-secret', 'x'), /unknown secret name/);
  // 固定枠の名前でも、自由枠の窓口からは固定枠に触れない（接頭辞が違う別物になる）。
  assert.strictEqual(store.isValidUserName('gemini'), true);
});

test('固定枠と自由枠は同じ名前でも別の場所（自由枠は固定枠に触れない）', { skip: skipVault }, () => {
  try {
    store.set('gemini', 'FIXED-SIDE-1234567890');
    assert.strictEqual(store.userGet('gemini'), null, '自由枠から固定枠が見えてはいけない');

    store.userSet(track('gemini'), 'USER-SIDE-1234567890');
    assert.strictEqual(store.get('gemini'), 'FIXED-SIDE-1234567890', '自由枠への書き込みが固定枠を上書きしてはいけない');
    assert.strictEqual(store.userGet('gemini'), 'USER-SIDE-1234567890');

    store.userRemove('gemini');
    assert.strictEqual(store.get('gemini'), 'FIXED-SIDE-1234567890', '自由枠の削除が固定枠を消してはいけない');
  } finally {
    try { store.remove('gemini'); } catch { /* ignore */ }
    cleanupUser();
  }
});

// ---- 索引 ----------------------------------------------------------------
test('索引には名前だけが入り、値は書かれない', { skip: skipVault }, () => {
  const secret = 'PROBE-VALUE-do-not-write-1234567890';
  try {
    store.userSet(track('メモ'), secret);
    const raw = fs.readFileSync(store.userIndexPath(), 'utf8');
    assert.ok(raw.includes('メモ'), '索引に名前が入っていない');
    assert.ok(!raw.includes(secret), '索引に値が書かれている（絶対にあってはならない）');
    if (process.platform !== 'win32') {
      assert.strictEqual(fs.statSync(store.userIndexPath()).mode & 0o777, 0o600, '索引は 600');
    }
  } finally {
    cleanupUser();
  }
});

test('索引の追加と削除（一覧は自由枠だけを返す）', { skip: skipVault }, () => {
  try {
    store.userSet(track('note-token'), 'token-value-1');
    store.userSet(track('合言葉'), 'token-value-2');

    let names = store.userList().filter((x) => x.exists).map((x) => x.name);
    assert.deepStrictEqual(names.sort(), ['note-token', '合言葉'].sort());

    store.userRemove('note-token');
    names = store.userList().map((x) => x.name);
    assert.deepStrictEqual(names, ['合言葉'], '削除したら索引からも消える');
  } finally {
    cleanupUser();
  }
});

test('索引にあるのに金庫に実体が無ければ「未登録」として扱う', { skip: skipVault }, () => {
  try {
    store.userSet(track('迷子'), 'value-1234567890');
    // 索引はそのままに、金庫の実体だけを消した状態を作る（手で security delete した等）。
    const backup = fs.readFileSync(store.userIndexPath(), 'utf8');
    store.userRemove('迷子');
    fs.writeFileSync(store.userIndexPath(), backup, { mode: 0o600 });

    const list = store.userList();
    const hit = list.find((x) => x.name === '迷子');
    assert.ok(hit, '索引にある名前は一覧に現れる');
    assert.strictEqual(hit.exists, false, '実体が無いことを示すこと（そのまま出して選ばせない）');
  } finally {
    cleanupUser();
  }
});

test('壊れた索引・不正な名前の行は黙って捨てる（読み込みで落ちない）', () => {
  try {
    fs.writeFileSync(store.userIndexPath(), '正しい名前\n../x\n\n   \nuser.foo\nもう一つ\n', { mode: 0o600 });
    const names = store.userList().map((x) => x.name);
    assert.deepStrictEqual(names, ['正しい名前', 'もう一つ']);
  } finally {
    try { fs.rmSync(store.userIndexPath(), { force: true }); } catch { /* ignore */ }
  }
});

// ---- 金庫への往復 ---------------------------------------------------------
test('自由枠へ set → get で往復する（ASCII / 日本語 / 記号）', { skip: skipVault }, () => {
  const cases = [
    ['note-token', 'sk-dummy-abcdefghijklmnopqrstuv'],
    ['合言葉', 'ひみつのあいことば'],
    ['記号', 'a"b\'c$d`e|f&g;h'],
    ['16進っぽい値', 'a'.repeat(64)],
  ];
  try {
    for (const [name, value] of cases) {
      store.userSet(track(name), value);
      assert.strictEqual(store.userGet(name), value, `往復に失敗: ${name}`);
    }
  } finally {
    cleanupUser();
  }
});

test('空の値は保存しない', { skip: skipVault }, () => {
  assert.throws(() => store.userSet('からっぽ', ''), /empty value/);
});

test('mac の 128 文字上限を超えたら、黙って切らずに分かる言葉で止める', { skip: skipVault }, () => {
  // 日本語は封筒（base64）で約 4 倍に膨らむので、40 文字ほどで上限に届く。
  assert.throws(() => store.userSet('長すぎ', 'あ'.repeat(60)), /長すぎて Mac の金庫に入りません/);
  // 途中まで書けてしまっていないこと（索引にも残らない）。
  assert.strictEqual(store.userList().some((x) => x.name === '長すぎ'), false);
});

test('remove すると exists が false になる', { skip: skipVault }, () => {
  try {
    store.userSet(track('消す予定'), 'value-1234567890');
    assert.strictEqual(store.userExists('消す予定'), true);
    store.userRemove('消す予定');
    assert.strictEqual(store.userExists('消す予定'), false);
  } finally {
    cleanupUser();
  }
});

test.after(() => {
  cleanupUser();
  try { store.remove('gemini'); } catch { /* ignore */ }
  fs.rmSync(SECRET_DIR, { recursive: true, force: true });
});
