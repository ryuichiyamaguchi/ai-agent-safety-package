#!/usr/bin/env bash
set -euo pipefail
backup_zip="${1:?backup zip required}"
workspace="${2:-$(pwd)}"
workspace="$(cd "$workspace" && pwd)"

# H7 Step 1: integrity check against companion .sha256 file (created by backup.sh).
# Missing .sha256 is tolerated for legacy backups (warn only).
if [ -f "${backup_zip}.sha256" ]; then
  expected="$(awk '{print $1}' "${backup_zip}.sha256" | tr -d '\r\n[:space:]')"
  actual="$(shasum -a 256 "$backup_zip" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "ERROR: backup zip SHA-256 mismatch" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
else
  echo "Warning: no companion .sha256 for $backup_zip (legacy backup?)" >&2
fi

# H7 Step 2: zip-slip detection. Reject entries with .. path traversal or absolute paths.
if unzip -l "$backup_zip" | awk 'NR>3 {print $4}' | grep -E '(^|/)\.\.(/|$)|^/' >/dev/null; then
  echo "ERROR: backup zip contains path traversal or absolute-path entries" >&2
  exit 1
fi

# H7 Step 3: extract only after validation.
unzip -oq "$backup_zip" -d "$workspace"
echo "Restored to $workspace"
