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
mkdir -p "$backup_dir" "$workspace/.ai-safety/hooks" "$workspace/.ai-safety/policy" "$workspace/.ai-safety/cards"

echo "Installing for platform: $PLATFORM"

# H6: verify distribution integrity against docs/tested_versions.md hash table.
# Mismatch warns and asks for confirmation (does not hard-fail, since instructors
# may customize policy.json on purpose).
verify_hash() {
  rel_path="$1"
  abs_path="$package_root/$rel_path"
  [ -f "$abs_path" ] || return 0
  versions_file="$package_root/docs/tested_versions.md"
  [ -f "$versions_file" ] || return 0
  # Look up "| <rel_path> | <sha> |" rows in tested_versions.md.
  expected="$(grep -F "| $rel_path |" "$versions_file" 2>/dev/null | head -n1 | awk -F'|' '{gsub(/ /,"",$3); print $3}')"
  [ -n "$expected" ] || return 0
  actual="$(shasum -a 256 "$abs_path" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "Warning: SHA-256 mismatch for $rel_path" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    if [ -t 0 ]; then
      printf "Continue anyway? [y/N] " >&2
      read -r yn
      case "$yn" in
        y|Y) : ;;
        *) echo "Aborted by user." >&2; exit 1 ;;
      esac
    else
      echo "Non-interactive shell: continuing with mismatch (set AI_SAFETY_STRICT=1 to abort)." >&2
      if [ "${AI_SAFETY_STRICT:-0}" = "1" ]; then exit 1; fi
    fi
  fi
}

verify_hash "policy/safety-policy.json"
case "$PLATFORM" in
  mac)
    verify_hash "configs/codex/hooks.mac.json"
    verify_hash "configs/claude/settings.mac.json"
    verify_hash "configs/gemini/settings.mac.json"
    verify_hash "configs/codex/config.mac.toml"
    ;;
  win)
    verify_hash "configs/codex/hooks.windows.json"
    verify_hash "configs/claude/settings.windows.json"
    verify_hash "configs/gemini/settings.windows.json"
    verify_hash "configs/codex/config.windows.toml"
    ;;
  both)
    verify_hash "configs/codex/hooks.mac.json"
    verify_hash "configs/codex/hooks.windows.json"
    verify_hash "configs/claude/settings.mac.json"
    verify_hash "configs/claude/settings.windows.json"
    verify_hash "configs/gemini/settings.mac.json"
    verify_hash "configs/gemini/settings.windows.json"
    verify_hash "configs/codex/config.mac.toml"
    verify_hash "configs/codex/config.windows.toml"
    ;;
esac
verify_hash "configs/gemini/policies/safety.toml"
verify_hash "workspace-template/aiexclude.template"

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

# agent-monitor 解説カード一式を .ai-safety/cards/ に配置する。
if [ -d "$package_root/configs/safety/cards" ]; then
  rm -rf "$workspace/.ai-safety/cards"
  cp -R "$package_root/configs/safety/cards" "$workspace/.ai-safety/cards"
fi

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
  global_target="$HOME/.claude/settings.json"
  global_src="$package_root/configs/claude/settings.mac.json"
  # M16: 既存の global Claude 設定は他プロジェクトでも使われている可能性が高い。
  # バックアップは取るが、上書き前に必ず diff を見せて y/n 確認する。
  if [ -f "$global_target" ]; then
    if cmp -s "$global_target" "$global_src"; then
      echo "Global Claude settings.json already matches package version; skipping."
    else
      echo "Existing global Claude settings found: $global_target"
      echo "----- diff (current -> package) -----"
      diff -u "$global_target" "$global_src" || true
      echo "-------------------------------------"
      if [ -t 0 ]; then
        printf "Overwrite global ~/.claude/settings.json? [y/N] "
        read -r yn
        case "$yn" in
          y|Y) copy_with_backup "$global_src" "$global_target" ;;
          *)   echo "Skipped global Claude settings install." ;;
        esac
      else
        echo "Non-interactive shell: skipped global Claude settings install (set AI_SAFETY_STRICT=1 to force overwrite)." >&2
        if [ "${AI_SAFETY_STRICT:-0}" = "1" ]; then
          copy_with_backup "$global_src" "$global_target"
        fi
      fi
    fi
  else
    copy_with_backup "$global_src" "$global_target"
  fi
fi

echo "AI Safety package installed."
echo "Workspace: $workspace"
echo "Backups: $backup_dir"
echo "Next: .ai-safety/hooks/macos/doctor.sh"
