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

echo
echo "AIをまとめて起動（安全装置つき）"
echo "────────────────────────────────"
echo "1) Codex   標準モード（ChatGPT 課金の人・推奨）"
echo "2) Claude  標準モード（Claude 課金の人・推奨）"
echo "3) Claude  AI補助モード（Claude 課金の人）"
echo "4) OpenCode + DeepSeek V4 Flash（無課金の人・少額チャージ／送信検査・Web検索OFF）"
echo "5) OpenCode + DeepSeek V4 Flash（無課金の人・少額チャージ／Web検索を確認制でON）"
echo "6) d-claude + DeepSeek V4 Flash（Claudeの操作感・送信検査・監視ON）"
echo "   ※6 は在校中のみ。卒業後は使えなくなります（OpenCode へ移行 → 説明書 docs/20_卒業後ガイド）"
echo "7) OpenCode + DeepSeek V4 Flash（前回の続きから開く）"
echo
read -r -p "番号を入力してください [1]: " choice
choice="${choice:-1}"

# OpenCode は「起動したフォルダ」が作業対象になり、動き出したあとで cd しても移らない
# （OpenCode 本体の仕様）。案件ごとにフォルダを分けて作業できるよう、起動前にどこで
# 始めるかを選んでもらう。パスを打たせず、作業フォルダ直下の一覧から番号で選ぶ。
# 何も入れずに Enter なら従来どおり作業フォルダ直下で起動する。
PROJECT_FLAG=""
choose_project() {
  # 直下のフォルダだけを候補にする（隠しフォルダと、パッケージが使う場所は除く）。
  _dirs=""
  _n=0
  for _d in "$WORKSPACE"/*/; do
    [ -d "$_d" ] || continue
    _name="$(basename "$_d")"
    case "$_name" in
      .*|スタート|safe-workspace) continue ;;
    esac
    _n=$((_n + 1))
    _dirs="$_dirs$_name"$'\n'
  done

  if [ "$_n" -eq 0 ]; then
    return 0
  fi

  echo
  echo "どのフォルダで作業しますか？"
  echo "────────────────────────────────"
  echo "0) $(basename "$WORKSPACE")（そのまま）"
  _i=0
  printf '%s' "$_dirs" | while IFS= read -r _name; do
    [ -n "$_name" ] || continue
    _i=$((_i + 1))
    echo "$_i) $_name"
  done
  echo
  read -r -p "番号を入力してください [0]: " _pick
  _pick="${_pick:-0}"

  case "$_pick" in
    0) return 0 ;;
    ''|*[!0-9]*)
      echo "番号で選んでください。作業フォルダ直下で起動します。"
      return 0
      ;;
  esac
  if [ "$_pick" -gt "$_n" ]; then
    echo "その番号はありません。作業フォルダ直下で起動します。"
    return 0
  fi

  _sel="$(printf '%s' "$_dirs" | sed -n "${_pick}p")"
  [ -n "$_sel" ] || return 0
  PROJECT_FLAG="--project=$WORKSPACE/$_sel"
  # 変数の直後に日本語が続くと、bash 3.2 は変数名の切れ目を取り違える。必ず ${} で囲む。
  echo "「${_sel}」で起動します。"
}

case "$choice" in
  1) exec bash "$LAUNCHER" "$WORKSPACE" codex standard ;;
  2) exec bash "$LAUNCHER" "$WORKSPACE" claude standard ;;
  3) exec bash "$LAUNCHER" "$WORKSPACE" claude assisted ;;
  4) choose_project; exec bash "$LAUNCHER" "$WORKSPACE" opencode standard "$PROJECT_FLAG" ;;
  5) choose_project; exec bash "$LAUNCHER" "$WORKSPACE" opencode standard --websearch "$PROJECT_FLAG" ;;
  6) exec bash "$LAUNCHER" "$WORKSPACE" d-claude standard ;;
  7) choose_project; exec bash "$LAUNCHER" "$WORKSPACE" opencode standard --resume "$PROJECT_FLAG" ;;
  *)
    echo "1〜7の番号を選んでください。"
    read -r -p "Enterで閉じます: " _
    exit 2
    ;;
esac
