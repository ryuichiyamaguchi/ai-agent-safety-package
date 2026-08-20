#!/bin/bash
# （上級）11_伏せた文章を元に戻す.command
#
# AI の返答をコピーしてからこれを押すと、__SECRET_1__ のような伏せ字を
# 元の文字（自分のメールアドレス・会社名など）に戻してクリップボードに書き戻します。
#
# 対応表は Mac の金庫（キーチェーン）に入っていて、既定 60 分で自動的に捨てます。
# 期限が切れていたら「期限切れです」と表示されるので、伏せるところからやり直してください。
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
node "$TARGET" --restore
echo ""
read -r -p "Enter キーで閉じます..." _
