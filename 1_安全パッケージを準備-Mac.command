#!/bin/bash
# 安全パッケージのインストール（薄いラッパー）。既存 install-one-click.command を呼ぶ。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HERE/scripts/macos/install-one-click.command"
if [ ! -f "$TARGET" ]; then
  echo "インストーラが見つかりません: $TARGET"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
bash "$TARGET"

# 準備が終わったら、次に使う「スタート」フォルダを自動で開く（迷わせない）。
START_DIR="$HOME/Documents/my-ai-workspace/スタート"
if [ -d "$START_DIR" ]; then
  echo ""
  echo "次に使うファイルはこのフォルダの中にあります:"
  echo "  $START_DIR"
  open "$START_DIR" 2>/dev/null || true
fi
