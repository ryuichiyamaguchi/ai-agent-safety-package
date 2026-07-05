#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [--platform mac|win|both] [--global-claude] [workspace]
  --platform: install hooks for which OS (default: mac)
              "both" installs both mac and win hooks (win hooks become read-only)
  --global-claude: also install Claude settings to \$HOME/.claude/
  workspace: target workspace directory (default: \$HOME/Documents/my-ai-workspace)
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

package_root="$(cd "$(dirname "$0")/../.." && pwd)"

# B-3: workspace 未指定時は安全なデフォルト ($HOME/Documents/my-ai-workspace) を使用。
# CWD がパッケージフォルダ自身の場合も同様に安全デフォルトへ。
if [ -z "$workspace" ]; then
  workspace="$HOME/Documents/my-ai-workspace"
  echo "INFO: workspace not specified. Using default: $workspace"
fi

# 相対パスを絶対パスに変換（mkdir -p 後に cd で正規化）
# B-2: 親ディレクトリが存在しなくても mkdir -p で自動作成。
mkdir -p "$workspace"
workspace="$(cd "$workspace" && pwd)"

# B-3: ZIP 展開フォルダ自身を workspace に指定した場合は安全停止。
if [ "$workspace" = "$package_root" ]; then
  echo "エラー: workspace にパッケージフォルダ自身を指定しないでください。" >&2
  echo "例: bash scripts/macos/install.sh \$HOME/Documents/my-ai-workspace" >&2
  exit 1
fi

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
    verify_hash "configs/codex/safe.config.toml"
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
    verify_hash "configs/codex/safe.config.toml"
    verify_hash "configs/codex/config.windows.toml"
    ;;
esac
verify_hash "configs/gemini/policies/safety.toml"
verify_hash "workspace-template/aiexclude.template"
verify_hash "workspace-template/dist-skills/hearing-ladder/SKILL.md"

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

# DeepSeek 送信検査 Gateway（クロスプラットフォーム・Node 実装）を配置
cp -R "$package_root/scripts/common" "$workspace/.ai-safety/hooks/"

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
copy_with_backup "$package_root/configs/codex/safe.config.toml" "$workspace/.codex/safe.config.toml"
copy_with_backup "$package_root/configs/codex/hooks.mac.json" "$workspace/.codex/hooks.json"
copy_with_backup "$package_root/configs/gemini/settings.mac.json" "$workspace/.gemini/settings.json"
copy_with_backup "$package_root/configs/gemini/policies/safety.toml" "$workspace/.gemini/policies/safety.toml"
copy_with_backup "$package_root/workspace-template/aiexclude.template" "$workspace/.aiexclude"

# 配布スキルを workspace の .claude/skills/ に配置。d-claude / claude が起動時に
# ${workspace}/.claude/skills 配下を読み込むので、ここに置けば受講者もそのまま使える。
# リポジトリ側は dist-skills/ に置く（.gitignore が .claude/ を除外するため）。
# スキル単位で処理: 同名の既存スキル（ユーザーが手を入れた版も含む）は backup へ退避してから
# ディレクトリごと入れ替える（copy_with_backup と同じ思想＝上書き前に必ず控えを取る／古い
# support ファイルが残らない）。同梱していない他スキルには触れない。
if [ -d "$package_root/workspace-template/dist-skills" ]; then
  mkdir -p "$workspace/.claude/skills"
  for skill_src in "$package_root/workspace-template/dist-skills"/*/; do
    [ -d "$skill_src" ] || continue
    skill_name="$(basename "$skill_src")"
    skill_dest="$workspace/.claude/skills/$skill_name"
    if [ -e "$skill_dest" ]; then
      safe_name="$(printf '%s' "$skill_dest" | sed 's#[/:]#_#g')"
      cp -R "$skill_dest" "$backup_dir/$safe_name"
      rm -rf "$skill_dest"
    fi
    cp -R "$skill_src" "$skill_dest"
  done
  echo "配布スキルを配置しました: $workspace/.claude/skills"
fi

# 受講者向けスタートフォルダ（番号ラッパー + 案内 HTML）を workspace に配置。
# ファイルシステム構造とは別に「ここを見てポチポチやれば使える」入口を用意する。
if [ -d "$package_root/workspace-template/スタート" ]; then
  mkdir -p "$workspace/スタート"
  cp -R "$package_root/workspace-template/スタート/." "$workspace/スタート/"
  if [ -f "$package_root/スタート.html" ]; then
    cp "$package_root/スタート.html" "$workspace/スタート/スタート.html"
  fi
  # 受講者が同名ファイル（.command と .bat）で迷わないよう、当該 OS 用だけ残す。
  if [[ "$PLATFORM" == "mac" ]]; then
    rm -f "$workspace/スタート/"*.bat
  elif [[ "$PLATFORM" == "win" ]]; then
    rm -f "$workspace/スタート/"*.command
  fi
  chmod +x "$workspace/スタート/"*.command 2>/dev/null || true
  echo "スタートフォルダを配置しました: $workspace/スタート"
fi

if [ "$install_global_claude" = "--global-claude" ]; then
  global_target="$HOME/.claude/settings.json"
  global_src="$package_root/configs/claude/settings.mac.json"
  deny_js="$package_root/scripts/common/apply-global-deny.js"
  # A案 (2026-07): settings を丸ごとコピーせず、permissions.deny だけを union マージする。
  # 丸ごとコピーは hook が ${CLAUDE_PROJECT_DIR}/.ai-safety を探し、そのフォルダが無い場所で
  # 全 Bash が exit2 ブロックになる落とし穴があったため廃止。既存の hooks/env/allow/ask は不変。
  if command -v node >/dev/null 2>&1; then
    echo "Merging package deny rules into global ~/.claude/settings.json (既存の hooks/env は不変)..."
    node "$deny_js" "$global_src" "$global_target" || echo "global deny merge failed (skipped)." >&2
  else
    echo "node not found; skipped global Claude deny merge (Node.js が必要です)." >&2
  fi
fi

echo "AI Safety package installed."
echo "Workspace: $workspace"
echo "Backups: $backup_dir"
echo "Next: .ai-safety/hooks/macos/doctor.sh"
