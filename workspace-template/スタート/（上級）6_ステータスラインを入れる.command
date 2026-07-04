#!/bin/bash
# Claude の画面下に「cwd | model | コンテキスト使用量バー」を表示するステータスラインを入れる。
# claude と d-claude の両方に効く。元に戻すときは同じフォルダから uninstall 引数付きで実行するか、
# ~/.ai-safety/backups/statusline-* のバックアップから戻せる。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/install-statusline.sh"
if [ ! -f "$TARGET" ]; then
  echo "スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
echo "Claude の画面下にステータスライン（cwd｜モデル｜コンテキスト使用量バー）を表示します。"
echo ""
bash "$TARGET" install
ec=$?
echo ""
if [ $ec -eq 0 ]; then
  echo "完了しました。次に起動する Claude / d-claude から表示されます。"
else
  echo "問題が起きました（上のメッセージを確認してください）。"
fi
read -r -p "Enter キーで閉じます..." _
