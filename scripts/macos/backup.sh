#!/usr/bin/env bash
set -euo pipefail
workspace="${1:-$(pwd)}"
out_dir="${2:-$HOME/.ai-safety/backups}"
workspace="$(cd "$workspace" && pwd)"
mkdir -p "$out_dir"
zip_path="$out_dir/ai-safety-backup-$(date +%Y%m%d-%H%M%S).zip"
cd "$workspace"
zip -qr "$zip_path" .ai-safety .claude .codex .gemini .aiexclude 2>/dev/null || true
echo "$zip_path"
