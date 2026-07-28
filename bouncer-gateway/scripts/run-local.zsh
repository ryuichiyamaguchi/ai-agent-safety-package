#!/bin/zsh
set -euo pipefail

TASK_ROOT="${0:A:h:h}"
LMS_BIN="${HOME}/.lmstudio/bin/lms"
STARTED_SERVER=0
STARTED_MODEL=0

if [[ ! -x "${LMS_BIN}" ]]; then
  print -u2 "LM Studio の lms コマンドが見つかりません: ${LMS_BIN}"
  print -u2 "先に LM Studio をインストールし、lms コマンドを有効にしてください。"
  exit 1
fi

cleanup() {
  if [[ "${STARTED_MODEL}" == "1" ]]; then
    "${LMS_BIN}" unload bouncer-gemma >/dev/null 2>&1 || true
  fi
  if [[ "${STARTED_SERVER}" == "1" ]]; then
    "${LMS_BIN}" server stop >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM HUP

# lms server status の出力から状態を判定する。
#
# 「動いていない」ときの応答 "The server is not running" にも running という語が
# 含まれるため、部分一致では肯定と否定を区別できない。行頭からの定型文で別々に
# 判定し、どちらとも読めないときは憶測で進めずに中止する（安全側）。
# Windows 版 run-local.ps1 の Get-LmsServerState と同じ考え方・同じ分類
# （running / stopped / unknown）にそろえてある。
lms_server_state() {
  local text="$1"
  local line indent trimmed
  while IFS= read -r line; do
    indent="${line%%[![:space:]]*}"
    trimmed="${line#"${indent}"}"
    case "${trimmed}" in
      'The server is not running'*) print -r -- "stopped"; return 0 ;;
      'The server is running'*)     print -r -- "running"; return 0 ;;
    esac
  done <<< "${text}"
  print -r -- "unknown"
}

# 終了コードやエラー出力で落とさず、本文だけを取り出す（判定は本文で行う）。
server_status="$("${LMS_BIN}" server status 2>&1 || true)"
server_state="$(lms_server_state "${server_status}")"

if [[ "${server_state}" == "unknown" ]]; then
  print -u2 "LM Studio サーバーの状態を判定できませんでした。安全のため起動を中止します。"
  print -u2 "lms server status の出力: ${server_status}"
  exit 1
fi

if [[ "${server_state}" == "stopped" ]]; then
  if ! "${LMS_BIN}" server start --port 1234 --bind 127.0.0.1; then
    print -u2 "LM Studio サーバーを起動できませんでした。"
    exit 1
  fi
  STARTED_SERVER=1
fi

# lms ps は読み込み済みモデルの一覧を出す。一覧を取れていないのに
# 「bouncer-gemma が無い」と解釈すると、読み込み済みのモデルを二重に読もうとして
# 失敗するため、出力が空なら判定不能として中止する（安全側）。
model_status="$("${LMS_BIN}" ps 2>&1 || true)"
if [[ -z "${model_status//[[:space:]]/}" ]]; then
  print -u2 "LM Studio の読み込み済みモデルを確認できませんでした。安全のため起動を中止します。"
  exit 1
fi

if [[ "${model_status}" != *bouncer-gemma* ]]; then
  if ! "${LMS_BIN}" load google/gemma-4-12b \
    --context-length 4096 \
    --parallel 1 \
    --identifier bouncer-gemma \
    --yes; then
    print -u2 "Bouncer 用の Gemma モデルを読み込めませんでした。"
    exit 1
  fi
  STARTED_MODEL=1
fi

export BOUNCER_HOST="${BOUNCER_HOST:-127.0.0.1}"
export BOUNCER_PORT="${BOUNCER_PORT:-8787}"
export BOUNCER_LM_STUDIO_URL="${BOUNCER_LM_STUDIO_URL:-http://127.0.0.1:1234/v1}"
export BOUNCER_LOCAL_MODEL="${BOUNCER_LOCAL_MODEL:-bouncer-gemma}"
export BOUNCER_AI_MODE="${BOUNCER_AI_MODE:-balanced}"
export BOUNCER_AI_FAILURE_MODE="${BOUNCER_AI_FAILURE_MODE:-block}"
export BOUNCER_REVIEW_MODE="${BOUNCER_REVIEW_MODE:-block}"
export PYTHONPATH="${TASK_ROOT}/src"

python3 -m bouncer serve
