#!/usr/bin/env bash
set -euo pipefail

# 受講者のシェルに残っていた AI_SAFE_POLICY / AI_SAFE_ROOT で deny 床ごと差し替えられる
# のを防ぐため、起動時に必ず捨てる（このあと同梱ポリシーを自分で設定する）。
# 万一これが漏れても、ガード側(lib/safety_policy.sh / lib/SafetyPolicy.ps1)が同梱パス以外を
# 拒否するので床は残る。ここは二重の保険。
unset AI_SAFE_POLICY AI_SAFE_ROOT

usage() {
  cat <<'EOF'
Usage:
  launch-integrated.sh [workspace] [codex|claude|opencode|d-claude] [standard|assisted|maximum] [--websearch] [--resume] [--project=<フォルダ>]

Profiles:
  standard  Safety hooks + approval monitor. No local LLM is required.
  assisted  Claude only. Standard profile plus two-key AI review for gray commands.
  maximum   Claude only. Adds the local Gemma Bouncer gateway and full response review.

OpenCode:
  standard only. DeepSeek V4 Pro/Flash is routed through the send inspection gateway.
  Web search is off by default; --websearch makes it approval-based.

d-claude:
  standard only. Claude Code UX with DeepSeek, safety hooks, Bouncer monitor,
  and the same fail-closed send inspection gateway.
EOF
}

workspace="${1:-$(pwd)}"
agent="${2:-codex}"
profile="${3:-standard}"
# 第 4・第 5 引数は OpenCode 用のフラグ。--resume は前回のセッションを開き直す。
# 配列にしないのは macOS 標準の bash 3.2 では set -u と空配列展開の相性が悪いため。
extra="${4:-}"
extra2="${5:-}"

case "$agent" in
  codex|claude|opencode|d-claude) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "agent must be codex, claude, opencode, or d-claude" >&2; usage >&2; exit 2 ;;
esac

case "$profile" in
  standard|assisted|maximum) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "profile must be standard, assisted, or maximum" >&2; usage >&2; exit 2 ;;
esac

if [ "$agent" = "codex" ] && [ "$profile" != "standard" ]; then
  echo "Codex は standard モードで起動してください。" >&2
  echo "Codex 自身の on-request + auto_review が承認要求を確認します。" >&2
  exit 2
fi
if [ "$agent" = "opencode" ] && [ "$profile" != "standard" ]; then
  echo "OpenCode は standard モードで起動してください。" >&2
  exit 2
fi
if [ "$agent" = "d-claude" ] && [ "$profile" != "standard" ]; then
  echo "d-claude は standard モードで起動してください。" >&2
  exit 2
fi
for _flag in "$extra" "$extra2"; do
  case "$_flag" in
    "") ;;
    --websearch|--resume|--project=*)
      if [ "$agent" != "opencode" ]; then
        echo "--websearch / --resume / --project は OpenCode だけで指定できます。" >&2
        exit 2
      fi
      ;;
    *)
      echo "第4引数以降に指定できるのは --websearch / --resume / --project=<フォルダ> だけです。" >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$workspace" ]; then
  echo "作業フォルダが見つかりません: $workspace" >&2
  exit 2
fi

workspace="$(cd "$workspace" && pwd)"
# どのボタン(スタート等)から呼ばれても、AI は必ず作業フォルダを起点に起動する。
# Claude Code は起動時の cwd を CLAUDE_PROJECT_DIR とし、配布 settings のフックを
# $CLAUDE_PROJECT_DIR/.ai-safety/... から解決するため、cwd が workspace の外だと
# ガード欠落(fail-closed)で全プロンプトがブロックされる。
cd "$workspace"
root="$workspace/.ai-safety"
hooks="$root/hooks/macos"
log_dir="${AI_SAFE_LOG_DIR:-$HOME/.ai-safety/logs}"
mkdir -p "$log_dir"

[ -x "$hooks/open-monitor.sh" ] || {
  echo "Bouncer統合版がこの作業フォルダに導入されていません。" >&2
  echo "先に統合版のインストーラーを実行してください。" >&2
  exit 2
}

if [ "${AI_SAFE_DRY_RUN:-0}" = "1" ]; then
  if [ "$profile" = "maximum" ] && [ ! -x "$root/bouncer/scripts/run-local.zsh" ]; then
    echo "ローカルBouncer Gatewayが見つかりません: $root/bouncer" >&2
    exit 2
  fi
  echo "Bouncer統合版 dry-run"
  echo "  workspace: $workspace"
  echo "  agent:     $agent"
  echo "  profile:   $profile"
  echo "  monitor:   enabled"
  if [ "$agent" = "opencode" ]; then
    _session="new"
    _project=""
    for _f in "$extra" "$extra2"; do
      case "$_f" in
        --resume) _session="continue last" ;;
        --project=*) _project="${_f#--project=}" ;;
      esac
    done
    echo "  session:   $_session"
    [ -n "$_project" ] && echo "  project:   $_project"
  fi
  if [ "$profile" = "maximum" ]; then
    echo "  gateway:   http://127.0.0.1:8787 (local only)"
  elif [ "$agent" = "opencode" ] || [ "$agent" = "d-claude" ]; then
    echo "  gateway:   http://127.0.0.1:8788 (send inspection, no local LLM)"
  else
    echo "  gateway:   bypassed (AIの応答速度を優先)"
  fi
  exit 0
fi

monitor_pid=""
gateway_pid=""

cleanup() {
  if [ -n "$gateway_pid" ]; then kill "$gateway_pid" 2>/dev/null || true; fi
  if [ -n "$monitor_pid" ]; then kill "$monitor_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM HUP

AI_SAFE_PROFILE="$profile" AI_SAFE_AGENT="$agent" \
  bash "$hooks/open-monitor.sh" >"$log_dir/integrated-monitor.log" 2>&1 &
monitor_pid=$!

if [ "$profile" = "maximum" ]; then
  bouncer="$root/bouncer"
  [ -x "$bouncer/scripts/run-local.zsh" ] || {
    echo "ローカルBouncer Gatewayが見つかりません: $bouncer" >&2
    exit 2
  }

  echo "ローカルGemmaとBouncer Gatewayを準備しています。"
  BOUNCER_REVIEW_MODE=block \
  BOUNCER_AI_FAILURE_MODE=block \
    zsh "$bouncer/scripts/run-local.zsh" >"$log_dir/bouncer-gateway.log" 2>&1 &
  gateway_pid=$!

  ready=0
  for _i in $(seq 1 180); do
    if curl -fsS --max-time 1 http://127.0.0.1:8787/bouncer/health >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! kill -0 "$gateway_pid" 2>/dev/null; then break; fi
    sleep 1
  done
  if [ "$ready" -ne 1 ]; then
    echo "Bouncer Gatewayを起動できませんでした。" >&2
    echo "確認先: $log_dir/bouncer-gateway.log" >&2
    exit 1
  fi
fi

case "$agent:$profile" in
  codex:standard)
    bash "$hooks/launch-codex-safe.sh" "$workspace"
    ;;
  claude:standard)
    bash "$hooks/launch-claude-safe.sh" "$workspace"
    ;;
  claude:assisted)
    bash "$hooks/launch-claude-safe.sh" --assisted "$workspace"
    ;;
  claude:maximum)
    export BOUNCER_INTEGRATED_MODE=1
    export ANTHROPIC_BASE_URL="http://127.0.0.1:8787"
    bash "$hooks/launch-claude-safe.sh" "$workspace"
    ;;
  opencode:standard)
    bash "$hooks/opencode/launch-opencode-deepseek.sh" "$workspace" "$extra" "$extra2"
    ;;
  d-claude:standard)
    consent="$hooks/launch-deepseek-safe.sh"
    auth_file="$HOME/.deepseek-claude/auth"
    gateway="$hooks/deepseek/launch-deepseek-gateway.sh"
    [ -f "$consent" ] || { echo "DeepSeek同意ゲートが見つかりません: $consent" >&2; exit 2; }
    [ -f "$gateway" ] || { echo "DeepSeek送信検査Gatewayが見つかりません: $gateway" >&2; exit 2; }
    [ -s "$auth_file" ] || {
      echo "DeepSeek APIキーが未登録です。" >&2
      echo "スタート/（上級）1_DeepSeekキーを登録 を先に実行してください。" >&2
      exit 2
    }
    bash "$consent" --consent-only
    export ANTHROPIC_AUTH_TOKEN
    ANTHROPIC_AUTH_TOKEN="$(cat "$auth_file")"
    export ANTHROPIC_MODEL="deepseek-v4-flash[1m]"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-v4-flash[1m]"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-flash[1m]"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"
    export CLAUDE_CODE_SUBAGENT_MODEL="deepseek-v4-flash"
    export CLAUDE_CODE_EFFORT_LEVEL="max"
    bash "$gateway" "$workspace"
    ;;
esac
