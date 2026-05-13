#!/usr/bin/env bash
set -euo pipefail
workspace="${1:-$(pwd)}"
prompt="${2:-}"
workspace="$(cd "$workspace" && pwd)"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"
export CODEX_HOME="$workspace/.codex"

[ -f "$AI_SAFE_POLICY" ] || { echo "AI Safety package is not installed in workspace: $workspace" >&2; exit 2; }
[ -f "$CODEX_HOME/config.toml" ] || { echo "Codex safety config was not found: $CODEX_HOME/config.toml" >&2; exit 2; }

# Bridge user's existing Codex auth into the safe CODEX_HOME so learners do not need to re-login.
# Using a symlink keeps things in sync if the user re-logs in via the normal codex command later.
if [ -f "$HOME/.codex/auth.json" ] && [ ! -e "$CODEX_HOME/auth.json" ]; then
  ln -sf "$HOME/.codex/auth.json" "$CODEX_HOME/auth.json"
fi

cmd=(codex --cd "$workspace" --profile safe --sandbox workspace-write --ask-for-approval untrusted --enable hooks)
if command -v caffeinate >/dev/null 2>&1; then
  cmd=(caffeinate -dimsu "${cmd[@]}")
fi
if [ -n "$prompt" ]; then
  "${cmd[@]}" "$prompt"
else
  "${cmd[@]}"
fi
