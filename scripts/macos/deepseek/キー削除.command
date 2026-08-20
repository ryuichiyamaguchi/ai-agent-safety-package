#!/usr/bin/env bash
# ============================================================
# キー削除.command
# 授業後のお片付け用。PC 側に保存した DeepSeek の API キーを消します（Mac 版）。
# ------------------------------------------------------------
# ・ダブルクリック1回で ~/.deepseek-claude/auth を削除します。
# ・PC 側を消すだけでは不十分です。DeepSeek の管理画面
#   （https://platform.deepseek.com/ の API keys）でも、
#   使ったキーを必ず Delete してください。
# ============================================================
set -u

AUTH_FILE="$HOME/.deepseek-claude/auth"

SERVICE="ai-safety.deepseek"
FOUND=0

echo ""
echo "PC 側の DeepSeek キーを削除します..."
# 金庫（キーチェーン）側
if [ -x /usr/bin/security ] && /usr/bin/security delete-generic-password -a "$USER" -s "$SERVICE" >/dev/null 2>&1; then
  echo "金庫から削除しました（キーチェーンの「$SERVICE」）"
  FOUND=1
fi
# 旧平文側（移行前の PC・移行に失敗した PC のために必ず両方見る）
if [ -f "$AUTH_FILE" ]; then
  rm -f "$AUTH_FILE"
  echo "削除しました: $AUTH_FILE"
  FOUND=1
fi
if [ "$FOUND" -eq 0 ]; then
  echo "登録済みのキーは見つかりませんでした（既に削除済みかもしれません）。"
fi
# 空になった保管フォルダも片付ける（中身が無いときだけ）
rmdir "$HOME/.deepseek-claude" 2>/dev/null || true

echo ""
echo "【まだ終わりではありません】"
echo "  DeepSeek 管理画面（https://platform.deepseek.com/ の API keys）でも"
echo "  使ったキーを Delete してください。これで漏えい対策は完了です。"
echo ""
read -r -p "Enter で閉じます..." _
