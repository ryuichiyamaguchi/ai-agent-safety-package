#!/bin/bash
# 10_作業フォルダを元に戻す.command
#
# AI が作業フォルダの中のファイルを書き換えたり消したりしてしまったときに、
# AI を起動する直前に自動で取っておいた「控え」の時点へ戻します。
#   ・控えのあとで書き換えられた／消されたファイル → 控えの中身に戻します
#   ・控えのあとで新しくできたファイル → 消さずに .ai-safety/snapshots/set-aside/<日時>/ へ移します
#   ・戻す直前の状態も自動で控えに取るので、「元に戻す」自体もあとから取り消せます
# 一覧 → 番号 → 変わる内容の確認 → y で実行、の流れは
# .ai-safety/hooks/common/workspace-snapshot.js（wizard）が正本。このボタンは呼ぶだけ。
# くわしくは docs/14_作業フォルダを元に戻す.md
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/common/workspace-snapshot.js"
if [ ! -f "$TARGET" ]; then
  echo "スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを最新版にする」を実行してください。"
  echo ""
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "node コマンドが見つかりません。先に Node.js（LTS 版）を入れてください。"
  echo ""
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
node "$TARGET" wizard --workspace "$WORKSPACE"
echo ""
read -r -p "Enter キーで閉じます..." _
