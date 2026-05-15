#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [--platform mac|win|both] [--global-claude] [workspace]
  --platform: install hooks for which OS (default: mac)
              "both" installs both mac and win hooks (win hooks become read-only)
  --global-claude: also install Claude settings to \$HOME/.claude/
  workspace: target workspace directory (default: current directory)
EOF
}

PLATFORM="mac"
workspace=""
install_global_claude=""

# Argument parsing: keep backward compatibility with positional
# "workspace" and legacy "--global-claude" / "$2" form.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      PLATFORM="${2:-}"
      shift 2
      ;;
    --platform=*)
      PLATFORM="${1#*=}"
      shift
      ;;
    --global-claude)
      install_global_claude="--global-claude"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [ -z "$workspace" ]; then
        workspace="$1"
      elif [ -z "$install_global_claude" ]; then
        install_global_claude="$1"
      fi
      shift
      ;;
  esac
done

case "$PLATFORM" in
  mac|win|both) ;;
  *) echo "Error: --platform must be mac, win, or both" >&2; exit 1 ;;
esac

workspace="${workspace:-$(pwd)}"
workspace="$(cd "$workspace" && pwd)"
package_root="$(cd "$(dirname "$0")/../.." && pwd)"
stamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$HOME/.ai-safety/backups/$stamp"
mkdir -p "$backup_dir" "$workspace/.ai-safety/hooks" "$workspace/.ai-safety/policy"

echo "Installing for platform: $PLATFORM"

copy_with_backup() {
  src="$1"
  dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ]; then
    safe_name="$(printf '%s' "$dest" | sed 's#[/:]#_#g')"
    cp -R "$dest" "$backup_dir/$safe_name"
  fi
  cp -R "$src" "$dest"
}

cp "$package_root/policy/safety-policy.json" "$workspace/.ai-safety/policy/safety-policy.json"

if [[ "$PLATFORM" == "mac" || "$PLATFORM" == "both" ]]; then
  cp -R "$package_root/scripts/macos" "$workspace/.ai-safety/hooks/"
  chmod +x "$workspace/.ai-safety/hooks/macos/"*.sh "$workspace/.ai-safety/hooks/macos/lib/"*.sh
fi

if [[ "$PLATFORM" == "win" || "$PLATFORM" == "both" ]]; then
  cp -R "$package_root/scripts/windows" "$workspace/.ai-safety/hooks/"
  # Foreign-OS hooks become read-only to shrink attack surface (H3).
  find "$workspace/.ai-safety/hooks/windows" -type f -exec chmod 600 {} \;
fi

# Remove stale foreign-OS hook directories when single-platform install
# is requested (defensive cleanup on re-install).
if [[ "$PLATFORM" == "mac" ]] && [ -d "$workspace/.ai-safety/hooks/windows" ]; then
  rm -rf "$workspace/.ai-safety/hooks/windows"
fi
if [[ "$PLATFORM" == "win" ]] && [ -d "$workspace/.ai-safety/hooks/macos" ]; then
  rm -rf "$workspace/.ai-safety/hooks/macos"
fi

copy_with_backup "$package_root/configs/claude/settings.mac.json" "$workspace/.claude/settings.json"
copy_with_backup "$package_root/configs/codex/config.mac.toml" "$workspace/.codex/config.toml"
copy_with_backup "$package_root/configs/codex/hooks.mac.json" "$workspace/.codex/hooks.json"
copy_with_backup "$package_root/configs/gemini/settings.mac.json" "$workspace/.gemini/settings.json"
copy_with_backup "$package_root/configs/gemini/policies/safety.toml" "$workspace/.gemini/policies/safety.toml"
copy_with_backup "$package_root/workspace-template/aiexclude.template" "$workspace/.aiexclude"

if [ "$install_global_claude" = "--global-claude" ]; then
  copy_with_backup "$package_root/configs/claude/settings.mac.json" "$HOME/.claude/settings.json"
fi

echo "AI Safety package installed."
echo "Workspace: $workspace"
echo "Backups: $backup_dir"
echo "Next: .ai-safety/hooks/macos/doctor.sh"
