#!/usr/bin/env bash
set -euo pipefail

# 受講者のシェルに残っていた AI_SAFE_POLICY / AI_SAFE_ROOT で deny 床ごと差し替えられる
# のを防ぐため、起動時に必ず捨てる（このあと同梱ポリシーを自分で設定する）。
# 万一これが漏れても、ガード側(lib/safety_policy.sh / lib/SafetyPolicy.ps1)が同梱パス以外を
# 拒否するので床は残る。ここは二重の保険。
unset AI_SAFE_POLICY AI_SAFE_ROOT
workspace="${1:-$(pwd)}"
prompt="${2:-}"
workspace="$(cd "$workspace" && pwd)"
policy="$workspace/.gemini/policies/safety.toml"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

[ -f "$policy" ] || { echo "Gemini safety policy was not found: $policy" >&2; exit 2; }

if [ -n "$prompt" ]; then
  gemini --approval-mode default --policy "$policy" --include-directories "$workspace" --prompt "$prompt"
else
  gemini --approval-mode default --policy "$policy" --include-directories "$workspace"
fi
