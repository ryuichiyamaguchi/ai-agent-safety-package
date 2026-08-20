#!/bin/bash
# 8_安全パッケージを最新版に更新.command
# GitHub の「最新 Release」から安全パッケージを取得して更新します（SHA-256 照合つき）。
# AI ツール本体（Codex / Claude Code / OpenCode）の更新は「9_AIツールを最新版に更新」で行います。
# 実体は .ai-safety/hooks/macos/fetch-update.command（ダウンロード→照合→展開→install）。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/fetch-update.command"
echo ""
echo " == 安全パッケージを最新版に更新します =="
echo " 最新版を GitHub から取得して更新します（ネット接続が必要です）。"
echo " ※ AI ツール本体の更新は「9_AIツールを最新版に更新」です。"
echo " 既存の設定はバックアップされてから上書きされます。"
echo ""
if [ ! -f "$TARGET" ]; then
  echo " 更新スクリプトが見つかりません: $TARGET"
  echo " 先に「1_安全パッケージを入れる」を実行してください。"
  echo ""
  read -n 1 -s -r -p "キーを押すと閉じます..."
  exit 1
fi
bash "$TARGET" "$WORKSPACE"
echo ""
read -n 1 -s -r -p "キーを押すと閉じます..."
