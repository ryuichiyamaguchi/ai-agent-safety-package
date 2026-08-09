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
GATEWAY_TOKEN_JS="$HOOKS_DIR/common/gateway-token.js"
LAUNCH_CLAUDE="$HOOKS_DIR/macos/launch-claude-safe.sh"
PORT="${DS_GATEWAY_PORT:-8788}"
KEY_FILE="$HOME/.deepseek-claude/auth"
# AI コーチ(モニター)に「これは d-claude セッション」を伝える目印。モニターは別プロセスなので
# env では渡らない＝LOG_DIR にファイルを置く。モニターはこの目印があるとき Gemini へコマンド本文を
# 送らず分類結果だけ送る(redact)＋UI 明示。終了時に必ず消す(消し忘れ対策にモニター側も鮮度を見る)。
COACH_MARKER="${AI_SAFE_LOG_DIR:-$HOME/.ai-safety/logs}/coach-engine"

command -v node >/dev/null 2>&1 || { echo "【エラー】node が見つかりません。Claude Code には Node が必要です。"; exit 1; }
[ -f "$GATEWAY_JS" ] || { echo "【エラー】ds-gateway.js が見つかりません: $GATEWAY_JS"; exit 1; }
[ -f "$GATEWAY_TOKEN_JS" ] || { echo "【エラー】gateway-token.js が見つかりません: $GATEWAY_TOKEN_JS"; exit 1; }
[ -f "$LAUNCH_CLAUDE" ] || { echo "【エラー】launch-claude-safe.sh が見つかりません: $LAUNCH_CLAUDE"; exit 1; }
# 実キーは Gateway 子プロセスだけが読む（Claude Code 側には渡さない）ので、ここで存在を確かめる。
[ -s "$KEY_FILE" ] || {
  echo "【エラー】DeepSeek APIキーが未登録です。"
  echo "  先に「登録-初回だけ」を実行してから、もう一度起動してください。"
  exit 1
}

# 呼び出し元認証の合言葉は、この PC の共有ファイル（実キーと同じ置き場・同じ権限）から取る。
# 127.0.0.1 で待つだけでは同一 PC の任意プロセスや DNS リバインディングを踏んだブラウザから
# 叩けてしまうため、合言葉自体は必須のまま。以前は起動ごとに採番していたが、それだと
# OpenCode と d-claude を併用したときに後発が先発の gateway を殺し、先に開いていた窓が
# 古い合言葉のまま 401 になっていたので、PC 単位の共有に変えた。
# コマンドライン引数には載せない（ps に出るため）。標準出力で受け取る。
GATEWAY_TOKEN="$(node "$GATEWAY_TOKEN_JS" --ensure --gateway "$GATEWAY_JS" 2>/dev/null || true)"
[ -n "$GATEWAY_TOKEN" ] || { echo "【エラー】Gateway の合言葉を用意できませんでした（fail-closed）。"; exit 1; }

# gateway の出力はログへ。listen 行の pid 照合に使うほか、受講者の画面を汚さない。
GATEWAY_LOG="${AI_SAFE_LOG_DIR:-$HOME/.ai-safety/logs}/deepseek-gateway.log"
mkdir -p "$(dirname "$GATEWAY_LOG")" 2>/dev/null || true
: >> "$GATEWAY_LOG" 2>/dev/null || true

# そのポートを握っているのが「自分たちの ds-gateway.js」かを、実行中のコマンドラインで確かめる。
# lsof が無い環境では判定できない＝再利用しない（自分で立て直す）に倒す。
our_gateway_pid() {
  _p="$1"
  command -v lsof >/dev/null 2>&1 || return 1
  for pid in $(lsof -nP -tiTCP:"$_p" -sTCP:LISTEN 2>/dev/null || true); do
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$cmd" in
      *"$GATEWAY_JS"*) printf '%s' "$pid"; return 0 ;;
    esac
  done
  return 1
}

stop_stale_gateway() {
  _p="$1"
  command -v lsof >/dev/null 2>&1 || return 0
  pids="$(lsof -nP -tiTCP:"$_p" -sTCP:LISTEN 2>/dev/null || true)"
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

# 自分で spawn した gateway が「本当に動いているか」を見る。
# bash のバックグラウンドジョブは、即座に終了しても親が wait するまで zombie として
# プロセステーブルに残り、`kill -0` が成功してしまう。EADDRINUSE で落ちた gateway を
# 生きていると誤判定すると、同じポートで応答している「別の gateway」を自分のものだと
# 取り違えて相乗りしてしまう（別ワークスペースの検査設定で通信することになる）。
gateway_process_alive() {
  _pid="$1"
  [ -n "$_pid" ] || return 1
  _st="$(ps -p "$_pid" -o state= 2>/dev/null | tr -d ' ')"
  case "$_st" in
    ''|Z*) return 1 ;;
    *) return 0 ;;
  esac
}

# 自分で立てた gateway が、そのポートで listen できたことを確かめる。
#
# healthz の応答だけで判断してはいけない。ポートが他に取られていた場合、自分の gateway は
# bind に失敗して終了するが、その同じポートで「別の gateway」（例: 別ワークスペースから
# 起動されたもの）が動いていると healthz は正常に応答する。それを自分のものと取り違えると、
# 別の検査設定を通って通信することになる（実機で発生）。
#
# 確実なのは gateway 自身が listen 直後に出す 1 行の照合。
#   listening on 127.0.0.1:<port> pid=<pid> started=<時刻>
# ここの pid は自分が spawn した node のプロセス ID そのものなので、これが一致すれば
# 「そのポートで listen しているのは自分の gateway」だと確定できる。
# ログは追記式なので、今回の起動より前の行は見ない。
wait_for_own_gateway() {
  _p="$1"
  _from="$2"
  for _w in $(seq 1 50); do
    if [ -n "${GW_PID:-}" ]; then
      gateway_process_alive "$GW_PID" || return 1
    fi
    if tail -n "+$_from" "$GATEWAY_LOG" 2>/dev/null \
       | grep -q "listening on 127.0.0.1:$_p pid=$GW_PID"; then
      # 念のため応答も確かめる（listen 直後に落ちた場合を弾く）。
      curl -fsS --max-time 1 "http://127.0.0.1:$_p/healthz" 2>/dev/null | grep -q '"status":"ok"' && return 0
      return 1
    fi
    sleep 0.1
  done
  return 1
}

# 使うポートを決める。DS_GATEWAY_PORT で明示指定されたときはその 1 つだけを使い（利用者の
# 意図を尊重し、黙って別のポートへ逃げない）、未指定なら既定 8788 から順に空きを探す。
# 8788 が他のプログラム（別プロジェクトの常駐サービス等）に取られている PC があり、
# 決め打ちのままだと起動そのものができなくなるため。
if [ -n "${DS_GATEWAY_PORT:-}" ]; then
  PORT_CANDIDATES="$DS_GATEWAY_PORT"
else
  PORT_CANDIDATES="8788 8789 8790 8791 8792 8793 8794 8795 8796 8797"
fi

GW_PID=""
GATEWAY_REUSED=0
PORT=""

# 1) 既に動いている gateway があれば、そのまま使う（＝複数の窓を同時に開ける）。
#    どのポートで動いているかは gateway 自身が合言葉ファイルへ記録しているのでそれを見る。
RECORDED_PORT="$(node "$GATEWAY_TOKEN_JS" --recorded-port 2>/dev/null || true)"
if [ -n "$RECORDED_PORT" ] \
   && our_gateway_pid "$RECORDED_PORT" >/dev/null 2>&1 \
   && node "$GATEWAY_TOKEN_JS" --probe --gateway "$GATEWAY_JS" --port "$RECORDED_PORT" >/dev/null 2>&1; then
  PORT="$RECORDED_PORT"
  GATEWAY_REUSED=1
  echo "稼働中の送信検査 Gateway をそのまま使います（127.0.0.1:${PORT}）。"
fi

# 2) 再利用できないときは、候補ポートを順に試して自分で立てる。
if [ "$GATEWAY_REUSED" -ne 1 ]; then
  for candidate in $PORT_CANDIDATES; do
    # 自分たちの gateway が中身違い（更新後に古いものが居座っている）で居るなら止める。
    stop_stale_gateway "$candidate"
    # 今回の起動より前のログ行は見ない（追記式のため）。
    _log_from=$(( $(wc -l < "$GATEWAY_LOG" 2>/dev/null || echo 0) + 1 ))
    # 実キー(DS_GATEWAY_AUTH_FILE)と合言葉(DS_GATEWAY_TOKEN)は、この行だけの環境変数として
    # gateway 子プロセスに渡す（export しないので Claude Code 側の環境には残らない）。
    DS_GATEWAY_PORT="$candidate" \
    DS_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
    DS_GATEWAY_AUTH_FILE="$KEY_FILE" \
      node "$GATEWAY_JS" >>"$GATEWAY_LOG" 2>&1 &
    GW_PID=$!
    if wait_for_own_gateway "$candidate" "$_log_from"; then
      PORT="$candidate"
      [ "$PORT" = "8788" ] || echo "ポート 8788 は他のプログラムが使っていたため、送信検査 Gateway は 127.0.0.1:${PORT} で動かします。"
      break
    fi
    kill "$GW_PID" 2>/dev/null || true
    GW_PID=""
  done
fi
# coach マーカーは d-claude と OpenCode が同じパスを共有する。並行起動時に片方の終了で
# もう片方のバナーが消えないよう、「自分が書いた値のままのときだけ」消す。
remove_own_coach_marker() {
  [ "$(cat "$COACH_MARKER" 2>/dev/null || true)" = "d-claude" ] || return 0
  rm -f "$COACH_MARKER" 2>/dev/null || true
}
# 自分で立てた gateway だけを止める。共用中の gateway を止めると、同時に開いている
# 別の窓（OpenCode など）の通信をこちらの終了で巻き添えにしてしまう。
cleanup() { [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null; remove_own_coach_marker; }
trap cleanup EXIT INT TERM

# ポートを 1 つも確保できなかった＝どの候補も他のプログラムに使われている。
if [ -z "$PORT" ]; then
  echo "【エラー】送信検査 Gateway を起動できませんでした。送信検査なしでは起動しません（fail-closed）。"
  if [ -n "${DS_GATEWAY_PORT:-}" ]; then
    echo "  指定されたポート $DS_GATEWAY_PORT を他のプログラムが使っている可能性があります。"
  else
    echo "  ポート 8788〜8797 をすべて他のプログラムが使っている可能性があります。"
  fi
  exit 1
fi

# ここへ来た時点で /healthz は確認済み（ポート選択の中で待っている）。最後にもう一度
# 「そのポートを握っているのが自分たちの ds-gateway.js か」を確かめる。
#   - 自分で立てた場合: その子プロセスが生きていれば、そのポートは確実に自分のもの
#     （他プロセスが占有していれば bind 失敗で即終了しているため）
#   - 共用の場合: コマンドライン照合で自分たちの gateway だと確かめる
gateway_alive=0
if [ -n "$GW_PID" ] && gateway_process_alive "$GW_PID"; then
  gateway_alive=1
elif [ "$GATEWAY_REUSED" = "1" ] && our_gateway_pid "$PORT" >/dev/null 2>&1; then
  gateway_alive=1
fi
if [ "$gateway_alive" -ne 1 ]; then
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
