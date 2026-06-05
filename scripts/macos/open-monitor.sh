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
  echo "ブラウザを開けませんでした。次のファイルを手動で開いてください:"
  echo "  $NOW_HTML"
  echo
  echo "（ブラウザが使えない場合は、コンソール版モニターも使えます: $HERE/monitor.sh）"
  exit 1
fi

# placeholder すら生成できなかった場合のフォールバック（コンソール版）。
echo "HTML モニターを準備できませんでした。"
echo "ログ保存先: $DIR"
echo "代わりにコンソール版モニターを開きます…"
echo
exec bash "$HERE/monitor.sh"
