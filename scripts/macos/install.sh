#!/usr/bin/env bash
set -euo pipefail
workspace="${1:-$(pwd)}"
install_global_claude="${2:-}"
workspace="$(cd "$workspace" && pwd)"
package_root="$(cd "$(dirname "$0")/../.." && pwd)"
stamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$HOME/.ai-safety/backups/$stamp"
mkdir -p "$backup_dir" "$workspace/.ai-safety/hooks" "$workspace/.ai-safety/policy"

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
cp -R "$package_root/scripts/windows" "$workspace/.ai-safety/hooks/"
cp -R "$package_root/scripts/macos" "$workspace/.ai-safety/hooks/"
chmod +x "$workspace/.ai-safety/hooks/macos/"*.sh "$workspace/.ai-safety/hooks/macos/lib/"*.sh

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
