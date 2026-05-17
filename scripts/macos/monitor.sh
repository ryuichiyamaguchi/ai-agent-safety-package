#!/usr/bin/env bash
# agent-monitor: 別ターミナルで起動する簡易ビューア
#
# 左上に「いま AI がやろうとしていること」（now.md）
# 下に「直近の出来事」（events-YYYY-MM-DD.jsonl の整形）
# Ctrl+C で終了。
#
# 環境変数:
#   AI_SAFE_LOG_DIR        ログディレクトリ（既定: $HOME/.ai-safety/logs）
#   AI_SAFE_MONITOR_TAIL   表示するイベント件数（既定: 12）
#   AI_SAFE_MONITOR_INTERVAL  再描画間隔秒（既定: 1）

set -u

log_dir() {
  if [ -n "${AI_SAFE_LOG_DIR:-}" ]; then
    printf '%s\n' "$AI_SAFE_LOG_DIR"
  else
    printf '%s\n' "$HOME/.ai-safety/logs"
  fi
}

DIR="$(log_dir)"
NOW="$DIR/now.md"
TAIL_N="${AI_SAFE_MONITOR_TAIL:-12}"
INTERVAL="${AI_SAFE_MONITOR_INTERVAL:-1}"

cleanup() {
  tput cnorm 2>/dev/null || true
  printf '\n'
  exit 0
}
trap cleanup INT TERM

tput civis 2>/dev/null || true

format_event() {
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ts="$(printf '%s' "$line" | sed -nE 's/.*"ts"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
    decision="$(printf '%s' "$line" | sed -nE 's/.*"decision"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
    mode="$(printf '%s' "$line" | sed -nE 's/.*"mode"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
    reason="$(printf '%s' "$line" | sed -nE 's/.*"reason"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
    short_ts="${ts##*T}"
    short_ts="${short_ts%Z}"
    short_ts="${short_ts%.*}"
    case "$decision" in
      block) icon="⛔" ;;
      allow) icon="✅" ;;
      explain) icon="💬" ;;
      *) icon="• " ;;
    esac
    printf '  %s  %s %-7s  %-12s  %s\n' "$short_ts" "$icon" "$decision" "$mode" "$reason"
  done
}

while :; do
  TODAY="$(date +%F)"
  EVENTS="$DIR/events-$TODAY.jsonl"
  clear 2>/dev/null || printf '\033[2J\033[H'
  printf '╔════════════════════════════════════════════════════════════════╗\n'
  printf '║  agent-monitor — AI の動きを横で見る  (Ctrl+C で終了)          ║\n'
  printf '╚════════════════════════════════════════════════════════════════╝\n'
  if [ -r "$NOW" ]; then
    cat "$NOW"
  else
    printf '\n  (まだ承認待ちのアクションはありません。AI が tool を呼ぶとここに出ます)\n'
  fi
  printf '\n──────────────  直近の出来事 (events-%s.jsonl)  ──────────────\n' "$TODAY"
  if [ -r "$EVENTS" ]; then
    tail -n "$TAIL_N" "$EVENTS" | format_event
  else
    printf '  (本日の監査ログはまだ作成されていません)\n'
  fi
  sleep "$INTERVAL"
done
