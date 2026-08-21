#!/bin/bash
# （上級）16_金庫に秘密をしまう.command
#
# 好きな名前を付けて、好きな文字列（合言葉・トークンなど）を
# Mac の「金庫」（キーチェーン）にしまいます。
# 取り出すときは「（上級）17_金庫から秘密を取り出す」を押します。
# 消すときは「（上級）18_金庫の秘密を消す」を押します。
#
# 中身は "ai-safety.user.<名前>" という名前でキーチェーンに入ります。
# 値を画面に出さない・コマンドの引数に置かない（＝ ps にも履歴にも残らない）ため、
# 保存は標準入力経由で secret-store.js に渡します。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
cd "$WORKSPACE" 2>/dev/null || true
TARGET="$WORKSPACE/.ai-safety/hooks/common/secret-store.js"
if [ ! -f "$TARGET" ]; then
  echo "スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi

echo ""
echo " ■ 金庫に秘密をしまう"
echo ""
echo " 「金庫」とは、Mac が最初から持っている鍵付きの引き出しのことです"
echo " （正式には「キーチェーン」と言います）。"
echo ""
echo "   ・この Mac にログインできる本人だけが開けられます。"
echo "   ・中身はディスクの上で暗号化されていて、そのままでは読めません。"
echo "   ・ファイルに書いたときと違い、他のアプリや AI が勝手に覗くことはできません。"
echo ""
echo " ふつうのファイル（メモ帳など）に書いた場合との違い:"
echo "   ファイル … 開けば誰でも読めます。AI に「このフォルダを見て」と言った時点で"
echo "               中身が読まれ、そのまま外へ送られてしまうことがあります。"
echo "   金庫   … 中身は暗号化され、取り出すには本人の操作が要ります。"
echo "               このパッケージの AI は金庫を読む権限を持っていません。"
echo ""
echo " ※ 入れられるのは短い文字列です（英数字なら約 90 文字、日本語なら約 30 文字まで）。"
echo "    長い文章は入りません。合言葉や API キーのような短いものを入れてください。"
echo ""

printf "この秘密に付ける名前を入力して Enter（やめるなら何も入れずに Enter）: "
read -r NAME
if [ -z "$NAME" ]; then
  echo "何も入力されませんでした。中止します。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi

echo ""
echo " 次に、しまいたい中身を入力します。"
echo " 入力した文字は画面に出ません（肩越しに覗かれても見えないようにするためです）。"
printf "中身を入力（または貼り付け）して Enter: "
read -r -s VALUE
echo ""
if [ -z "$VALUE" ]; then
  echo "何も入力されませんでした。中止します。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi

echo ""
echo " 金庫にしまっています..."
if printf '%s' "$VALUE" | node "$TARGET" --user-set "$NAME" >/dev/null; then
  VALUE=""
  echo ""
  # 変数名の直後に日本語が続く形（"$NAME」"）は bash 3.2 が変数名を取り違えるので printf を使う。
  printf ' しまえました。名前は「%s」です。\n' "$NAME"
  echo ""
  echo " 取り出したいときは:"
  echo "   「（上級）17_金庫から秘密を取り出す」をダブルクリック"
  echo "   → 一覧から番号で選ぶと、中身がクリップボードに入ります。"
  echo "     （画面には出しません。貼り付けたい場所で ⌘+V を押してください）"
  echo ""
  echo " いらなくなったら「（上級）18_金庫の秘密を消す」で消せます。"
else
  VALUE=""
  echo ""
  echo " しまえませんでした。上のメッセージを確認してください。"
  echo " 名前に使えるのは 英数字・ひらがな・カタカナ・漢字・ー・-・_ の 1〜40 文字です。"
fi

echo ""
read -r -p "Enter キーで閉じます..." _
