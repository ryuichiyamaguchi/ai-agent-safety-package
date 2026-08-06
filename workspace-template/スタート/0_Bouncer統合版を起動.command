#!/bin/bash
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$HERE/.." && pwd)"
LAUNCHER="$WORKSPACE/.ai-safety/hooks/macos/launch-integrated.sh"

if [ ! -x "$LAUNCHER" ]; then
  echo "Bouncer統合版がまだ準備されていません。"
  echo "先にインストーラーを実行してください。"
  read -r -p "Enterで閉じます: " _
  exit 2
fi

echo
echo "Bouncer 統合版"
echo "────────────────────────────────"
echo "1) Codex   標準モード（推奨・軽快）"
echo "2) Claude  標準モード（推奨・軽快）"
echo "3) Claude  AI補助モード"
echo "4) Claude  最大保護モード（ローカルGemmaが必要）"
echo "5) OpenCode + DeepSeek V4 Pro（送信検査・Web検索OFF）"
echo "6) OpenCode + DeepSeek V4 Pro（Web検索を確認制でON）"
echo "7) d-claude + DeepSeek V4 Pro（Claudeの操作感・送信検査・監視ON）"
echo "8) OpenCode + DeepSeek V4 Pro（前回の続きから開く）"
echo
read -r -p "番号を入力してください [1]: " choice
choice="${choice:-1}"

case "$choice" in
  1) exec bash "$LAUNCHER" "$WORKSPACE" codex standard ;;
  2) exec bash "$LAUNCHER" "$WORKSPACE" claude standard ;;
  3) exec bash "$LAUNCHER" "$WORKSPACE" claude assisted ;;
  4) exec bash "$LAUNCHER" "$WORKSPACE" claude maximum ;;
  5) exec bash "$LAUNCHER" "$WORKSPACE" opencode standard ;;
  6) exec bash "$LAUNCHER" "$WORKSPACE" opencode standard --websearch ;;
  7) exec bash "$LAUNCHER" "$WORKSPACE" d-claude standard ;;
  8) exec bash "$LAUNCHER" "$WORKSPACE" opencode standard --resume ;;
  *)
    echo "1〜8の番号を選んでください。"
    read -r -p "Enterで閉じます: " _
    exit 2
    ;;
esac
