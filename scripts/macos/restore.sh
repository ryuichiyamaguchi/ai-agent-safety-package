#!/usr/bin/env bash
set -euo pipefail
backup_zip="${1:?backup zip required}"
workspace="${2:-$(pwd)}"
workspace="$(cd "$workspace" && pwd)"
unzip -oq "$backup_zip" -d "$workspace"
echo "Restored to $workspace"
