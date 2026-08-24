#!/bin/bash
# 3_じぶんに合うAIを選ぶ.command
# 「どの AI を使えばいいの？」の説明ページ（docs/じぶんに合うAIを選ぶ.html）を
# ブラウザで開く（読むだけ・何も変更しません）。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/docs/じぶんに合うAIを選ぶ.html"
if [ ! -f "$TARGET" ]; then
  echo "説明ページが見つかりません: $TARGET"
  echo "「1_安全パッケージを最新版にする」を実行すると配置されます。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
open "$TARGET"
