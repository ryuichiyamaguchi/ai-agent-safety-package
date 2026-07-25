#!/bin/zsh
set -euo pipefail

TASK_ROOT="${0:A:h:h}"
LMS_BIN="${HOME}/.lmstudio/bin/lms"
STARTED_SERVER=0
STARTED_MODEL=0

if [[ ! -x "${LMS_BIN}" ]]; then
  print -u2 "LM Studio CLI was not found: ${LMS_BIN}"
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

if ! "${LMS_BIN}" server status | rg -q '^The server is running'; then
  "${LMS_BIN}" server start --port 1234 --bind 127.0.0.1
  STARTED_SERVER=1
fi

if ! "${LMS_BIN}" ps | rg -q 'bouncer-gemma'; then
  "${LMS_BIN}" load google/gemma-4-12b \
    --context-length 4096 \
    --parallel 1 \
    --identifier bouncer-gemma \
    --yes
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
