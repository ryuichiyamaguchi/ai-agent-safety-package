#!/bin/bash
# 野良 d-claude 退治（薄いラッパー）。実体スクリプトを呼ぶだけ。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/野良d-claudeを退治.command"
if [ ! -f "$TARGET" ]; then
  echo "退治スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
bash "$TARGET" "$WORKSPACE"
