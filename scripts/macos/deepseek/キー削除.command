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

echo ""
echo "PC 側の DeepSeek キーを削除します..."
if [ -f "$AUTH_FILE" ]; then
  rm -f "$AUTH_FILE"
  echo "削除しました: $AUTH_FILE"
else
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
