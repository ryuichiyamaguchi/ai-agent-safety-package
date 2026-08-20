#!/bin/bash
# 好きなフォルダを「AI が安全に使える作業フォルダ」にする（ワンクリック）。
# 卒業後、my-ai-workspace 以外のフォルダ（案件ごとのフォルダなど）で作業したいときに使う。
# フォルダ選択ダイアログで選んだフォルダに、安全ルール・ガード・安全ランチャー・
# スタートフォルダ・説明書・信頼ダイアログの登録をまとめて入れる。
# ホーム直下やシステムフォルダなど、危険な場所を選んだときは警告して中止する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/protect-folder.sh"
if [ ! -f "$TARGET" ]; then
  echo "スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
echo "新しく作業したいフォルダを選ぶと、そのフォルダを AI が安全に使える状態にします。"
echo "（案件ごとに 1 つフォルダを作って、そこを選ぶのがおすすめです。）"
echo ""
bash "$TARGET"
ec=$?
echo ""
if [ $ec -ne 0 ]; then
  echo "終了しました（上のメッセージを確認してください）。"
fi
read -r -p "Enter キーで閉じます..." _
