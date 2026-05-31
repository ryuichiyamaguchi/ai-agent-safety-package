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
