#!/usr/bin/env bash
# launch-deepseek-gateway.sh
# ds-gateway を起動し health 確認後に ANTHROPIC_BASE_URL をプロキシへ向け、
# ガード付き Claude Code を起動。終了時に gateway を確実停止（fail-closed）。
set -u

WORKSPACE="${1:-$HOME/Documents/my-ai-workspace}"
HOOKS_DIR="$WORKSPACE/.ai-safety/hooks"
GATEWAY_JS="$HOOKS_DIR/common/ds-gateway.js"
LAUNCH_CLAUDE="$HOOKS_DIR/macos/launch-claude-safe.sh"
PORT="${DS_GATEWAY_PORT:-8788}"

command -v node >/dev/null 2>&1 || { echo "【エラー】node が見つかりません。Claude Code には Node が必要です。"; exit 1; }
[ -f "$GATEWAY_JS" ] || { echo "【エラー】ds-gateway.js が見つかりません: $GATEWAY_JS"; exit 1; }
[ -f "$LAUNCH_CLAUDE" ] || { echo "【エラー】launch-claude-safe.sh が見つかりません: $LAUNCH_CLAUDE"; exit 1; }

stop_stale_gateway() {
  command -v lsof >/dev/null 2>&1 || return 0
  pids="$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
  [ -n "$pids" ] || return 0
  for pid in $pids; do
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$cmd" in
      *"$GATEWAY_JS"*)
        echo "古い DeepSeek Gateway を停止します（PID: $pid）。"
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 20); do
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then
          kill -9 "$pid" 2>/dev/null || true
        fi
        ;;
    esac
  done
}

stop_stale_gateway

DS_GATEWAY_PORT="$PORT" node "$GATEWAY_JS" &
GW_PID=$!
cleanup() { kill "$GW_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM

ok=0
for _ in $(seq 1 50); do
  if curl -s "http://127.0.0.1:$PORT/healthz" 2>/dev/null | grep -q '"status":"ok"'; then ok=1; break; fi
  sleep 0.1
done
if [ "$ok" -ne 1 ]; then
  echo "【エラー】Gateway の起動確認に失敗しました。送信検査なしでは起動しません（fail-closed）。"
  exit 1
fi

# health OK かつ「自身が spawn した node が生存」なら、そのポートは確実に自プロセスのもの。
# foreign process がポートを占有していれば自 node は bind 失敗で即終了している。
if ! kill -0 "$GW_PID" 2>/dev/null; then
  echo "【エラー】Gateway プロセスが生存していません（ポート占有の可能性）。送信検査なしでは起動しません（fail-closed）。"
  exit 1
fi

export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
echo "送信検査 Gateway 稼働中（127.0.0.1:${PORT}）。DeepSeek へは検査後に転送されます。"
bash "$LAUNCH_CLAUDE" "$WORKSPACE"
