#!/bin/bash
# この Mac の Claude 全体設定（~/.claude/settings.json）に、危険コマンドの deny を反映する（ワンクリック）。
# 既存の設定は壊さず、permissions.deny だけを追加する。反映前に自動でバックアップを取る。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/apply-global-deny.sh"
if [ ! -f "$TARGET" ]; then
  echo "スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
echo "この Mac で Claude をどのフォルダから起動しても、危険コマンド（curl / rm -rf / .env 読取 / git push / 外部送信など）を禁止します。"
echo ""
bash "$TARGET"
ec=$?
echo ""
if [ $ec -eq 0 ]; then
  echo "完了しました。次に起動する Claude から反映されます。"
else
  echo "問題が起きました（上のメッセージを確認してください）。"
fi
read -r -p "Enter キーで閉じます..." _
