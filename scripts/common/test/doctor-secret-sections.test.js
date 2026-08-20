'use strict';
// 診断の「どのキーの話か」が節と一致しているかの回帰テスト。
//
// 実機（Windows）で起きたこと:
//   ■ 4. DeepSeek キーの状態
//     [OK] 金庫に登録済み（...\deepseek.dpapi）
//     [注意] 平文のキーファイルが残っています: ...\gemini-api-key.txt   ← Gemini の話が DeepSeek の節に出る
//   受講生が「DeepSeek の問題だ」と誤解するため、キーごとに正しい節へ分けた。
//
// ここで守りたいこと:
//   1. 診断.ps1 の「DeepSeek キーの状態」の節に、DeepSeek 以外のキーのファイル名が出ない
//   2. DeepSeek 以外のキー（Gemini / Gemini 有料 / Buffer）専用の節がある
//   3. 節番号が重複せず 1 から連番になっている
//   4. doctor.ps1 / doctor.sh の平文残骸の報告は、いまもキー名（ラベル）付きで出る
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..', '..');
const shindanPath = path.join(root, 'scripts', 'windows', '診断.ps1');
const shindan = fs.readFileSync(shindanPath, 'utf8');

// `Line "■ 4. ..."` の行を頼りに節へ切り分ける。
function sections(text) {
  const out = [];
  const re = /^Line\s+"■\s*(\d+)\.\s*([^"]*)"/gm;
  const hits = [];
  let m;
  while ((m = re.exec(text)) !== null) hits.push({ number: Number(m[1]), title: m[2], at: m.index });
  for (let i = 0; i < hits.length; i += 1) {
    const end = i + 1 < hits.length ? hits[i + 1].at : text.length;
    out.push(Object.assign({}, hits[i], { body: text.slice(hits[i].at, end) }));
  }
  return out;
}

const NON_DEEPSEEK_KEY_FILES = ['gemini-api-key.txt', 'gemini-api-key-paid.txt', 'buffer-api-key.txt'];

test('診断.ps1: DeepSeek の節に他のキーのファイル名を出さない', () => {
  const deepseek = sections(shindan).find((s) => s.title.includes('DeepSeek キーの状態'));
  assert.ok(deepseek, '「DeepSeek キーの状態」の節が見つからない');
  for (const f of NON_DEEPSEEK_KEY_FILES) {
    assert.ok(!deepseek.body.includes(f),
      `DeepSeek の節に ${f} の話が混ざっている（受講生が DeepSeek の問題だと誤解する）`);
  }
  assert.ok(deepseek.body.includes('deepseek.dpapi') && deepseek.body.includes('.deepseek-claude'),
    'DeepSeek の節では DeepSeek の保管先だけを見ること');
});

test('診断.ps1: DeepSeek 以外のキー専用の節がある', () => {
  const other = sections(shindan).find((s) => NON_DEEPSEEK_KEY_FILES.every((f) => s.body.includes(f)));
  assert.ok(other, 'AIコーチ（Gemini）/ Gemini 有料 / Buffer をまとめて見る節が無い');
  const deepseek = sections(shindan).find((s) => s.title.includes('DeepSeek キーの状態'));
  assert.notStrictEqual(other.number, deepseek.number, 'その節が DeepSeek の節であってはならない');
  for (const dpapi of ['gemini.dpapi', 'gemini-paid.dpapi', 'buffer.dpapi']) {
    assert.ok(other.body.includes(dpapi), `${dpapi}（金庫側）の状態も同じ節で見ること`);
  }
});

test('診断.ps1: 節番号は 1 から連番で重複しない', () => {
  const numbers = sections(shindan).map((s) => s.number);
  assert.ok(numbers.length >= 5, '節が取れていない');
  assert.deepStrictEqual(numbers, numbers.map((_, i) => i + 1),
    `節番号が連番でない: ${numbers.join(',')}`);
});

// v1.17.1: 「金庫へ書けなかった」を doctor で見せる。ここが見えなかったせいで、
// Windows 実機のファイル一覧をもらうまで原因を切り分けられなかった。
test('doctor.ps1 / doctor.sh / 診断.ps1: 金庫への書き込み失敗を必ず表示する', () => {
  const ps1 = fs.readFileSync(path.join(root, 'scripts', 'windows', 'doctor.ps1'), 'utf8');
  const sh = fs.readFileSync(path.join(root, 'scripts', 'macos', 'doctor.sh'), 'utf8');
  // Windows 側は移行ログを直接 grep する。mac 側は secret-migrate.js --status の
  // writeFailures（同じ抽出を JS 側で済ませたもの）を読む。入口は違うが情報源は同じ。
  for (const [name, body] of [['doctor.ps1', ps1], ['診断.ps1', shindan]]) {
    assert.ok(/vault-write-failed/.test(body), `${name}: 書き込み失敗の記録を見ていない`);
  }
  assert.ok(sh.includes('writeFailures'), 'doctor.sh: 書き込み失敗の記録を見ていない');
  // 失敗の中身（制限時間・所要時間・終了コード）まで出すこと。「失敗しました」だけでは切り分けられない。
  for (const [name, body] of [['doctor.ps1', ps1], ['doctor.sh', sh]]) {
    for (const field of ['timeoutMs', 'elapsedMs']) {
      assert.ok(body.includes(field), `${name}: ${field} を表示していない`);
    }
  }
  // ConvertFrom-Json は ISO8601 の ts を DateTime にする。`$ev.ts + " "` と書くと
  // TimeSpan の加算とみなされて整形が丸ごと失敗し、生の JSON が出る（実際に踏んだ）。
  assert.ok(ps1.includes('[string]$ev.ts'),
    'doctor.ps1: ts は [string] で固定すること（DateTime との加算で整形が壊れる）');
  // doctor は自分の診断ログのため AI_SAFE_LOG_DIR を差し替える。案内するパスは移行ログの既定の置き場。
  assert.ok(sh.includes('$HOME/.ai-safety/logs/secret-migrate-events.jsonl'),
    'doctor.sh: 案内するログの場所が doctor-logs になっていないこと');
});

test('doctor.ps1 / doctor.sh: 平文の残骸はキー名つきで報告する', () => {
  const ps1 = fs.readFileSync(path.join(root, 'scripts', 'windows', 'doctor.ps1'), 'utf8');
  const sh = fs.readFileSync(path.join(root, 'scripts', 'macos', 'doctor.sh'), 'utf8');

  // Windows: 1 キー 1 行で、行の名前に $item.Name を必ず含める。
  assert.ok(/Add-Result\s+\("secrets: "\s*\+\s*\$item\.Name\)\s+\$false\s+\("平文のまま残っています/.test(ps1),
    'doctor.ps1 が平文残骸をキー名つきで報告していない');
  // mac: ラベル（$_label）を必ず添えて出す。
  assert.ok(/WARN secrets: %s がまだ平文のままです/.test(sh) && /"\$_label"/.test(sh),
    'doctor.sh が平文残骸をキー名つきで報告していない');
  // 両 OS とも DeepSeek の節に他キーをぶら下げる作りになっていない（キー表を回すだけ）。
  assert.ok(sh.includes('j.leftovers'), 'doctor.sh はキーごとの一覧を回して報告すること');
});
