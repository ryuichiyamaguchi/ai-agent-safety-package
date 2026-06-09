#!/bin/bash
# セーフ Codex オート起動（薄いラッパー）。launch-codex-safe.sh を --auto 付きで呼ぶだけ。
# doctor の隔離チェック(金庫)が green のときだけ承認プロンプトが省かれる。
# 確認できない場合は launcher が理由を表示して通常の都度承認モードで起動する(フェイルクローズ)。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/launch-codex-safe.sh"
if [ ! -f "$TARGET" ]; then
  echo "起動スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
echo "オートモード: 安全確認（金庫）が取れたときだけ、承認の手間を省いて起動します。"
echo "確認できない場合は、自動で通常の都度承認モードになります。"
bash "$TARGET" "$WORKSPACE" "" --auto
ec=$?
if [ $ec -ne 0 ]; then read -r -p "問題が起きました。Enter キーで閉じます..." _; fi
