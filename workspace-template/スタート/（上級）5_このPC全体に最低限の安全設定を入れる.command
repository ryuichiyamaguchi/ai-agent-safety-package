#!/bin/bash
# この Mac の「全体設定」に、4 エンジン（Claude Code / Codex / agy(Gemini) / OpenCode）分の
# 最低限の安全設定を入れる（ワンクリック）。
# どのフォルダから起動しても、rm -r / cat .env / curl|sh などの危険操作が止まるようになる。
# Codex はデスクトップアプリも同じ設定ファイルを読むので、アプリ側にも同時に効く。
# 既存の設定は壊さず、反映前に自動でバックアップを取る。
# 元に戻すときは「（上級）6_PC全体の安全設定を解除」。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
TARGET="$WORKSPACE/.ai-safety/hooks/macos/apply-global-guard.sh"
if [ ! -f "$TARGET" ]; then
  echo "スクリプトが見つかりません: $TARGET"
  echo "先に「1_安全パッケージを準備」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
echo "この Mac で AI（Claude Code / Codex / agy / OpenCode）をどのフォルダから起動しても、"
echo "危険コマンド（rm -r / cat .env / curl|sh / 外部送信など）を止めるようにします。"
echo ""
bash "$TARGET"
ec=$?
echo ""
if [ $ec -eq 0 ]; then
  echo "終了しました。次に起動する AI から反映されます。"
  echo "（元に戻したいときは「（上級）6_PC全体の安全設定を解除」を実行してください。）"
else
  echo "問題が起きました（上のメッセージを確認してください）。"
fi
read -r -p "Enter キーで閉じます..." _
