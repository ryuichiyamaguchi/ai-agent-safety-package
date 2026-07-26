#!/usr/bin/env bash
# OpenCode + DeepSeek V4 Pro/Flash を送信検査 Gateway 経由で起動する。
set -euo pipefail

WORKSPACE="${1:-$HOME/Documents/my-ai-workspace}"
WEBSEARCH="${2:-}"
HOOKS_DIR="$WORKSPACE/.ai-safety/hooks"
GATEWAY_JS="$HOOKS_DIR/common/ds-gateway.js"
CONFIG_JS="$HOOKS_DIR/common/opencode-config.js"
MONITOR_PLUGIN="$HOOKS_DIR/common/opencode-bouncer-monitor.mjs"
PORT="${DS_GATEWAY_PORT:-8788}"
KEY_DIR="$HOME/.deepseek-claude"
KEY_FILE="$KEY_DIR/auth"
LOG_DIR="${AI_SAFE_LOG_DIR:-$HOME/.ai-safety/logs}"
COACH_MARKER="$LOG_DIR/coach-engine"

case "$WEBSEARCH" in
  ""|--websearch) ;;
  *) echo "使い方: $0 [workspace] [--websearch]" >&2; exit 2 ;;
esac

[ -d "$WORKSPACE" ] || { echo "作業フォルダが見つかりません: $WORKSPACE" >&2; exit 2; }
[ -f "$GATEWAY_JS" ] || { echo "送信検査 Gateway が見つかりません: $GATEWAY_JS" >&2; exit 2; }
[ -f "$CONFIG_JS" ] || { echo "OpenCode 安全設定が見つかりません: $CONFIG_JS" >&2; exit 2; }
[ -f "$MONITOR_PLUGIN" ] || { echo "OpenCode承認モニターが見つかりません: $MONITOR_PLUGIN" >&2; exit 2; }

if [ "${AI_SAFE_DRY_RUN:-0}" = "1" ]; then
  echo "OpenCode + DeepSeek dry-run"
  echo "  workspace: $WORKSPACE"
  echo "  gateway:   http://127.0.0.1:$PORT/v1 (mandatory)"
  echo "  config:    OPENCODE_CONFIG_CONTENT"
  echo "  model:     DeepSeek V4 Pro / small: V4 Flash"
  if [ "$WEBSEARCH" = "--websearch" ]; then
    echo "  websearch: opt-in (approval required)"
  else
    echo "  websearch: off"
  fi
  exit 0
fi

command -v node >/dev/null 2>&1 || { echo "Node.js が見つかりません。" >&2; exit 1; }
OPENCODE_BIN="${OPENCODE_BIN:-$(command -v opencode 2>/dev/null || true)}"
[ -n "$OPENCODE_BIN" ] || { echo "OpenCode が見つかりません。先に OpenCode をインストールしてください。" >&2; exit 1; }
[ -s "$KEY_FILE" ] || { echo "DeepSeek APIキーが未登録です。先に「DeepSeekキーを登録」を実行してください。" >&2; exit 1; }

VERSION="$("$OPENCODE_BIN" --version 2>/dev/null | head -n1 | tr -d '\r')"
if ! node -e 'const m=require(process.argv[1]);process.exit(m.isSupportedVersion(process.argv[2])?0:1)' "$CONFIG_JS" "$VERSION"; then
  echo "OpenCode 1.14.24 以上が必要です（検出: ${VERSION:-不明}）。" >&2
  exit 1
fi

stop_stale_gateway() {
  command -v lsof >/dev/null 2>&1 || return 0
  for pid in $(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true); do
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$cmd" in
      *"$GATEWAY_JS"*) kill "$pid" 2>/dev/null || true ;;
    esac
  done
}

mkdir -p "$LOG_DIR"
stop_stale_gateway
DS_GATEWAY_PORT="$PORT" \
DS_GATEWAY_UPSTREAM="https://api.deepseek.com" \
DS_GATEWAY_AUTH_FILE="$KEY_FILE" \
  node "$GATEWAY_JS" >"$LOG_DIR/opencode-deepseek-gateway.log" 2>&1 &
GW_PID=$!

cleanup() {
  kill "$GW_PID" 2>/dev/null || true
  rm -f "$COACH_MARKER" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

ready=0
for _i in $(seq 1 50); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/healthz" 2>/dev/null | grep -q '"status":"ok"'; then
    ready=1
    break
  fi
  kill -0 "$GW_PID" 2>/dev/null || break
  sleep 0.1
done
if [ "$ready" -ne 1 ] || ! kill -0 "$GW_PID" 2>/dev/null; then
  echo "送信検査 Gateway を確認できないため、OpenCode は起動しません（fail-closed）。" >&2
  echo "確認先: $LOG_DIR/opencode-deepseek-gateway.log" >&2
  exit 1
fi

# プロジェクト固有の設定は無効化し、隔離した設定ディレクトリからBouncerプラグインだけを読む。
export OPENCODE_DISABLE_PROJECT_CONFIG=1
unset OPENCODE_PURE 2>/dev/null || true
export XDG_CONFIG_HOME="$WORKSPACE/.ai-safety/opencode-runtime/xdg-config"
export AI_SAFE_LOG_DIR="$LOG_DIR"
mkdir -p "$XDG_CONFIG_HOME"
if [ "$WEBSEARCH" = "--websearch" ]; then
  export OPENCODE_ENABLE_EXA=1
  export OPENCODE_CONFIG_CONTENT
  OPENCODE_CONFIG_CONTENT="$(node "$CONFIG_JS" --port "$PORT" --monitor-plugin "$MONITOR_PLUGIN" --websearch)"
  echo "Web検索を有効にしました。検索語は外部サービスへ送信され、実行前に確認が出ます。"
else
  unset OPENCODE_ENABLE_EXA 2>/dev/null || true
  export OPENCODE_CONFIG_CONTENT
  OPENCODE_CONFIG_CONTENT="$(node "$CONFIG_JS" --port "$PORT" --monitor-plugin "$MONITOR_PLUGIN")"
fi

# 実キーは Gateway 子プロセスだけが読み、OpenCode の環境には渡さない。
unset DEEPSEEK_API_KEY DEEPSEEK_API_TOKEN ANTHROPIC_AUTH_TOKEN DS_GATEWAY_AUTH_FILE 2>/dev/null || true
printf 'opencode-deepseek' > "$COACH_MARKER" 2>/dev/null || true
echo "Bouncer送信検査: 有効 / モデル: DeepSeek V4 Pro / 補助: V4 Flash"
echo "変更操作は確認、外部フォルダは禁止、Web検索は${WEBSEARCH:+許可時のみ}$( [ -n "$WEBSEARCH" ] || printf '無効' )です。"

cd "$WORKSPACE"
"$OPENCODE_BIN"
