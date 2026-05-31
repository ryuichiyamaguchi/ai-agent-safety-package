#!/bin/bash
# 見守りモニター起動（薄いラッパー）。既存 monitor.sh を呼ぶだけ。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/monitor.sh"
if [ ! -f "$TARGET" ]; then
  echo "起動スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
bash "$TARGET"
ec=$?
if [ $ec -ne 0 ]; then read -r -p "問題が起きました。Enter キーで閉じます..." _; fi
