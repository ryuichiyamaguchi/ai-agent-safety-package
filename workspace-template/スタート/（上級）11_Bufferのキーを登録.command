#!/bin/bash
# （上級）11_Bufferのキーを登録.command
# SNS の予約投稿サービス Buffer の API キーを登録します。
# 登録すると OpenCode から Buffer を操作できます（投稿の作成・予約・下書き、
# チャンネル一覧、実績の取得など）。
# キーは ~/.ai-safety/buffer-api-key.txt に保存します（環境変数は汚しません）。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
cd "$WORKSPACE" 2>/dev/null || true
echo ""
echo " Buffer（SNSの予約投稿サービス）の API キーを登録します。"
echo ""
echo " キーの取り方:"
echo "   1. ブラウザで  https://publish.buffer.com/settings/api  を開く"
echo "   2. Buffer にログインして API キーを作成"
echo "   3. 表示されたキーをコピー"
echo ""
echo " 登録するとできること:"
echo "   ・投稿の下書き作成・予約・キューの管理"
echo "   ・つないでいるSNSアカウント（チャンネル）の一覧"
echo "   ・投稿の実績（数値）の取得"
echo ""
echo " ★注意: SNS への投稿は取り消せません。"
echo "   AI が投稿しようとすると必ず確認が出ます。中身をよく読んでから許可してください。"
echo ""
printf "APIキーを貼り付けて Enter（登録をやめるなら何も入れずに Enter）: "
read -r KEY
if [ -z "$KEY" ]; then
  echo "何も入力されませんでした。中止します。"
  read -n 1 -s -r -p "キーを押すと閉じます..."
  exit 1
fi
mkdir -p "$HOME/.ai-safety"
printf '%s' "$KEY" > "$HOME/.ai-safety/buffer-api-key.txt"
chmod 600 "$HOME/.ai-safety/buffer-api-key.txt"
echo ""
echo " 登録できました。OpenCode を開き直すと Buffer が使えます。"
echo " 使うのをやめたいときは、このファイルを消してください:"
echo "   $HOME/.ai-safety/buffer-api-key.txt"
echo ""
read -n 1 -s -r -p "キーを押すと閉じます..."
