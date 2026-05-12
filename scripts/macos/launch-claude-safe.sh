#!/usr/bin/env bash
set -euo pipefail
workspace="${1:-$(pwd)}"
prompt="${2:-}"
workspace="$(cd "$workspace" && pwd)"
settings="$workspace/.claude/settings.json"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

[ -f "$settings" ] || { echo "Claude safety settings were not found: $settings" >&2; exit 2; }
[ -f "$AI_SAFE_POLICY" ] || { echo "AI Safety package is not installed in workspace: $workspace" >&2; exit 2; }

if [ -n "$prompt" ]; then
  claude --settings "$settings" --setting-sources user,project,local "$prompt"
else
  claude --settings "$settings" --setting-sources user,project,local
fi
