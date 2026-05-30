#!/usr/bin/env bash
# ============================================================
# 登録-初回だけ.command
# DeepSeek の API キーを保存する（初回1回だけ / Mac 版）
# ------------------------------------------------------------
# ・このファイルには API キーは書きません。実行時に入力した値を
#   ~/.deepseek-claude/auth に保存し、起動 .command がそこから読みます。
# ・Windows の setx 相当を、Mac では権限 600 のファイルで代替します
#   （平文を毎日使う起動ファイルに残さないための分離）。
# ・暗号化ではありません。漏えい対策は「少額チャージ + 授業後に
#   キー削除」で守ります。
# ============================================================
set -u

AUTH_DIR="$HOME/.deepseek-claude"
AUTH_FILE="$AUTH_DIR/auth"

echo ""
echo "DeepSeek の API キーを登録します。"
echo "（キーを貼り付け → Enter。入力は画面に表示されません）"
echo ""
# -s で非表示入力（キーが画面/履歴に残らない）
read -r -s -p "APIキー: " KEY
echo ""
if [ -z "${KEY:-}" ]; then
  echo ""
  echo "何も入力されませんでした。中止します。"
  read -r -p "Enter で閉じます..." _
  exit 1
fi

mkdir -p "$AUTH_DIR"
umask 077
printf '%s\n' "$KEY" > "$AUTH_FILE"
chmod 600 "$AUTH_FILE"

echo ""
echo "登録できました。保存先: $AUTH_FILE （権限 600 = 自分だけ読める）"
echo "次に「起動-Claude-DeepSeek.command」をダブルクリックしてください。"
echo ""
read -r -p "Enter で閉じます..." _
