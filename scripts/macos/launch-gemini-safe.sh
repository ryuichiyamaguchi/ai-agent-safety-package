#!/usr/bin/env bash
set -euo pipefail
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
