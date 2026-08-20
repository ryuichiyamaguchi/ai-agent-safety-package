#!/bin/bash
# （上級）8_Bufferのキーを登録.command
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
# v1.17.0 から、キーは Mac の金庫（キーチェーンの「ai-safety.buffer」）にしまいます。
# 値はコマンドの引数に書かないので、シェルの履歴にも ps にも残りません。
SERVICE="ai-safety.buffer"
LEGACY="$HOME/.ai-safety/buffer-api-key.txt"
SAVED=""

if [ -x /usr/bin/security ]; then
  # 金庫に入れる値は "v1:" + base64 の封筒に包む（非 ASCII で 16 進表示になるのを防ぐ）。
  ENVELOPE="v1:$(printf '%s' "$KEY" | base64 | tr -d '\n')"
  # -w を値なしで末尾に置くと対話プロンプトになる。標準入力から本文と確認の2回を流し込む。
  if printf '%s\n%s\n' "$ENVELOPE" "$ENVELOPE" \
    | /usr/bin/security add-generic-password -U -a "$USER" -s "$SERVICE" -w >/dev/null 2>&1; then
    # 書いた直後に読み戻して一致を検証する。
    BACK="$(/usr/bin/security find-generic-password -a "$USER" -s "$SERVICE" -w 2>/dev/null \
      | sed 's/^v1://' | base64 --decode 2>/dev/null)"
    if [ "$BACK" = "$KEY" ]; then
      SAVED="keychain"
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
else
  echo " この Mac では金庫を使えなかったため、ファイルに保存しました: $LEGACY"
fi
echo " OpenCode を開き直すと Buffer が使えます。"
echo " 使うのをやめたいときは「（上級）13_Bufferのキーを削除」をダブルクリックしてください。"
echo ""
read -n 1 -s -r -p "キーを押すと閉じます..."
