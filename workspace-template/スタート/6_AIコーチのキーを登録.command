#!/bin/bash
# 6_AIコーチのキーを登録.command
# 見守りモニターの「AIコーチ」が使う、無料の Gemini API キーを登録します。
# キーは ~/.ai-safety/gemini-api-key.txt に保存します（環境変数は汚しません）。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
cd "$WORKSPACE" 2>/dev/null || true
echo ""
echo " AIコーチ用の無料 Gemini API キーを登録します。"
echo ""
echo " キーの取り方:"
echo "   1. ブラウザで  https://aistudio.google.com/apikey  を開く"
echo "   2. Google でログインして「Create API key（APIキーを作成）」"
echo "   3. 表示されたキーをコピー"
echo ""
printf "APIキーを貼り付けて Enter: "
read -r KEY
if [ -z "$KEY" ]; then
  echo "何も入力されませんでした。中止します。"
  read -n 1 -s -r -p "キーを押すと閉じます..."
  exit 1
fi
mkdir -p "$HOME/.ai-safety"
printf '%s' "$KEY" > "$HOME/.ai-safety/gemini-api-key.txt"
chmod 600 "$HOME/.ai-safety/gemini-api-key.txt"
echo ""
echo " 登録できました。見守りモニターを開き直すと、AIコーチが使えます。"
echo ""
read -n 1 -s -r -p "キーを押すと閉じます..."
