#!/bin/bash
# AIアシスト承認つきセーフ Claude 起動（薄いラッパー）。
# 既存 launch-claude-safe.sh を AI_SAFE_ASSISTED_APPROVAL=1 で呼ぶだけ。
# グレー（決定的に危険でない）コマンドは「2つのAI判定（提案＋Geminiの検証）」で、
# 両方OKなら自動承認・迷うときだけ確認。危険コマンド（curl/.env/rm -rf 等）は常にブロック（不変）。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/launch-claude-safe.sh"
if [ ! -f "$TARGET" ]; then
  echo "起動スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
echo "AIアシスト承認モードで起動します（定型は自走・危険はブロック・迷うものだけ確認）。"
export AI_SAFE_ASSISTED_APPROVAL=1
bash "$TARGET" "$WORKSPACE"
ec=$?
if [ $ec -ne 0 ]; then read -r -p "問題が起きました。Enter キーで閉じます..." _; fi
