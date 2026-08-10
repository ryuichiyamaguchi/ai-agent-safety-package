#!/usr/bin/env node
// フック入力（JSON）を `plutil -p` と同じ見た目のテキストに直す。
//
// なぜ必要か:
//   ガードは Claude Code から渡されるフック入力を読んで中身を検査する。読み取りに
//   macOS の `plutil -p` を使っていたが、**macOS 14 (Sonoma) では `-p` が JSON を
//   受け付けず必ず失敗する**（ファイル指定でも標準入力でも同じ。macOS 26 では成功する）。
//   読めない＝検査できないので設計どおり fail-closed になり、無害なプロンプトまで
//   含めて全部ブロックされ、AI がまったく使えなくなっていた（受講者の実機で発生）。
//
//   OS ごとの当たり外れがある外部コマンドに fail-closed を直結させたのが誤りだった。
//   Node は元から必須（送信検査 Gateway 等で使う）なので、こちらへ寄せて OS 差を断つ。
//
// 出力形式について:
//   検査側の正規表現は `plutil -p` の出力を前提に組まれ、3 エンジン一致テストで
//   固定されている。だから**形式を変えずに再現する**のが必須要件。実機の挙動に合わせて:
//     - 辞書はキーをソートして `"key" => value`
//     - 配列は `0 => value` のように添字を付ける
//     - インデントは 2 スペース、閉じ括弧は親の深さに合わせる
//     - 空の配列・辞書は開き括弧と閉じ括弧だけを行に分けて出す
//     - **文字列はエスケープしない**（plutil -p は引用符も改行もタブも生のまま出す）
//     - null は <null>
'use strict';

function format(value, indent) {
  const pad = ' '.repeat(indent);
  const padInner = ' '.repeat(indent + 2);

  if (value === null || value === undefined) return '<null>';
  if (typeof value === 'string') return `"${value}"`;
  if (typeof value === 'number') return String(value);
  if (typeof value === 'boolean') return value ? 'true' : 'false';

  if (Array.isArray(value)) {
    if (value.length === 0) return `[\n${pad}]`;
    const lines = value.map((item, i) => `${padInner}${i} => ${format(item, indent + 2)}`);
    return `[\n${lines.join('\n')}\n${pad}]`;
  }

  if (typeof value === 'object') {
    // plutil はキーを並べ替えて出す。順序が変わると検査結果は変わらないが、
    // 出力を突き合わせる回帰テストのために揃えておく。
    const keys = Object.keys(value).sort();
    if (keys.length === 0) return `{\n${pad}}`;
    const lines = keys.map((k) => `${padInner}"${k}" => ${format(value[k], indent + 2)}`);
    return `{\n${lines.join('\n')}\n${pad}}`;
  }

  // 想定外の型は検査できないものとして扱う（呼び出し側が fail-closed する）。
  throw new TypeError(`unsupported value type: ${typeof value}`);
}

function renderPlutilP(json) {
  return format(json, 0);
}

module.exports = { renderPlutilP, format };

if (require.main === module) {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => { raw += chunk; });
  process.stdin.on('end', () => {
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (_) {
      // 壊れた JSON は読めない＝検査できない。呼び出し側の fail-closed に委ねる。
      process.exit(1);
    }
    try {
      process.stdout.write(`${renderPlutilP(parsed)}\n`);
    } catch (_) {
      process.exit(1);
    }
  });
  process.stdin.on('error', () => process.exit(1));
}
