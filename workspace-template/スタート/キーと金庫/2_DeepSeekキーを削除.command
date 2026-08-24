#!/bin/bash
# DeepSeek キー削除（薄いラッパー）。既存のクリックスクリプトを呼ぶだけ。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/../.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/deepseek/キー削除.command"
if [ ! -f "$TARGET" ]; then
  echo "DeepSeek 起動スクリプトが見つかりません: $TARGET"
  echo "先に「インストーラー（install-one-click）」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
bash "$TARGET"
