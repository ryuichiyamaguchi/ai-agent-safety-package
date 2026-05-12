#!/usr/bin/env bash
set -euo pipefail
workspace="${1:-$(pwd)}"
workspace="$(cd "$workspace" && pwd)"
"$(dirname "$0")/backup.sh" "$workspace" >/dev/null
"$(dirname "$0")/install.sh" "$workspace" >/dev/null
echo "Updated AI Safety package."
"$(dirname "$0")/doctor.sh" "$workspace"
