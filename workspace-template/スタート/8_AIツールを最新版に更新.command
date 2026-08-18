#!/bin/bash
# 8_AIツールを最新版に更新.command
# AI ツール本体 (Codex CLI / Claude Code / OpenCode) を npm でまとめて更新します。
# Claude Code だけは最新版ではなく「動作確認済みの版」に合わせます（版の表はパッケージ更新で配布）。
# 安全パッケージ本体の更新は「7_安全パッケージを最新版に更新」です。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/update-ai-tools.sh"
if [ ! -f "$TARGET" ]; then
  echo " 更新スクリプトが見つかりません: $TARGET"
  echo " 先に「7_安全パッケージを最新版に更新」（または 1_安全パッケージを準備）を実行してください。"
  echo ""
  read -n 1 -s -r -p "キーを押すと閉じます..."
  exit 1
fi
bash "$TARGET" "$WORKSPACE"
echo ""
read -n 1 -s -r -p "キーを押すと閉じます..."
