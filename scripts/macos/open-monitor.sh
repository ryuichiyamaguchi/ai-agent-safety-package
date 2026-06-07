#!/usr/bin/env bash
# open-monitor.sh — HTML 見守りモニター(now.html)を既定ブラウザで開く。
#
# 「見守りモニターを起動」ボタンの実体。
#   1. ログディレクトリを解決（guards / monitor.sh と同一ロジック）
#   2. now.html がまだ無ければ待機カードの placeholder を生成
#   3. open で既定ブラウザに表示（meta refresh + JS reload で自動更新）
#
# ガード発火後は guard 側 (explainer.sh write_now_html) が同じ now.html を
# 上書きするので、本物の承認カードに自動で切り替わる。
#
# 環境変数:
#   AI_SAFE_LOG_DIR          ログディレクトリ（既定: $HOME/.ai-safety/logs）
#   AI_SAFE_MONITOR_INTERVAL 自動更新間隔秒（既定: 1）

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# ログディレクトリ解決: monitor.sh / safety_policy.sh の log_dir と完全に揃える。
log_dir() {
  if [ -n "${AI_SAFE_LOG_DIR:-}" ]; then
    printf '%s\n' "$AI_SAFE_LOG_DIR"
  else
    printf '%s\n' "$HOME/.ai-safety/logs"
  fi
}

DIR="$(log_dir)"
NOW_HTML="$DIR/now.html"

# --- AI コーチ・モニター（Node サーバ）を優先起動。Node 不在 / 失敗時は file:// にフォールバック ---
# サーバはこのウィンドウが開いている間だけ動く（閉じる/ Ctrl+C で停止）。常駐デーモンにはしない。
SERVER_JS="$HERE/../common/monitor-server.js"
if command -v node >/dev/null 2>&1 && [ -r "$SERVER_JS" ] && [ "${AI_SAFE_MONITOR_NO_SERVER:-0}" != "1" ]; then
  URL_FILE="$DIR/monitor-url.txt"
  mkdir -p "$DIR" 2>/dev/null || true
  rm -f "$URL_FILE" 2>/dev/null || true
  # node の出力（URL+トークン）はターミナルに出さずログへ。
  AI_SAFE_LOG_DIR="$DIR" node "$SERVER_JS" >"$DIR/monitor-server.log" 2>&1 &
  SRV_PID=$!
  # URL ファイル（サーバが listen 後に書く）を最大 5 秒待つ
  for _i in $(seq 1 25); do [ -f "$URL_FILE" ] && break; sleep 0.2; done
  if [ -f "$URL_FILE" ]; then
    open "$(cat "$URL_FILE")" 2>/dev/null || true
    echo "AI コーチ・モニターを起動しました。"
    echo "（このウィンドウを閉じる、または Ctrl+C で停止します）"
    trap 'kill "$SRV_PID" 2>/dev/null' INT TERM
    wait "$SRV_PID"
    exit 0
  fi
  echo "サーバ起動を確認できませんでした。従来の file:// モニターに切り替えます。"
  kill "$SRV_PID" 2>/dev/null || true
fi

# placeholder 生成は explainer.sh の write_now_html_placeholder を再利用する
# （重複ロジックを増やさない）。source できない / 失敗しても open は試みる。
if [ ! -f "$NOW_HTML" ]; then
  explainer="$HERE/lib/explainer.sh"
  if [ -r "$explainer" ]; then
    # shellcheck source=lib/explainer.sh
    . "$explainer" 2>/dev/null || true
    if command -v write_now_html_placeholder >/dev/null 2>&1; then
      write_now_html_placeholder "$DIR" 2>/dev/null || true
    fi
  fi
fi

if [ -f "$NOW_HTML" ]; then
  open "$NOW_HTML" 2>/dev/null && exit 0
  # F-G: ブラウザ起動失敗時はコンソール版へ自動フォールバック（非エンジニア配慮）。
  echo "ブラウザを開けませんでした。コンソール版モニターを表示します。"
  echo
fi

# placeholder 生成失敗 or ブラウザ起動失敗時のフォールバック（コンソール版）。
exec bash "$HERE/monitor.sh"
