#!/usr/bin/env bash
# OpenCode + DeepSeek V4 Pro/Flash を送信検査 Gateway 経由で起動する。
set -euo pipefail

WORKSPACE="${1:-$HOME/Documents/my-ai-workspace}"
HOOKS_DIR="$WORKSPACE/.ai-safety/hooks"
GATEWAY_JS="$HOOKS_DIR/common/ds-gateway.js"
GATEWAY_TOKEN_JS="$HOOKS_DIR/common/gateway-token.js"
CONFIG_JS="$HOOKS_DIR/common/opencode-config.js"
MONITOR_PLUGIN="$HOOKS_DIR/common/opencode-bouncer-monitor.mjs"
PORT="${DS_GATEWAY_PORT:-8788}"
KEY_DIR="$HOME/.deepseek-claude"
KEY_FILE="$KEY_DIR/auth"
LOG_DIR="${AI_SAFE_LOG_DIR:-$HOME/.ai-safety/logs}"
# 秘密の解決（順序は全箇所共通: 環境変数 → OS の金庫 → 旧平文）。
# 金庫は Mac のキーチェーン。値は "v1:" + base64 の封筒に包んで入れてある。
read_secret() { # $1=金庫の service 名, $2=環境変数名(省略可), $3=旧平文ファイル(省略可)
  if [ -n "${2:-}" ]; then
    _v="${!2:-}"
    if [ -n "$_v" ]; then printf '%s' "$_v"; return 0; fi
  fi
  if [ -x /usr/bin/security ]; then
    _v="$(/usr/bin/security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null | sed 's/^v1://' | base64 --decode 2>/dev/null)"
    if [ -n "$_v" ]; then printf '%s' "$_v"; return 0; fi
  fi
  if [ -n "${3:-}" ] && [ -s "$3" ]; then
    tr -d '\r\n' < "$3"; return 0
  fi
  return 1
}

COACH_MARKER="$LOG_DIR/coach-engine"

# 第 2 引数以降はフラグ。順不同で受ける。
#   --websearch        Web 検索を確認制で有効化
#   --resume           前回の続きから開く（OpenCode の --continue）
#   --free             モデル自由選択モード（無料モデルあり）。DeepSeek キー・送信検査
#                      Gateway を使わず、OpenCode 標準のモデル選択に任せる。permission の
#                      表（deny 床・edit 表・read 表・external_directory・プラグイン床）は
#                      DeepSeek 版と同一（opencode-config.js --free が同じ表から生成する）。
#   --project <path>   作業フォルダ。OpenCode は「起動したフォルダ」が作業対象になり、
#                      動き出したあとで cd しても移らない（本体仕様）。プロジェクトごとに
#                      分けて作業できるよう、起動するフォルダをここで指定する。
WEBSEARCH=""
RESUME=""
LONGRUN=""
FREE=""
PROJECT_DIR=""
# 画面から雇うための「裏で1件だけ実行する」モード用（--task を渡すと TUI を開かず run で走る）
TITLE=""
TASK=""
SESSION=""
_expect_project=0
_expect_title=0
_expect_task=0
_expect_session=0
shift || true
for _arg in "$@"; do
  if [ "$_expect_project" = "1" ]; then
    PROJECT_DIR="$_arg"; _expect_project=0; continue
  fi
  if [ "$_expect_title" = "1" ]; then
    TITLE="$_arg"; _expect_title=0; continue
  fi
  if [ "$_expect_task" = "1" ]; then
    TASK="$_arg"; _expect_task=0; continue
  fi
  if [ "$_expect_session" = "1" ]; then
    SESSION="$_arg"; _expect_session=0; continue
  fi
  case "$_arg" in
    "") ;;
    --websearch) WEBSEARCH="--websearch" ;;
    # 長時間おまかせモード（目を離して走らせる）。確認を出さない代わりに ask だったものは
    # deny 側へ倒す（opencode-config.js --longrun）。deny 床は 1 本も外さない。
    --longrun) LONGRUN="--longrun" ;;
    # モデル自由選択（2026-08-24 依頼者裁定）。無料モデル利用時は送信検査を通らない
    # ことを許容する。安全設定（permission の表）は DeepSeek 版と同一に生成する。
    --free) FREE="--free" ;;
    --resume|--continue) RESUME="--continue" ;;
    --title) _expect_title=1 ;;
    --title=*) TITLE="${_arg#--title=}" ;;
    --task) _expect_task=1 ;;
    --task=*) TASK="${_arg#--task=}" ;;
    --session) _expect_session=1 ;;
    --session=*) SESSION="${_arg#--session=}" ;;
    --project) _expect_project=1 ;;
    --project=*) PROJECT_DIR="${_arg#--project=}" ;;
    *) echo "使い方: $0 [workspace] [--websearch] [--longrun] [--free] [--resume] [--project <フォルダ>] [--title <名前>] [--task <指示>] [--session <ID>]" >&2; exit 2 ;;
  esac
done
[ "$_expect_project" = "0" ] || { echo "--project の後にフォルダを指定してください。" >&2; exit 2; }

[ -d "$WORKSPACE" ] || { echo "作業フォルダが見つかりません: $WORKSPACE" >&2; exit 2; }
# 比較は物理パス（pwd -P）で揃える。macOS の /var → /private/var のようなシンボリックリンクが
# 途中にあると、論理パスのままでは「ワークスペースの中なのに外」と誤判定される。
WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"

# 作業フォルダ（OpenCode を起動する場所）を決める。既定はワークスペース直下。
# ワークスペースの外は指定させない: 安全パッケージのガードとポリシーはワークスペースを
# 基準に配置されており、外で起動すると保護が及ばない場所で AI が動くことになる。
if [ -n "$PROJECT_DIR" ]; then
  [ -d "$PROJECT_DIR" ] || { echo "指定されたフォルダが見つかりません: $PROJECT_DIR" >&2; exit 2; }
  PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
  case "$PROJECT_DIR" in
    "$WORKSPACE"|"$WORKSPACE"/*) ;;
    *)
      echo "作業フォルダはワークスペースの中だけを指定できます（fail-closed）。" >&2
      echo "  指定: $PROJECT_DIR" >&2
      echo "  ワークスペース: $WORKSPACE" >&2
      exit 2
      ;;
  esac
else
  PROJECT_DIR="$WORKSPACE"
fi
[ -f "$GATEWAY_JS" ] || { echo "送信検査 Gateway が見つかりません: $GATEWAY_JS" >&2; exit 2; }
[ -f "$GATEWAY_TOKEN_JS" ] || { echo "送信検査 Gateway の合言葉管理が見つかりません: $GATEWAY_TOKEN_JS" >&2; exit 2; }
[ -f "$CONFIG_JS" ] || { echo "OpenCode 安全設定が見つかりません: $CONFIG_JS" >&2; exit 2; }
[ -f "$MONITOR_PLUGIN" ] || { echo "OpenCode承認モニターが見つかりません: $MONITOR_PLUGIN" >&2; exit 2; }

if [ "${AI_SAFE_DRY_RUN:-0}" = "1" ]; then
  if [ -n "$FREE" ]; then
    echo "OpenCode free-model dry-run"
    echo "  workspace: $WORKSPACE"
    echo "  project:   $PROJECT_DIR"
    echo "  gateway:   none (--free / 送信検査 Gateway を使いません)"
    echo "  config:    OPENCODE_CONFIG_CONTENT"
    echo "  model:     free (OpenCode のモデル一覧から自分で選択)"
  else
  echo "OpenCode + DeepSeek dry-run"
  echo "  workspace: $WORKSPACE"
  echo "  project:   $PROJECT_DIR"
  if [ -n "${DS_GATEWAY_PORT:-}" ]; then
    echo "  gateway:   http://127.0.0.1:$PORT/v1 (mandatory)"
  else
    echo "  gateway:   http://127.0.0.1:8788/v1 (mandatory / 使用中なら 8789-8797 から自動選択)"
  fi
  echo "  config:    OPENCODE_CONFIG_CONTENT"
  echo "  model:     DeepSeek V4 Flash / small: V4 Flash"
  fi
  if [ "$WEBSEARCH" = "--websearch" ]; then
    echo "  websearch: opt-in (approval required)"
  else
    echo "  websearch: off"
  fi
  if [ -n "$RESUME" ]; then
    echo "  session:   continue last"
  else
    echo "  session:   new"
  fi
  exit 0
fi

command -v node >/dev/null 2>&1 || { echo "Node.js が見つかりません。" >&2; exit 1; }
# 安全プラグインが壊れていると「黙って無防備」になるので、起動前に構文まで確かめる。
if ! node --check "$MONITOR_PLUGIN" >/dev/null 2>&1; then
  echo "OpenCode承認モニターが壊れているため、OpenCode は起動しません（fail-closed）。" >&2
  echo "「導入(インストール)」をやり直してください: $MONITOR_PLUGIN" >&2
  exit 1
fi
OPENCODE_BIN="${OPENCODE_BIN:-$(command -v opencode 2>/dev/null || true)}"
[ -n "$OPENCODE_BIN" ] || { echo "OpenCode が見つかりません。先に OpenCode をインストールしてください。" >&2; exit 1; }
# 実キーはここで一度だけ解決する（環境変数 → 金庫 → 旧平文）。金庫に移したあとは
# 旧平文が消えるので、ファイルの有無で判定してはいけない。
# 解決できなければ fail-closed（鍵なしで gateway を立てると素通しの中継になる）。
# --free（モデル自由選択）では DeepSeek キーも Gateway も使わないので、未登録でも止めない。
DS_KEY=""
if [ -z "$FREE" ]; then
  DS_KEY="$(read_secret ai-safety.deepseek DEEPSEEK_API_KEY "$KEY_FILE" || true)"
  [ -n "$DS_KEY" ] || { echo "DeepSeek APIキーが未登録です。先に「DeepSeekキーを登録」を実行してください。" >&2; exit 1; }
fi

VERSION="$("$OPENCODE_BIN" --version 2>/dev/null | head -n1 | tr -d '\r')"
if ! node -e 'const m=require(process.argv[1]);process.exit(m.isSupportedVersion(process.argv[2])?0:1)' "$CONFIG_JS" "$VERSION"; then
  echo "OpenCode 1.14.24 以上が必要です（検出: ${VERSION:-不明}）。" >&2
  exit 1
fi

# そのポートを握っているのが「自分たちの ds-gateway.js」かどうかを、実行中のコマンドラインで
# 確かめる。ポートに何かが応答するだけでは、それが本物の gateway とは限らないため。
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
  for pid in $(lsof -nP -tiTCP:"$_p" -sTCP:LISTEN 2>/dev/null || true); do
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$cmd" in
      *"$GATEWAY_JS"*) kill "$pid" 2>/dev/null || true ;;
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

# 呼び出し元認証の合言葉は、この PC の共有ファイル（実キーと同じ置き場・同じ権限）から取る。
# 以前は起動ごとに採番して、動いている gateway を必ず停止して立て直していた。その方式だと
# OpenCode を 2 枚開いたり d-claude と併用したりすると、後発が先発の gateway を殺すため、
# 先に開いていた窓だけが古い合言葉のまま取り残されて全リクエストが 401 になっていた。
# コマンドライン引数には載せない（ps に出るため）。標準出力で受け取る。
# --free では Gateway を使わないので合言葉も用意しない。
GATEWAY_TOKEN=""
if [ -z "$FREE" ]; then
  GATEWAY_TOKEN="$(node "$GATEWAY_TOKEN_JS" --ensure --gateway "$GATEWAY_JS" 2>/dev/null || true)"
  [ -n "$GATEWAY_TOKEN" ] || { echo "送信検査 Gateway の合言葉を用意できませんでした（fail-closed）。" >&2; exit 1; }
fi

mkdir -p "$LOG_DIR"
GATEWAY_LOG="$LOG_DIR/opencode-deepseek-gateway.log"
: >> "$GATEWAY_LOG" 2>/dev/null || true

# 使うポートを決める。DS_GATEWAY_PORT で明示指定されたときはその 1 つだけを使い（利用者の
# 意図を尊重し、黙って別のポートへ逃げない）、未指定なら既定 8788 から順に空きを探す。
# 8788 が他のプログラム（別プロジェクトの常駐サービス等）に取られている PC があり、
# 決め打ちのままだと「Gateway を確認できない」で起動そのものができなくなるため。
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
#    条件は「自分たちのプロセスであること」と「中身が今と同じであること」の両方。
RECORDED_PORT=""
if [ -z "$FREE" ]; then
  RECORDED_PORT="$(node "$GATEWAY_TOKEN_JS" --recorded-port 2>/dev/null || true)"
fi
if [ -n "$RECORDED_PORT" ] \
   && our_gateway_pid "$RECORDED_PORT" >/dev/null 2>&1 \
   && node "$GATEWAY_TOKEN_JS" --probe --gateway "$GATEWAY_JS" --port "$RECORDED_PORT" >/dev/null 2>&1; then
  PORT="$RECORDED_PORT"
  GATEWAY_REUSED=1
fi

# 2) 再利用できないときは、候補ポートを順に試して自分で立てる。
#    ポートを他に取られていれば gateway は即座に終了するので、次の候補へ進む。
#    --free では gateway を一切立てない（DeepSeek へ送る通信そのものが無い）。
if [ -z "$FREE" ] && [ "$GATEWAY_REUSED" -ne 1 ]; then
  for candidate in $PORT_CANDIDATES; do
    # 自分たちの gateway が中身違い（更新後に古いものが居座っている）で居るなら止める。
    stop_stale_gateway "$candidate"
    # 今回の起動より前のログ行は見ない（追記式のため）。
    _log_from=$(( $(wc -l < "$GATEWAY_LOG" 2>/dev/null || echo 0) + 1 ))
    DS_GATEWAY_PORT="$candidate" \
    DS_GATEWAY_UPSTREAM="https://api.deepseek.com" \
    DEEPSEEK_API_KEY="$DS_KEY" \
    DS_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
    DS_GATEWAY_WORKSPACE="$WORKSPACE" \
      node "$GATEWAY_JS" >>"$GATEWAY_LOG" 2>&1 &
    GW_PID=$!
    if wait_for_own_gateway "$candidate" "$_log_from"; then
      PORT="$candidate"
      break
    fi
    kill "$GW_PID" 2>/dev/null || true
    GW_PID=""
  done
fi

if [ -z "$FREE" ] && [ -z "$PORT" ]; then
  echo "送信検査 Gateway を起動できないため、OpenCode は起動しません（fail-closed）。" >&2
  if [ -n "${DS_GATEWAY_PORT:-}" ]; then
    echo "指定されたポート $DS_GATEWAY_PORT を他のプログラムが使っている可能性があります。" >&2
  else
    echo "ポート 8788〜8797 をすべて他のプログラムが使っている可能性があります。" >&2
  fi
  # 原因の実物（EADDRINUSE 等）を画面にも出す。ログを開かないと分からない状態にしない。
  _last="$(tail -n 3 "$GATEWAY_LOG" 2>/dev/null || true)"
  [ -n "$_last" ] && { echo "Gateway が出したメッセージ:" >&2; printf '  %s\n' "$_last" >&2; }
  echo "確認先: $GATEWAY_LOG" >&2
  exit 1
fi

WATCHDOG_PID=""
# coach マーカーは d-claude と OpenCode が同じパスを共有する。並行起動時に片方の終了で
# もう片方のバナーが消えないよう、「自分が書いた値のままのときだけ」消す。
remove_own_coach_marker() {
  case "$(cat "$COACH_MARKER" 2>/dev/null || true)" in
    opencode-deepseek|opencode-free) rm -f "$COACH_MARKER" 2>/dev/null || true ;;
  esac
  return 0
}
cleanup() {
  # 自分で立てた gateway だけを止める。共用中の gateway（GATEWAY_REUSED=1）を止めると、
  # 同時に開いている別の窓の通信をこちらの終了で巻き添えにしてしまう。
  [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
  remove_own_coach_marker
  return 0
}
trap cleanup EXIT INT TERM HUP

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
if [ -z "$FREE" ] && [ "$gateway_alive" -ne 1 ]; then
  echo "送信検査 Gateway を確認できないため、OpenCode は起動しません（fail-closed）。" >&2
  echo "確認先: $GATEWAY_LOG" >&2
  exit 1
fi
if [ "$GATEWAY_REUSED" = "1" ]; then
  echo "稼働中の送信検査 Gateway をそのまま使います（127.0.0.1:${PORT}）。"
elif [ -z "$FREE" ] && [ "$PORT" != "8788" ]; then
  # 既定ポートが空いていなかったことは、黙って別ポートに逃げず利用者へ伝える。
  echo "ポート 8788 は他のプログラムが使っていたため、送信検査 Gateway は 127.0.0.1:${PORT} で動かします。"
fi

# 実キーは Gateway 子プロセスだけが読み、OpenCode の環境には渡さない。
# 一覧は opencode-config.js が持つ（Windows 版と 1 か所で共有するため）。ここで先に消すのは、
# 消す前に設定を作ると「鍵があるので MCP を登録したのに、その鍵が MCP へ届かない」状態に
# なるため。検索・画像読取は ~/.ai-safety/gemini-api-key.txt（「7_AIコーチのキーを登録」が
# 書く場所）だけを見るので、環境変数しか持っていない人にはここで案内を出す。
SECRET_ENV_VARS="$(node "$CONFIG_JS" --print-secret-env)"
[ -n "$SECRET_ENV_VARS" ] || { echo "OpenCode 安全設定を生成できませんでした。" >&2; exit 1; }
if [ -n "${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}" ] && ! read_secret ai-safety.gemini '' "$HOME/.ai-safety/gemini-api-key.txt" >/dev/null 2>&1; then
  echo "注意: 環境変数の Gemini キーは OpenCode へ渡しません（AI から見えてしまうため）。" >&2
  echo "      検索と画像読み取りを使うときは「キーと金庫/3_AIコーチのキーを登録」で登録してください。" >&2
fi
# shellcheck disable=SC2086
unset $SECRET_ENV_VARS 2>/dev/null || true
# deny 床そのものを決めるポリシーの置き場を、環境変数で差し替えられないようにする。
# 無害な正規表現だけのポリシーを指されると、決定的 deny 床が丸ごと消える。
unset AI_SAFE_POLICY AI_SAFE_ROOT 2>/dev/null || true

# プロジェクト固有の設定は無効化し、隔離した設定ディレクトリからBouncerプラグインだけを読む。
export OPENCODE_DISABLE_PROJECT_CONFIG=1
unset OPENCODE_PURE 2>/dev/null || true
# 強制設定を後から丸ごと無効化できる環境変数を先に消す。
# OPENCODE_PERMISSION と OPENCODE_TEST_MANAGED_CONFIG_DIR は OPENCODE_CONFIG_CONTENT より
# 後にマージされるため、外から仕込まれていると deny 床がそのまま外れる（1.18.4 実測）。
unset OPENCODE_PERMISSION OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_TEST_MANAGED_CONFIG_DIR 2>/dev/null || true
export XDG_CONFIG_HOME="$WORKSPACE/.ai-safety/opencode-runtime/xdg-config"
export AI_SAFE_LOG_DIR="$LOG_DIR"
mkdir -p "$XDG_CONFIG_HOME"

# --- 日本語ハーネスの配置 ---------------------------------------------------
# OPENCODE_DISABLE_PROJECT_CONFIG=1 では作業フォルダの .opencode/ は一切読まれず、
# 作業フォルダ側 AGENTS.md の探索も止まる。一方、設定ディレクトリ直下の AGENTS.md は
# instructions の指定と関係なく無条件で読み込まれる（1.18.4 実測）。そこで
# 「隔離設定ディレクトリ側」にパッケージ同梱のハーネス一式を毎回置き直す。
#   - AGENTS.md            … 日本語の指示書本体（設定ディレクトリ直下＝無条件で読まれる）
#   - command(s)/*.md      … 日本語スラッシュコマンド（1.18.4 は単数・複数どちらも読む）
#   - agents/*.md          … 追加エージェント（読み取り専用「せんせい」等）
#   - skills/<名前>/       … 配布スキル（hearing-ladder 等）
# 同梱物の名前を決め打ちせず、配布元にある物をそのまま写す（将来 1 本増えても配線不要）。
# 毎回置き直すので、ここを書き換えられてもパッケージ側の内容が必ず勝つ。
# 中身が無いときは警告だけ出して続行する（保護には影響しないため止めない）。
OC_CONFIG_DIR="$XDG_CONFIG_HOME/opencode"
HARNESS_SRC="$WORKSPACE/.ai-safety/opencode-harness"
SKILLS_SRC="$WORKSPACE/.ai-safety/dist-skills"
# 消す前に「本当に自分が作った隔離設定ディレクトリか」を完全一致で確かめる。
# ここを前方一致だけで済ませると、環境変数の細工で受講者の作業フォルダを消しかねない。
if [ "$OC_CONFIG_DIR" != "$WORKSPACE/.ai-safety/opencode-runtime/xdg-config/opencode" ]; then
  echo "設定ディレクトリの場所が想定外のため、OpenCode は起動しません（fail-closed）。" >&2
  exit 1
fi
mkdir -p "$OC_CONFIG_DIR"

# --- OpenCode が読む場所を毎回まっさらにする -------------------------------------
# 「配布物にある名前だけ置き直す」方式だと、配布物に無い綴り（単数形の agent/ command/、
# mode/、skill/、themes/）へ仕込まれた定義が次の起動でも生き残る（1.18.4 のバイナリ実測:
# {agent,agents}/**/*.md ・ {command,commands}/**/*.md ・ {mode,modes}/*.md ・
# {plugin,plugins}/*.{ts,js} ・ skill/ と skills/ ・ themes/*.json を読む）。読む場所を
# 先に消してから配布物を置き直せば、綴りの取りこぼしが構造的に起きない。
# 消すのは上で場所を完全一致で確かめた隔離設定ディレクトリの中だけ。node_modules /
# package.json / bun.lock は OpenCode がプラグインの依存を入れる場所なので残す
# （毎回消すと起動のたびにダウンロードが走り、教室の PC では実用にならない）。
for _known in agent agents command commands mode modes plugin plugins skill skills themes; do
  rm -rf "$OC_CONFIG_DIR/$_known"
done
# config.json も消す（1.18.4 実測: 設定ディレクトリ直下の config.json も設定として読む。
# opencode.json5 / .opencoderc / config.jsonc は読まないので、増やすのはこの 1 本だけ）。
rm -f "$OC_CONFIG_DIR/AGENTS.md" "$OC_CONFIG_DIR/opencode.json" "$OC_CONFIG_DIR/opencode.jsonc" \
  "$OC_CONFIG_DIR/config.json"

if [ -d "$HARNESS_SRC" ]; then
  for _entry in "$HARNESS_SRC"/*; do
    [ -e "$_entry" ] || continue
    _name="$(basename "$_entry")"
    # plugin/ だけは写さない。設定ディレクトリの plugin は無条件で実行されるので、
    # 動くコードは「ランチャーが明示的に渡す Bouncer 監視プラグイン 1 本」に限る。
    case "$_name" in
      plugin|plugins) echo "注意: 配布物の $_name は安全のため配置しません。" >&2; continue ;;
    esac
    if [ -d "$_entry" ]; then
      rm -rf "$OC_CONFIG_DIR/$_name"
      mkdir -p "$OC_CONFIG_DIR/$_name"
      cp -R "$_entry/." "$OC_CONFIG_DIR/$_name/"
    else
      cp "$_entry" "$OC_CONFIG_DIR/$_name"
    fi
  done
  [ -f "$OC_CONFIG_DIR/AGENTS.md" ] \
    || echo "注意: 日本語の指示書が見つからないため配置をとばしました: $HARNESS_SRC/AGENTS.md" >&2
else
  echo "注意: 日本語の指示書が見つからないため配置をとばしました: $HARNESS_SRC" >&2
fi

if [ -d "$SKILLS_SRC" ]; then
  mkdir -p "$OC_CONFIG_DIR/skills"
  for _skill in "$SKILLS_SRC"/*/; do
    [ -f "$_skill/SKILL.md" ] || continue
    _name="$(basename "$_skill")"
    rm -rf "$OC_CONFIG_DIR/skills/$_name"
    cp -R "$_skill" "$OC_CONFIG_DIR/skills/$_name"
  done
else
  echo "注意: 配布スキルが見つからないため配置をとばしました: $SKILLS_SRC" >&2
fi

# --- 設定ディレクトリのシンボリックリンクを禁じる（fail-closed）-------------------
# opencode 1.18.4 は command / agent / mode を `symlink:true` で走査する＝リンクの
# 先にある .md も読む。リンクを 1 本置かれるだけで「配置し直した安全なファイルを見て
# いるつもりが、まったく別の場所のファイルを読ませられる」形になる。配布物に
# シンボリックリンクは 1 本も無いので、あれば作為とみなして起動しない。ただし
# node_modules は OpenCode が管理する依存キャッシュで、.bin に通常のリンクが作られる。
# 実ディレクトリである node_modules の中だけは降りず、node_modules 自体がリンクなら止める。
_link_hits="$(
  find "$OC_CONFIG_DIR" \
    -path "$OC_CONFIG_DIR/node_modules" -type d -prune -o \
    -type l -print 2>/dev/null || true
)"
if [ -n "$_link_hits" ]; then
  echo "設定フォルダにショートカット（シンボリックリンク）が置かれていたため、OpenCode は起動しません（fail-closed）。" >&2
  printf '%s\n' "$_link_hits" | while IFS= read -r _f; do [ -n "$_f" ] && echo "  対象: $_f" >&2; done
  echo "「導入(インストール)」をやり直してください。それでも出る場合は講師に連絡してください。" >&2
  exit 1
fi

# --- スラッシュコマンドの中の「シェル実行」を禁じる（fail-closed）-----------------
# コマンド .md の本文に書かれた !`コマンド` は、テンプレート展開時に受講者のシェルへ
# そのまま渡されて実行される（1.18.4 のバイナリ内 /!`([^`]+)`/g → shell 実行を確認）。
# これはツール呼び出しを経ないので permission の確認も、承認モニターの決定的 deny 床も
# 通らない＝安全機構を丸ごと迂回する任意コード実行になる。配布物にこの書き方は無いので、
# 「配置後の実ファイル」を見て 1 つでもあれば起動しない（配置後に書き換えられた場合も拾う）。
#
# 走査は OpenCode 自身の依存キャッシュ node_modules を除く設定ディレクトリ全体にかける。
# node_modules の JavaScript には通常のテンプレートリテラル末尾として !` が現れるため、
# コマンド定義と同じ検査をすると誤検出になる。opencode が読むのは command(s) / agent(s) /
# mode(s) だが、フォルダ名を並べて数え上げる書き方は取りこぼす（mode を書き忘れる、
# 大文字の Commands を見落とす、といった形）。配布物のどのファイルにもこの書き方は
# 無いので、依存キャッシュ以外を全部見て 1 件でもあれば止める。
_shell_expansion_hits="$(
  find "$OC_CONFIG_DIR" \
    -path "$OC_CONFIG_DIR/node_modules" -type d -prune -o \
    -type f -exec grep -lF '!`' {} + 2>/dev/null || true
)"
if [ -n "$_shell_expansion_hits" ]; then
  echo "コマンド定義に「確認なしでコマンドを実行する書き方」が含まれていたため、OpenCode は起動しません（fail-closed）。" >&2
  printf '%s\n' "$_shell_expansion_hits" | while IFS= read -r _f; do [ -n "$_f" ] && echo "  対象: $_f" >&2; done
  echo "「導入(インストール)」をやり直してください。それでも出る場合は講師に連絡してください。" >&2
  exit 1
fi

# --- 利用者が自分で入れたプラグインの配置 -----------------------------------------
# 配布物の plugin/ を写さない方針（上）はそのまま。そのうえで「利用者が自分の意思で置いた
# プラグイン」だけを通す道を 1 本用意する。置き場は作業フォルダの .ai-safety/plugins/ に
# 限り、その直下の .js / .ts を隔離設定ディレクトリの plugin/ へ毎回写す。サブフォルダは
# 見ない（画面に一覧として出せる範囲に限るため）。
# 設定ディレクトリの plugin は無条件で実行される＝ここに置いたコードは承認モニターの
# 決定的 deny 床を通らないどころか、見守りの仕組みそのものを止めることもできる。
#
# 歯止めの作り方について（レビュー指摘を受けた設計）:
#   画面に名前を出すだけでは歯止めにならない。この直後に走る `opencode debug config` が
#   プラグインを実際に読み込み、その数百ミリ秒後に全画面 TUI がメッセージごと画面を消す
#   ため、利用者が読み終わる前に実行が済んでいる（このスクリプト自身が別の箇所で
#   「TUI は全画面なので画面出力では気づけない」と結論している）。
#   そこで「顔ぶれ（名前＋中身のハッシュ）が前回と変わったときだけ、Enter を求めて止まる」
#   方式にした。毎回は聞かないので普段の起動は静かなまま、新しい物が増えた・中身が
#   差し替わったときだけ必ず人の手が要る。承認の記録は監査ログにも残す。
#   端末が対話可能でないとき（stdin が TTY でない）は、返事を取れないので配置しない。
#
# 位置について: 上の 2 つの検査（シンボリックリンク禁止・スラッシュコマンドの !`…` 禁止）は
# 「配布物のハーネスが差し替えられていないか」を見るためのもので、配布物に無い書き方が 1 つ
# でもあれば起動を止める。利用者のプラグインは配布物ではなく本人が承知の上で置いた
# JavaScript なので、その 2 つの検査より後に写す。とくに !`…` の検査は .md のテンプレート
# 展開を止めるためのもので、ふつうの JavaScript（`…!` で終わるテンプレート文字列など）に
# 当てると、本人が置いたプラグインが理由の分からない fail-closed で弾かれる。
USER_PLUGIN_SRC="$WORKSPACE/.ai-safety/plugins"
USER_PLUGIN_DEST="$OC_CONFIG_DIR/plugin"
if [ -L "$USER_PLUGIN_SRC" ]; then
  # 置き場そのものがショートカットだと、写す物の出所が作業フォルダの外になる。
  echo "注意: 追加プラグインの置き場がショートカットのため読み込みません: $USER_PLUGIN_SRC" >&2
elif [ -d "$USER_PLUGIN_SRC" ]; then
  _user_plugin_files=()
  _user_plugin_names=""
  for _entry in "$USER_PLUGIN_SRC"/*.js "$USER_PLUGIN_SRC"/*.ts; do
    # 一致が無いときはパターン文字列そのものが渡ってくるので、実在確認で弾く。
    [ -e "$_entry" ] || continue
    if [ -L "$_entry" ]; then
      echo "注意: ショートカット（シンボリックリンク）は配置しません: $_entry" >&2
      continue
    fi
    [ -f "$_entry" ] || continue
    # 名前は画面に出す唯一の手掛かりなので、制御文字（行消去などの端末エスケープ）を落とす。
    _name="$(basename "$_entry" | tr -d '[:cntrl:]')"
    _user_plugin_files+=("$_entry")
    _user_plugin_names="${_user_plugin_names:+$_user_plugin_names, }$_name"
  done
  if [ "${#_user_plugin_files[@]}" -gt 0 ]; then
    # 顔ぶれの指紋 = 名前と中身のハッシュ。中身だけ差し替えられた場合も検知する。
    _plugin_fp="$(for _entry in "${_user_plugin_files[@]}"; do
      printf '%s %s\n' "$(basename "$_entry")" "$(shasum -a 256 "$_entry" 2>/dev/null | cut -d' ' -f1)"
    done | sort)"
    _plugin_state="$LOG_DIR/opencode-user-plugins.approved"
    _plugin_prev=""
    [ -f "$_plugin_state" ] && _plugin_prev="$(cat "$_plugin_state" 2>/dev/null || true)"

    # 20 件を超えたら丸めて出す（1 行が巨大化すると「見せる」歯止めが崩れるため）
    _plugin_count="${#_user_plugin_files[@]}"
    _plugin_shown="$_user_plugin_names"
    if [ "$_plugin_count" -gt 20 ]; then
      _plugin_shown="$(printf '%s' "$_user_plugin_names" | cut -d',' -f1-20), ほか $((_plugin_count - 20)) 件"
    fi

    if [ "$_plugin_fp" != "$_plugin_prev" ]; then
      echo ""
      echo "────────────────────────────────────────"
      echo "追加プラグインの顔ぶれが前回と変わりました。"
      echo "  読み込むもの: $_plugin_shown"
      echo "  置き場: $USER_PLUGIN_SRC"
      echo ""
      echo "これはあなたが置いたコードです。OpenCode の中で無条件に実行され、"
      echo "見守り（承認モニター）を止めることもできます。中身に心当たりがありますか？"
      echo "────────────────────────────────────────"
      if [ -t 0 ]; then
        printf "続けるには Enter、やめるには Ctrl+C を押してください: "
        read -r _plugin_answer || true
        printf '%s' "$_plugin_fp" > "$_plugin_state" 2>/dev/null || true
      else
        # 返事を取れない状況（TTY でない）では、承認されていないコードは動かさない。
        echo "注意: 対話できない状態のため、追加プラグインは読み込みません。" >&2
        _user_plugin_files=()
      fi
    fi

    if [ "${#_user_plugin_files[@]}" -gt 0 ]; then
      echo "次の追加プラグインを読み込みます: $_plugin_shown"
      mkdir -p "$USER_PLUGIN_DEST"
      for _entry in "${_user_plugin_files[@]}"; do
        cp "$_entry" "$USER_PLUGIN_DEST/$(basename "$_entry")"
      done
      # 画面は TUI で流れるため、監査ログ（見守り画面の履歴）にも残す。
      printf '{"ts":"%s","type":"user_plugins_loaded","names":"%s","count":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_user_plugin_names" "$_plugin_count" \
        >> "$LOG_DIR/events-$(date +%Y-%m-%d).jsonl" 2>/dev/null || true
    fi
  fi
fi

# 合言葉は provider の apiKey として設定に埋め込む（gateway 側で照合される）。
# opencode-config.js へは環境変数で渡す（引数にすると ps に出る）。この行限定の
# 環境変数なのでランチャー自身の環境には残らない。
# --free ではポートも合言葉も要らない（provider を注入しない設定を生成する）。
if [ -n "$FREE" ]; then
  CONFIG_ARGS=(--free --monitor-plugin "$MONITOR_PLUGIN")
else
  CONFIG_ARGS=(--port "$PORT" --monitor-plugin "$MONITOR_PLUGIN")
fi
if [ -n "$LONGRUN" ]; then CONFIG_ARGS+=("$LONGRUN"); fi
if [ "$WEBSEARCH" = "--websearch" ]; then
  export OPENCODE_ENABLE_EXA=1
  export OPENCODE_CONFIG_CONTENT
  OPENCODE_CONFIG_CONTENT="$(DS_GATEWAY_TOKEN="$GATEWAY_TOKEN" node "$CONFIG_JS" "${CONFIG_ARGS[@]}" --websearch)"
  echo "Web検索を有効にしました。検索語は外部サービスへ送信され、実行前に確認が出ます。"
else
  unset OPENCODE_ENABLE_EXA 2>/dev/null || true
  export OPENCODE_CONFIG_CONTENT
  OPENCODE_CONFIG_CONTENT="$(DS_GATEWAY_TOKEN="$GATEWAY_TOKEN" node "$CONFIG_JS" "${CONFIG_ARGS[@]}")"
fi
[ -n "$OPENCODE_CONFIG_CONTENT" ] || { echo "OpenCode 安全設定を生成できませんでした。" >&2; exit 1; }

# 消すだけでなく「安全な値で上書き」して二重化する。環境変数側が最後にマージされるので、
# 将来マージ順が変わっても最小限の deny 床（削除・昇格・公開・外部通信・外部フォルダ）は残る。
OPENCODE_PERMISSION="$(node "$CONFIG_JS" --print-permission-env ${LONGRUN:+$LONGRUN})"
[ -n "$OPENCODE_PERMISSION" ] || { echo "OpenCode 安全設定を生成できませんでした。" >&2; exit 1; }
export OPENCODE_PERMISSION

# 合言葉の受け渡し用変数も消す（OpenCode へは設定内の apiKey として渡るので不要）。
unset DS_GATEWAY_AUTH_FILE DS_GATEWAY_TOKEN 2>/dev/null || true

# OpenCode は「起動したフォルダ」が作業対象になる（動き出したあとで cd しても移らない）。
# プロジェクトごとに分けて作業できるよう、ここで指定されたフォルダへ移ってから起動する。
cd "$PROJECT_DIR"

# --- 本体を出す前に「安全プラグインが本当に載るか」を実物で確かめる ----------------
# `opencode debug config` はプラグインを実際に読み込む（1.18.4 実測: プラグインの中で
# ファイルを書かせて確認）。そこでこれを本体より先に 1 回だけ同期実行し、
#   (1) 解決済み設定で deny 床が生きているか
#   (2) プラグインが ready マーカーを書いたか（＝決定的 deny 床が載ったか）
# の両方を確かめてから本体を起動する。以前はどちらも「起動してから 30 秒後に気づく」
# 形だったため、無防備な OpenCode がそのまま動き続けていた。
READY_MARKER="$LOG_DIR/opencode-monitor-ready.json"
FAILED_RESOLVED="$LOG_DIR/opencode-resolved-config.failed.txt"
rm -f "$READY_MARKER" 2>/dev/null || true
rm -f "$FAILED_RESOLVED" 2>/dev/null || true
PLUGIN_PROBE_SINCE="$(node -e 'process.stdout.write(String(Date.now()))')"

resolved="$("$OPENCODE_BIN" debug config 2>/dev/null || true)"
if [ -z "$resolved" ]; then
  echo "安全設定を確認できないため、OpenCode は起動しません（fail-closed）。" >&2
  echo "OpenCode が古い可能性があります。最新版に更新してから、もう一度お試しください。" >&2
  exit 1
fi
if ! printf '%s' "$resolved" | node "$CONFIG_JS" --verify-resolved ${LONGRUN:+$LONGRUN}; then
  resolved_safe="${resolved//$GATEWAY_TOKEN/REDACTED}"
  # 解決済み設定には、リモート MCP（Buffer 等）の鍵も Authorization ヘッダとして入る。
  # 診断ファイルは講師へ共有してもらう前提なので、鍵は残さず伏せる。
  _remote_key="$(read_secret ai-safety.buffer '' "$HOME/.ai-safety/buffer-api-key.txt" || true)"
  [ -n "$_remote_key" ] && resolved_safe="${resolved_safe//$_remote_key/REDACTED}"
  unset _remote_key
  ( umask 077; printf '%s' "$resolved_safe" > "$FAILED_RESOLVED" ) 2>/dev/null || true
  echo "安全設定が有効になっていないため、OpenCode は起動しません（fail-closed）。" >&2
  echo "診断ファイル: $FAILED_RESOLVED" >&2
  echo "このファイルを講師へ共有してください（Gatewayの合言葉は伏せてあります）。" >&2
  exit 1
fi
# 終了コードだけでなく合図の 1 行も要求する。何かの理由で検査そのものが走らなかったとき、
# 「黙って 0 で終わった」を「確認できた」と取り違えないため。
ready_signal="$(node "$MONITOR_PLUGIN" --verify-ready --not-before "$PLUGIN_PROBE_SINCE" || true)"
case "$ready_signal" in
  *BOUNCER_READY_OK*) ;;
  *)
    echo "危険なコマンドを止める安全プラグインが読み込まれないため、OpenCode は起動しません（fail-closed）。" >&2
    if [ -n "${_user_plugin_names:-}" ]; then
      # 「導入をやり直す」では .ai-safety/plugins/ は消えないので、こちらを先に案内する。
      echo "" >&2
      echo "この起動では、あなたが置いた追加プラグインを読み込んでいます: $_user_plugin_names" >&2
      echo "まず次のフォルダから中身を別の場所へ移して、もう一度お試しください:" >&2
      echo "  $USER_PLUGIN_SRC" >&2
      echo "（プラグインの書き方が誤っていると、OpenCode はプラグインの読み込み全体を中止します）" >&2
      echo "" >&2
    fi
    echo "「導入(インストール)」をやり直してから、もう一度お試しください。" >&2
    exit 1 ;;
esac

# 見張り: 本体のセッションでもプラグインが読み込まれたかを ready マーカーで確かめ、
# 読み込まれていなければ監視画面の履歴に警告を残す（TUI は全画面なので画面出力では気づけない）。
# 上の確認で書かれたマーカーを消してから始めるので、今回のセッション分だけを見る。
rm -f "$READY_MARKER" 2>/dev/null || true
node "$MONITOR_PLUGIN" --watchdog --timeout-ms 30000 >/dev/null 2>&1 &
WATCHDOG_PID=$!

# coach マーカーの値はモニターが「本文が DeepSeek へ流れる」バナーの判定に使う。
# --free では DeepSeek へは流れない（選んだモデルの提供元へ直接流れる）ので別の値にする。
if [ -n "$FREE" ]; then
  printf 'opencode-free' > "$COACH_MARKER" 2>/dev/null || true
  echo "送信検査（伏せる人）: なし / モデル: OpenCode の一覧から自分で選択（無料モデルあり）"
  echo "会話の内容は選んだモデルの提供元へ直接送信されます（マスキングは掛かりません）。"
else
  printf 'opencode-deepseek' > "$COACH_MARKER" 2>/dev/null || true
  echo "送信検査（伏せる人）: 有効 / モデル: DeepSeek V4 Flash / 補助: V4 Flash"
fi
echo "変更操作は確認、外部フォルダは禁止、Web検索は${WEBSEARCH:+許可時のみ}$( [ -n "$WEBSEARCH" ] || printf '無効' )です。"
echo "危険なコマンド（まとめて削除・鍵の読み出し・ネットから拾った実行）は確認なしで止まります。"

# --task が来たときは対話画面(TUI)を開かず、その 1 件だけを裏で走らせて終わる。
# 可視化ダッシュボードの「雇用する」「話しかける」から使うための入口。
# ここまでの安全設定（送信検査 Gateway・deny 床・承認モニター・ハーネス配置・
# 利用者プラグインの承認）は、対話起動とまったく同じものが効いた状態で走る。
if [ -n "$TASK" ]; then
  if [ -n "$SESSION" ]; then
    echo "続きの指示を渡します（セッション: $SESSION）。"
    exec "$OPENCODE_BIN" run --session "$SESSION" --auto "$TASK"
  fi
  if [ -n "$TITLE" ]; then
    echo "裏で 1 件だけ実行します（名前: $TITLE）。"
    exec "$OPENCODE_BIN" run --title "$TITLE" --auto "$TASK"
  fi
  echo "裏で 1 件だけ実行します。"
  exec "$OPENCODE_BIN" run --auto "$TASK"
fi

# --resume が指定されたときは前回のセッションを開き直す。会話は OpenCode 自身が
# ローカル（~/.local/share/opencode）に保存しているので、前の窓が落ちても続きから戻れる。
if [ -n "$RESUME" ]; then
  echo "前回の続きから開きます（新しく始めるときは「続きから」ではないボタンを使ってください）。"
  "$OPENCODE_BIN" --continue
else
  "$OPENCODE_BIN"
fi
