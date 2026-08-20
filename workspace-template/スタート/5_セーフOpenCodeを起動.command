#!/bin/bash
# セーフ OpenCode 起動（薄いラッパー）。既存の安全起動口 oc-safe をそのまま呼ぶ。
#
# なぜ oc-safe を呼ぶのか:
#   oc-safe は「いま居るフォルダ」を作業対象にして統合ランチャー
#   （見守りモニター + 送信検査ゲートウェイ + 決定的 deny 床）へ橋渡しする入口。
#   OpenCode 本体を直接叩くとモニターが上がらないので、必ずここを通す。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
OC_SAFE="$HOME/.ai-safety/bin/oc-safe"
if [ ! -x "$OC_SAFE" ]; then
  echo "起動コマンドが見つかりません: $OC_SAFE"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
cd "$WORKSPACE" || exit 1
"$OC_SAFE"
ec=$?
if [ $ec -ne 0 ]; then read -r -p "問題が起きました。Enter キーで閉じます..." _; fi
