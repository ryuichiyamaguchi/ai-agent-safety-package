#!/bin/bash
# （上級）10_コピーした文章から秘密を伏せる.command
#
# いま「コピー」した文章の中から、API キー・メールアドレス・電話番号・クレジットカード番号
# らしき列などを見つけて伏せ字にし、そのままクリップボードに書き戻します。
# 外部の AI（ChatGPT / DeepSeek など）に貼り付ける直前に1回押してください。
#
# 元に戻せる伏せ字は __SECRET_1__ の形になります。AI の返答をコピーしてから
# 「（上級）11_伏せた文章を元に戻す」を押すと、元の文字に戻ります。
# 「トークン ↔ 原文」の対応表には本物の秘密が入るので、平文ファイルには置かず
# Mac の金庫（キーチェーン）に入れ、既定 60 分で自動的に捨てます。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/common/clipboard-mask.js"
if [ ! -f "$TARGET" ]; then
  echo "スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
node "$TARGET" --mask
echo ""
read -r -p "Enter キーで閉じます..." _
