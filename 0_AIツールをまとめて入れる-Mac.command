#!/bin/bash
# 0_AIツールをまとめて入れる（Mac・薄い補助）。
# Codex CLI / Claude Code / OpenCode / agy をまとめて入れる（入っているものは更新する）。
# 実体はスタート「2_AIツールをまとめて入れる」と同じ scripts/macos/update-ai-tools.sh
# （v1.19.5 で 1 本にまとめた。以前はここに npm の導入処理の写しがあり、agy は入れていなかった）。
# Claude Code は @latest、Playwright（d-claude / OpenCode のブラウザ操作の部品）も事前に入れる
# （playwright-prefetch.js）。いずれも update-ai-tools.sh の中で行う。
# ※ ログイン（codex login 等）は本人の操作が必要なため、ここでは行わない。
set -u
PKG_HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$PKG_HERE/scripts/macos/update-ai-tools.sh"
if [ ! -f "$TARGET" ]; then
  echo "必要なファイルが見つかりません: $TARGET"
  echo "ZIP を最後まで展開してから、もう一度このファイルをダブルクリックしてください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
bash "$TARGET" "$PKG_HERE"
echo ""
read -r -p "Enter キーで閉じます..." _
