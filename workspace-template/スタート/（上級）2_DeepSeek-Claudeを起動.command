#!/bin/bash
# DeepSeek-Claude 起動（薄いラッパー）。既存のクリックスクリプトを呼ぶだけ。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/deepseek/起動-Claude-DeepSeek.command"
if [ ! -f "$TARGET" ]; then
  echo "DeepSeek 起動スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
bash "$TARGET"
