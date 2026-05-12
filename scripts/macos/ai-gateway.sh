#!/usr/bin/env bash
set -euo pipefail
engine="${1:-codex}"
workspace="${2:-$(pwd)}"
prompt="${3:-}"
workspace="$(cd "$workspace" && pwd)"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

if [ -n "$prompt" ]; then
  guard="$workspace/.ai-safety/hooks/macos/guard-prompt.sh"
  [ -x "$guard" ] || { echo "Prompt guard is missing: $guard" >&2; exit 2; }
  printf '{"hook_event_name":"GatewayPrompt","cwd":"%s","prompt":"%s"}' "$workspace" "$(printf '%s' "$prompt" | sed 's/"/\\"/g')" | "$guard"
fi

case "$engine" in
  codex)  "$(dirname "$0")/launch-codex-safe.sh" "$workspace" "$prompt" ;;
  claude) "$(dirname "$0")/launch-claude-safe.sh" "$workspace" "$prompt" ;;
  gemini) "$(dirname "$0")/launch-gemini-safe.sh" "$workspace" "$prompt" ;;
  *) echo "unknown engine: $engine" >&2; exit 2 ;;
esac
