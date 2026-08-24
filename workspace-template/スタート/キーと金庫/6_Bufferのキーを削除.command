#!/bin/bash
# 6_Bufferのキーを削除.command
# 登録した Buffer の API キー を、この Mac から消します。
# ・Mac の金庫（キーチェーンの「ai-safety.buffer」）と、移行前の平文ファイルの両方を消します。
# ・PC 側を消しても、発行元のサイトではキーが生きています。
#   Buffer の設定画面（https://publish.buffer.com/settings/api）でも、そのキーを削除してください。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/../.." && pwd)"
cd "$WORKSPACE" 2>/dev/null || true

SERVICE="ai-safety.buffer"
LEGACY="$HOME/.ai-safety/buffer-api-key.txt"
FOUND=0

echo ""
echo " Buffer の API キー をこの Mac から削除します..."
if [ -x /usr/bin/security ] && /usr/bin/security delete-generic-password -a "$USER" -s "$SERVICE" >/dev/null 2>&1; then
  echo "  金庫から削除しました（キーチェーンの「$SERVICE」）"
  FOUND=1
fi
if [ -f "$LEGACY" ]; then
  rm -f "$LEGACY"
  echo "  ファイルを削除しました: $LEGACY"
  FOUND=1
fi
if [ "$FOUND" -eq 0 ]; then
  echo "  登録済みのキーは見つかりませんでした（すでに削除済みかもしれません）。"
fi

echo ""
echo " 【まだ終わりではありません】"
echo "   Buffer の設定画面（https://publish.buffer.com/settings/api）でも、そのキーを削除してください。"
echo ""
read -r -p "Enter キーで閉じます..." _
