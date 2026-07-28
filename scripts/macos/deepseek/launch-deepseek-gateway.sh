#!/usr/bin/env bash
# launch-deepseek-gateway.sh
# ds-gateway を起動し health 確認後に ANTHROPIC_BASE_URL をプロキシへ向け、
# ガード付き Claude Code を起動。終了時に gateway を確実停止（fail-closed）。
set -u

# 受講者のシェルに残っていた AI_SAFE_POLICY / AI_SAFE_ROOT で deny 床ごと差し替えられる
# のを防ぐため、起動時に必ず捨てる（このあと同梱ポリシーを自分で設定する）。
# 万一これが漏れても、ガード側(lib/safety_policy.sh / lib/SafetyPolicy.ps1)が同梱パス以外を
# 拒否するので床は残る。ここは二重の保険。
unset AI_SAFE_POLICY AI_SAFE_ROOT

WORKSPACE="${1:-$HOME/Documents/my-ai-workspace}"
HOOKS_DIR="$WORKSPACE/.ai-safety/hooks"
GATEWAY_JS="$HOOKS_DIR/common/ds-gateway.js"
LAUNCH_CLAUDE="$HOOKS_DIR/macos/launch-claude-safe.sh"
PORT="${DS_GATEWAY_PORT:-8788}"
KEY_FILE="$HOME/.deepseek-claude/auth"
# AI コーチ(モニター)に「これは d-claude セッション」を伝える目印。モニターは別プロセスなので
# env では渡らない＝LOG_DIR にファイルを置く。モニターはこの目印があるとき Gemini へコマンド本文を
# 送らず分類結果だけ送る(redact)＋UI 明示。終了時に必ず消す(消し忘れ対策にモニター側も鮮度を見る)。
COACH_MARKER="${AI_SAFE_LOG_DIR:-$HOME/.ai-safety/logs}/coach-engine"

command -v node >/dev/null 2>&1 || { echo "【エラー】node が見つかりません。Claude Code には Node が必要です。"; exit 1; }
[ -f "$GATEWAY_JS" ] || { echo "【エラー】ds-gateway.js が見つかりません: $GATEWAY_JS"; exit 1; }
[ -f "$LAUNCH_CLAUDE" ] || { echo "【エラー】launch-claude-safe.sh が見つかりません: $LAUNCH_CLAUDE"; exit 1; }
# 実キーは Gateway 子プロセスだけが読む（Claude Code 側には渡さない）ので、ここで存在を確かめる。
[ -s "$KEY_FILE" ] || {
  echo "【エラー】DeepSeek APIキーが未登録です。"
  echo "  先に「登録-初回だけ」を実行してから、もう一度起動してください。"
  exit 1
}

# 呼び出し元認証トークンを起動ごとに採番する。127.0.0.1 で待つだけでは同一 PC の
# 任意プロセスや DNS リバインディングを踏んだブラウザから叩けてしまうため、
# 「この起動で立てた Claude Code だけが通れる」合言葉を毎回作り直す。
# コマンドライン引数には載せない（ps に出るため）。環境変数と gateway 内メモリだけで扱う。
if command -v openssl >/dev/null 2>&1; then
  GATEWAY_TOKEN="$(openssl rand -hex 32)"
else
  GATEWAY_TOKEN="$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')"
fi
[ -n "$GATEWAY_TOKEN" ] || { echo "【エラー】Gateway の合言葉を生成できませんでした（fail-closed）。"; exit 1; }

stop_stale_gateway() {
  command -v lsof >/dev/null 2>&1 || return 0
  pids="$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
  [ -n "$pids" ] || return 0
  for pid in $pids; do
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$cmd" in
      *"$GATEWAY_JS"*)
        echo "古い DeepSeek Gateway を停止します（PID: ${pid}）。"
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

# 実キー(DS_GATEWAY_AUTH_FILE)と合言葉(DS_GATEWAY_TOKEN)は、この行だけの環境変数として
# gateway 子プロセスに渡す（export しないので Claude Code 側の環境には残らない）。
DS_GATEWAY_PORT="$PORT" \
DS_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
DS_GATEWAY_AUTH_FILE="$KEY_FILE" \
  node "$GATEWAY_JS" &
GW_PID=$!
# coach マーカーは d-claude と OpenCode が同じパスを共有する。並行起動時に片方の終了で
# もう片方のバナーが消えないよう、「自分が書いた値のままのときだけ」消す。
remove_own_coach_marker() {
  [ "$(cat "$COACH_MARKER" 2>/dev/null || true)" = "d-claude" ] || return 0
  rm -f "$COACH_MARKER" 2>/dev/null || true
}
cleanup() { kill "$GW_PID" 2>/dev/null; remove_own_coach_marker; }
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
# Claude Code が gateway へ送る鍵を「実キー」から「この起動限りの合言葉」に差し替える。
# 呼び出し元 (.command / launch-integrated.sh) が実キーを ANTHROPIC_AUTH_TOKEN に入れて
# 渡してくるが、ここで上書きするので実キーは Claude Code のプロセスには残らない
# （実キーを読むのは gateway 子プロセスだけ = OpenCode 経路と同じ扱い）。
export ANTHROPIC_AUTH_TOKEN="$GATEWAY_TOKEN"
# d-claude 経路の目印。launch-claude-safe.sh はこのフラグがあるとき
# DeepSeek ルーティング env (AUTH_TOKEN/BASE_URL/MODEL) の unset をスキップする
# （消すと DeepSeek に繋がらず claude が "not logged in" になるため）。
export DS_CLAUDE_MODE=1
# d-claude ではグレーコマンドの危険判定を独立した Gemini(2鍵)に任せて自律的に回す。
# 判定役は DeepSeek でなく Gemini なので「自分のコマンドを自分で審査」にならない。両鍵が
# approve のときだけ自動許可、少しでも怪しければ人間に確認(fail-closed)。決定的 deny の底は不変。
# judge は無条件で ON。以前の ${VAR:-1} は残存 "0"（旧 export/setx）を上書きできず judge が黙って
# OFF になり得たため撤廃（Windows の .ps1 と対称）。無効化は残存値では起きない別 env を明示指定したときだけ。
if [ "${AI_SAFE_ASSISTED_APPROVAL_OPTOUT:-0}" = "1" ]; then
  export AI_SAFE_ASSISTED_APPROVAL="0"
else
  export AI_SAFE_ASSISTED_APPROVAL="1"
fi
# モニターへ d-claude 目印を置く（AI コーチが Gemini へコマンド本文を送らないように）。
mkdir -p "$(dirname "$COACH_MARKER")" 2>/dev/null && printf 'd-claude' > "$COACH_MARKER" 2>/dev/null || true
echo "送信検査 Gateway 稼働中（127.0.0.1:${PORT}）。DeepSeek へは検査後に転送されます。"
bash "$LAUNCH_CLAUDE" "$WORKSPACE"
