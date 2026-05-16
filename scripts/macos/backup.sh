#!/usr/bin/env bash
set -euo pipefail
workspace="${1:-$(pwd)}"
out_dir="${2:-$HOME/.ai-safety/backups}"
workspace="$(cd "$workspace" && pwd)"
mkdir -p "$out_dir"
zip_path="$out_dir/ai-safety-backup-$(date +%Y%m%d-%H%M%S).zip"
cd "$workspace"
zip -qr "$zip_path" .ai-safety .claude .codex .gemini .aiexclude 2>/dev/null || true
# H7: emit companion .sha256 so restore.sh can verify integrity before extracting.
if [ -f "$zip_path" ]; then
  shasum -a 256 "$zip_path" | awk '{print $1}' > "${zip_path}.sha256"
fi
echo "$zip_path"
