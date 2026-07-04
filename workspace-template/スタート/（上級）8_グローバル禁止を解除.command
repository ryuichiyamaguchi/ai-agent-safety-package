#!/bin/bash
# 「（上級）7_危険コマンドをClaude全体で禁止」で入れた全体設定の変更を取り消し、元の状態へ戻す（ワンクリック）。
# 適用前のバックアップから ~/.claude/settings.json と ~/.codex/config.toml / hooks.json を復元する。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/uninstall-global-guard.sh"
if [ ! -f "$TARGET" ]; then
  echo "スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
echo "「（上級）7」で入れた Claude／Codex 全体のガードを取り消し、元の設定に戻します。"
echo ""
bash "$TARGET"
ec=$?
echo ""
if [ $ec -eq 0 ]; then
  echo "元に戻しました。次に起動する Claude／Codex から反映されます。"
else
  echo "問題が起きました（上のメッセージを確認してください）。"
fi
read -r -p "Enter キーで閉じます..." _
