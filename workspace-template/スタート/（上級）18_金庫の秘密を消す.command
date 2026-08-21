#!/bin/bash
# （上級）18_金庫の秘密を消す.command
#
# 「（上級）16_金庫に秘密をしまう」でしまったものを、この Mac から消します。
# Mac の金庫（キーチェーンの「ai-safety.user.<名前>」）と、名前の一覧
# （~/.ai-safety/user-secrets.index）の両方から消します。
# ※ この金庫の中身しか消しません。AIコーチや Buffer のキーには触りません。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
cd "$WORKSPACE" 2>/dev/null || true
TARGET="$WORKSPACE/.ai-safety/hooks/common/secret-store.js"
if [ ! -f "$TARGET" ]; then
  echo "スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi

echo ""
echo " ■ 金庫の秘密を消す"
echo ""
echo " 消したものは元に戻せません。必要なら先に"
echo " 「（上級）17_金庫から秘密を取り出す」で控えを取ってください。"
echo ""

LIST="$(node "$TARGET" --user-list 2>/dev/null || true)"
COUNT=0
while IFS= read -r _line; do
  [ -z "$_line" ] && continue
  NAMES[$COUNT]="$_line"
  COUNT=$((COUNT + 1))
done <<EOF
$LIST
EOF

if [ "$COUNT" -eq 0 ]; then
  echo " 金庫にはまだ何も入っていません。消すものはありません。"
  echo ""
  read -r -p "Enter キーで閉じます..." _
  exit 0
fi

echo " しまってあるもの:"
_i=0
while [ "$_i" -lt "$COUNT" ]; do
  echo "   $((_i + 1))) ${NAMES[$_i]}"
  _i=$((_i + 1))
done
echo ""
printf "消したいものの番号を入力して Enter（やめるなら何も入れずに Enter）: "
read -r CHOICE
if [ -z "$CHOICE" ]; then
  echo "中止します。"
  read -r -p "Enter キーで閉じます..." _
  exit 0
fi
case "$CHOICE" in
  ''|*[!0-9]*)
    echo "番号ではありません。中止します。"
    read -r -p "Enter キーで閉じます..." _
    exit 1
    ;;
esac
if [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$COUNT" ]; then
  echo "1 〜 $COUNT の番号を入力してください。中止します。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
NAME="${NAMES[$((CHOICE - 1))]}"

echo ""
printf "「%s」を消します。よろしければ y を入力して Enter: " "$NAME"
read -r ANSWER
if [ "$ANSWER" != "y" ] && [ "$ANSWER" != "Y" ]; then
  echo "中止しました。何も消していません。"
  read -r -p "Enter キーで閉じます..." _
  exit 0
fi

echo ""
if node "$TARGET" --user-remove "$NAME" >/dev/null; then
  echo " 消しました。金庫からも、名前の一覧からも消えています。"
else
  echo " 金庫には見つかりませんでした（すでに消えていたようです）。"
  echo " 名前の一覧からは片付けました。"
fi

echo ""
read -r -p "Enter キーで閉じます..." _
