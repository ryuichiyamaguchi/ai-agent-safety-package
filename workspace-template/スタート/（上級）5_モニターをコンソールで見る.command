#!/bin/bash
# 見守りモニター（コンソール版）。ブラウザを使わずターミナル内で見る上級向け。
# 通常は「5_見守りモニターを起動」を使ってください（ブラウザで見やすく表示）。
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
