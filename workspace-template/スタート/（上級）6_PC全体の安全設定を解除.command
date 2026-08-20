#!/bin/bash
# 「（上級）5_このPC全体に最低限の安全設定を入れる」で入れた全体設定の変更を取り消し、
# 元の状態へ戻す（ワンクリック）。
# 適用前のバックアップから ~/.claude/settings.json・~/.codex/config.toml と hooks.json・
# ~/.gemini/settings.json・~/.config/opencode/opencode.json を復元する。
# 入れた分だけを正確に戻すので、入れていないエンジンには触らない。
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
echo "「（上級）5」で入れた PC 全体の安全設定を取り消し、元の設定に戻します。"
echo "（Claude Code / Codex / agy(Gemini) / OpenCode の 4 つが対象です。）"
echo ""
bash "$TARGET"
ec=$?
echo ""
if [ $ec -eq 0 ]; then
  echo "元に戻しました。次に起動する AI から反映されます。"
else
  echo "問題が起きました（上のメッセージを確認してください）。"
fi
read -r -p "Enter キーで閉じます..." _
