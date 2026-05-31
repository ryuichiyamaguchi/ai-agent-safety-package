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

# 自プロセス識別用の nonce。foreign process がポートを占有していても healthz で見分ける（fail-closed）。
TOKEN="$(head -c 16 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null | tr -d '\n')"
[ -n "$TOKEN" ] || TOKEN="$RANDOM$RANDOM$RANDOM"
export DS_GATEWAY_HEALTH_TOKEN="$TOKEN"

command -v node >/dev/null 2>&1 || { echo "【エラー】node が見つかりません。Claude Code には Node が必要です。"; exit 1; }
[ -f "$GATEWAY_JS" ] || { echo "【エラー】ds-gateway.js が見つかりません: $GATEWAY_JS"; exit 1; }
[ -f "$LAUNCH_CLAUDE" ] || { echo "【エラー】launch-claude-safe.sh が見つかりません: $LAUNCH_CLAUDE"; exit 1; }

DS_GATEWAY_PORT="$PORT" node "$GATEWAY_JS" &
GW_PID=$!
cleanup() { kill "$GW_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM

ok=0
for _ in $(seq 1 50); do
  resp="$(curl -s "http://127.0.0.1:$PORT/healthz" 2>/dev/null)"
  if printf '%s' "$resp" | grep -q '"status":"ok"' && printf '%s' "$resp" | grep -q "$TOKEN"; then ok=1; break; fi
  sleep 0.1
done
if [ "$ok" -ne 1 ]; then
  echo "【エラー】Gateway の起動確認に失敗しました。送信検査なしでは起動しません（fail-closed）。"
  exit 1
fi

export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
echo "送信検査 Gateway 稼働中（127.0.0.1:$PORT）。DeepSeek へは検査後に転送されます。"
bash "$LAUNCH_CLAUDE" "$WORKSPACE"
