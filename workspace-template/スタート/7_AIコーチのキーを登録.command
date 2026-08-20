#!/bin/bash
# 7_AIコーチのキーを登録.command
# 見守りモニターで安全イベントやAI回答を相談するときに使う、無料の Gemini API キーを登録します。
# v1.17.0 から、キーは Mac の金庫（キーチェーン）にしまいます。
#   保存先: キーチェーンの「ai-safety.gemini」
#   ・値はコマンドの引数に書かないので、シェルの履歴にも ps にも残りません。
#   ・「キーチェーンアクセス」アプリで ai-safety を検索すると、実物が見られます
#     （見るときにログインパスワードを聞かれる = 本人以外は読めない証拠）。
# 金庫が使えない古い環境では、これまでどおり ~/.ai-safety/gemini-api-key.txt（権限600）に保存します。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
cd "$WORKSPACE" 2>/dev/null || true
echo ""
echo " 安全イベント・AI回答相談用の無料 Gemini API キーを登録します。"
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

SERVICE="ai-safety.gemini"
LEGACY="$HOME/.ai-safety/gemini-api-key.txt"
SAVED=""

if [ -x /usr/bin/security ]; then
  # 金庫に入れる値は "v1:" + base64 の封筒に包む（非 ASCII で 16 進表示になるのを防ぐ）。
  ENVELOPE="v1:$(printf '%s' "$KEY" | base64 | tr -d '\n')"
  # -w を値なしで末尾に置くと対話プロンプトになる。標準入力から本文と確認の2回を流し込む。
  if printf '%s\n%s\n' "$ENVELOPE" "$ENVELOPE" \
    | /usr/bin/security add-generic-password -U -a "$USER" -s "$SERVICE" -w >/dev/null 2>&1; then
    # 書いた直後に読み戻して一致を検証する（ここを飛ばすと「消したのに入っていない」事故になる）。
    BACK="$(/usr/bin/security find-generic-password -a "$USER" -s "$SERVICE" -w 2>/dev/null \
      | sed 's/^v1://' | base64 --decode 2>/dev/null)"
    if [ "$BACK" = "$KEY" ]; then
      SAVED="keychain"
      # 一致したときだけ、古い平文を消す。
      rm -f "$LEGACY" 2>/dev/null || true
    fi
  fi
fi

if [ -z "$SAVED" ]; then
  mkdir -p "$HOME/.ai-safety"
  chmod 700 "$HOME/.ai-safety" 2>/dev/null || true
  printf '%s' "$KEY" > "$LEGACY"
  chmod 600 "$LEGACY"
  SAVED="file"
fi

echo ""
if [ "$SAVED" = "keychain" ]; then
  echo " 金庫にしまいました（Mac のキーチェーンの「$SERVICE」）。"
  echo " 「キーチェーンアクセス」アプリで ai-safety を検索すると実物を確認できます。"
else
  echo " この Mac では金庫を使えなかったため、ファイルに保存しました（自分だけ読める権限にしています）。"
  echo "   $LEGACY"
fi
echo " 見守りモニターを開き直すと、安全イベントや取得済みAI回答をAIに相談できます。"
echo ""
read -n 1 -s -r -p "キーを押すと閉じます..."
