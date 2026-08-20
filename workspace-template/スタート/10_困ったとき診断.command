#!/bin/bash
# 10_困ったとき診断.command
# 安全装置が効いているかを自己診断します（読み取り専用・何も変更しません）。
# 実体は .ai-safety/hooks/macos/doctor.sh。PASS=正常 / FAIL=問題あり。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/doctor.sh"
echo ""
echo " == 診断（読み取り専用・何も変更しません）=="
echo " うまく動かないとき、この結果を講師や AI コーチに送ってください。"
echo " 見かた: PASS = 正常 / FAIL = 問題あり / SKIP・INFO = 参考情報"
echo ""
if [ ! -f "$TARGET" ]; then
  echo " 診断スクリプトが見つかりません: $TARGET"
  echo " 先に「1_安全パッケージを準備」を実行してください。"
  echo ""
  read -n 1 -s -r -p "キーを押すと閉じます..."
  exit 1
fi
if bash "$TARGET" "$WORKSPACE"; then
  echo ""
  echo " すべて正常です（FAIL はありませんでした）。"
else
  echo ""
  echo " 問題が見つかりました（上の FAIL 行）。この画面の内容をそのまま講師や AI コーチに送ってください。"
fi
echo ""
read -n 1 -s -r -p "キーを押すと閉じます..."
