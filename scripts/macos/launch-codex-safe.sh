#!/usr/bin/env bash
set -euo pipefail
workspace="${1:-$(pwd)}"
prompt="${2:-}"
workspace="$(cd "$workspace" && pwd)"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

[ -f "$AI_SAFE_POLICY" ] || { echo "AI Safety package is not installed in workspace: $workspace" >&2; exit 2; }

cmd=(codex --cd "$workspace" --profile safe --sandbox workspace-write --ask-for-approval never --enable hooks)
if command -v caffeinate >/dev/null 2>&1; then
  cmd=(caffeinate -dimsu "${cmd[@]}")
fi
if [ -n "$prompt" ]; then
  "${cmd[@]}" "$prompt"
else
  "${cmd[@]}"
fi
