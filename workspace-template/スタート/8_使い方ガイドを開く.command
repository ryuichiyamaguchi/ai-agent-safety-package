#!/bin/bash
# 8_使い方ガイドを開く.command
# 安全パッケージの使い方ガイド（docs/ai-agent-safety-package-explained.html）を
# ブラウザで開く（読むだけ・何も変更しません）。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/docs/ai-agent-safety-package-explained.html"
if [ ! -f "$TARGET" ]; then
  echo "使い方ガイドが見つかりません: $TARGET"
  echo "「1_安全パッケージを最新版にする」を実行すると配置されます。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
open "$TARGET"
