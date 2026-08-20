#!/bin/bash
# 長時間おまかせモード（目を離して AI に長く作業させる）で起動する。
# Claude / Codex / OpenCode / AntiGravity から選べる。
# 壁（OS のサンドボックス）がある環境では従来どおり、壁が無い環境では
# 「壁がありません」と一度だけ確認してから進む。deny 床と記録はどの環境でも外していない。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/launch-longrun.sh"
if [ ! -f "$TARGET" ]; then
  echo "スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
bash "$TARGET" "$WORKSPACE"
ec=$?
echo ""
if [ $ec -ne 0 ]; then
  echo "起動しませんでした（上のメッセージを確認してください）。"
fi
read -r -p "Enter キーで閉じます..." _
