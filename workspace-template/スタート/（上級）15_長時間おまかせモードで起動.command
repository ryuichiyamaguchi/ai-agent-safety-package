#!/bin/bash
# 長時間おまかせモード（目を離して AI に長く作業させる）で Claude を起動する。
# 承認を省ける理由は「OS の壁（サンドボックス）があるから」なので、壁が使える環境
# （いまは Mac）と、壁が効く作業フォルダでしか起動しない。deny 床は外していない。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/launch-claude-longrun.sh"
if [ ! -f "$TARGET" ]; then
  echo "スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
bash "$TARGET" "$WORKSPACE"
ec=$?
echo ""
if [ $ec -ne 0 ]; then
  echo "起動しませんでした（上のメッセージを確認してください）。"
fi
read -r -p "Enter キーで閉じます..." _
