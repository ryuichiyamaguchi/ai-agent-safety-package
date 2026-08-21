#!/bin/bash
# （上級）17_金庫から秘密を取り出す.command
#
# 「（上級）16_金庫に秘密をしまう」でしまった中身を、クリップボードに取り出します。
# 画面には中身を出しません（肩越しの覗き見と、画面録画への写り込みを防ぐため）。
# 取り出した中身は 60 秒後に自動でクリップボードから消します。ただし、その間に
# 別のものをコピーしていたら消しません（あなたのコピーを横取りしないため）。
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

# macOS には timeout コマンドが無いので、外部コマンドの時間制限は perl の alarm で作る。
# 使い方: run_limited <秒> <コマンド> [引数...]
run_limited() {
  perl -e 'alarm shift; exec @ARGV' "$@"
}

echo ""
echo " ■ 金庫から秘密を取り出す"
echo ""
echo " 金庫（Mac のキーチェーン）にしまってある中身を、クリップボードに入れます。"
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
  echo " 金庫にはまだ何も入っていません。"
  echo " 「（上級）16_金庫に秘密をしまう」でしまってから、もう一度お試しください。"
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
printf "取り出したいものの番号を入力して Enter（やめるなら何も入れずに Enter）: "
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
# 変数名の直後に日本語が続く形（"$NAME」"）は bash 3.2 が変数名を取り違えるので printf を使う。
printf ' 「%s」を取り出しています...\n' "$NAME"
if node "$TARGET" --user-copy "$NAME" >/dev/null; then
  echo ""
  echo " クリップボードに入れました。貼り付けたい所で ⌘+V を押してください。"
  echo " （中身は画面に出していません）"
  echo ""
  echo " ★ 60 秒後に、クリップボードから自動で消します。"
  echo "   そのあいだに別のものをコピーしていたら、そちらは消しません。"
  echo "   （いま入れた中身がクリップボードに残っているときだけ消します）"
  # 消し忘れ防止の後始末。ここで持つのは「中身そのもの」ではなく指紋（ハッシュ）だけ。
  # 中身を変数にも引数にも置かないので、ps にも履歴にも残らない。
  # trap '' HUP と disown で、この窓を閉じても 60 秒後の後始末が生き残るようにする
  # （nohup と同じ効果を、外部コマンドを増やさずに得る）。
  (
    trap '' HUP INT TERM
    BEFORE="$(run_limited 10 /usr/bin/pbpaste 2>/dev/null | shasum 2>/dev/null | awk '{print $1}')"
    sleep 60
    AFTER="$(run_limited 10 /usr/bin/pbpaste 2>/dev/null | shasum 2>/dev/null | awk '{print $1}')"
    if [ -n "$BEFORE" ] && [ "$BEFORE" = "$AFTER" ]; then
      printf '' | run_limited 10 /usr/bin/pbcopy 2>/dev/null
    fi
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
else
  echo ""
  echo " 取り出せませんでした。金庫に見つからないか、金庫を開けませんでした。"
  echo " 「（上級）16_金庫に秘密をしまう」でしまい直してください。"
fi

echo ""
read -r -p "Enter キーで閉じます..." _
