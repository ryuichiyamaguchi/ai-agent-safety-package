#!/usr/bin/env bash
set -euo pipefail
# M13: Claude Code の approval 制御は CLI フラグでは渡せない（Codex の
# --ask-for-approval untrusted に相当する仕組みは settings.json 側にある）。
# 本パッケージは configs/claude/settings.mac.json の permissions / hooks 経由で
# 同等の効果（PreToolUse hook による fail-closed 判定 + 危険コマンド deny）を出している。
# 追加の保険として --permission-mode default を渡し、Claude Code 側のデフォルト
# 承認モードを明示する。古い CLI でフラグ非対応の場合はフォールバックする。
workspace="${1:-$(pwd)}"
prompt="${2:-}"
workspace="$(cd "$workspace" && pwd)"
settings="$workspace/.claude/settings.json"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

[ -f "$settings" ] || { echo "Claude safety settings were not found: $settings" >&2; exit 2; }
[ -f "$AI_SAFE_POLICY" ] || { echo "AI Safety package is not installed in workspace: $workspace" >&2; exit 2; }

# --permission-mode の対応有無を help で判定（非対応の Claude Code でも壊れないように）
claude_args=(--settings "$settings" --setting-sources user,project,local)
if claude --help 2>&1 | grep -q -- "--permission-mode"; then
  claude_args=(--permission-mode default "${claude_args[@]}")
fi

if [ -n "$prompt" ]; then
  claude "${claude_args[@]}" "$prompt"
else
  claude "${claude_args[@]}"
fi
