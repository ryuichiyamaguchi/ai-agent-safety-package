#!/bin/bash
# この Mac の Claude と Codex の「全体設定」に、危険コマンドのガードを反映する（ワンクリック）。
# どのフォルダから起動しても、rm -r / cat .env / curl|sh などの危険操作が止まるようになる。
# 既存の設定は壊さず、反映前に自動でバックアップを取る。元に戻すときは「（上級）8_グローバル禁止を解除」。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/apply-global-guard.sh"
if [ ! -f "$TARGET" ]; then
  echo "スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
echo "この Mac で Claude と Codex をどのフォルダから起動しても、危険コマンド（rm -r / cat .env / curl|sh / 外部送信など）を止めます。"
echo ""
bash "$TARGET"
ec=$?
echo ""
if [ $ec -eq 0 ]; then
  echo "完了しました。次に起動する Claude／Codex から反映されます。"
  echo "（元に戻したいときは「（上級）8_グローバル禁止を解除」を実行してください。）"
else
  echo "問題が起きました（上のメッセージを確認してください）。"
fi
read -r -p "Enter キーで閉じます..." _
