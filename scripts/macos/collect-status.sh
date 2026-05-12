#!/usr/bin/env bash
set -euo pipefail
workspace="${1:-$(pwd)}"
out_dir="${2:-$HOME/.ai-safety/status}"
workspace="$(cd "$workspace" && pwd)"
mkdir -p "$out_dir"
out="$out_dir/status-${USER:-user}-$(date +%Y%m%d-%H%M%S).txt"
{
  echo "timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "user=${USER:-unknown}"
  echo "host=$(hostname)"
  echo "workspace=$workspace"
  for cmd in codex claude gemini; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "$cmd=$($cmd --version 2>/dev/null || true)"
    else
      echo "$cmd=missing"
    fi
  done
  for p in .ai-safety/policy/safety-policy.json .claude/settings.json .codex/config.toml .codex/hooks.json .gemini/settings.json; do
    if [ -e "$workspace/$p" ]; then echo "$p=true"; else echo "$p=false"; fi
  done
  echo "logDir=$HOME/.ai-safety/logs"
} > "$out"
echo "$out"
