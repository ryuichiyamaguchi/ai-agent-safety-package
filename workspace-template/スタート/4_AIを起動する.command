#!/bin/bash
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
LAUNCHER="$WORKSPACE/.ai-safety/hooks/macos/launch-integrated.sh"

if [ ! -x "$LAUNCHER" ]; then
  echo "安全装置（Bouncer）がまだ準備されていません。"
  echo "先にインストーラーを実行してください。"
  read -r -p "Enterで閉じます: " _
  exit 2
fi

# メニューの正本はランチャー本体（launch-integrated.sh の menu モード）に 1 か所だけ置く。
# 以前はこのボタンに選択肢の写しを持っていたが、ランチャー側の変更に追従できず
# 古いメニュー（AntiGravity 無し等）が残ったため、委譲だけにした。
# 並びは課金プラン順。作業フォルダの選択（OpenCode 用）もランチャー側で聞かれる。
exec bash "$LAUNCHER" "$WORKSPACE" menu standard
