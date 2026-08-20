#!/bin/bash
# uninstall-global-guard.sh — apply-global-guard.sh で入れた「全体設定」への変更を取り消し、
# 適用前のバックアップから元へ戻す。対象は 4 エンジン:
#   Claude Code (~/.claude/settings.json)
#   Codex       (~/.codex/config.toml, ~/.codex/hooks.json)
#   agy/Gemini  (~/.gemini/settings.json)
#   OpenCode    (~/.config/opencode/opencode.json | .jsonc)
# 記録(~/.ai-safety/global-guard-state.json)を辿って「入れた分だけ」を正確に戻すので、
# 入れていないエンジンには触らない。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/../../.." && pwd)"
COMMON="$HERE/../common"
CLAUDE_JS="$COMMON/apply-global-guard.js"
CODEX_JS="$COMMON/apply-global-codex.js"
AGY_JS="$COMMON/apply-global-agy.js"
OPENCODE_JS="$COMMON/apply-global-opencode.js"

CLAUDE_TARGET="${AI_SAFE_GLOBAL_CLAUDE:-$HOME/.claude/settings.json}"
CODEX_CONFIG="${AI_SAFE_GLOBAL_CODEX:-$HOME/.codex/config.toml}"
CODEX_HOOKS="${AI_SAFE_GLOBAL_CODEX_HOOKS:-$HOME/.codex/hooks.json}"
AGY_TARGET="${AI_SAFE_GLOBAL_AGY:-$HOME/.gemini/settings.json}"
OPENCODE_DIR="${AI_SAFE_GLOBAL_OPENCODE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
STATE_ARGS=()
[ -n "${AI_SAFE_GLOBAL_STATE:-}" ] && STATE_ARGS=(--state "$AI_SAFE_GLOBAL_STATE")

if ! command -v node >/dev/null 2>&1; then
  echo "エラー: node が見つかりません。Node.js を入れてから実行してください。" >&2
  exit 2
fi
for _js in "$CLAUDE_JS" "$CODEX_JS" "$AGY_JS" "$OPENCODE_JS"; do
  if [ ! -f "$_js" ]; then
    echo "エラー: 取り消しスクリプトが見つかりません: $_js" >&2
    exit 2
  fi
done

rc=0
echo "── 1) Claude Code の全体設定を元に戻す ───────────────"
node "$CLAUDE_JS" uninstall --target "$CLAUDE_TARGET" "${STATE_ARGS[@]}" "$@" || rc=1

echo ""
echo "── 2) Codex の全体設定を元に戻す ─────────────────────"
node "$CODEX_JS" uninstall --config-target "$CODEX_CONFIG" --hooks-target "$CODEX_HOOKS" "${STATE_ARGS[@]}" "$@" || rc=1

echo ""
echo "── 3) agy / Gemini の全体設定を元に戻す ──────────────"
node "$AGY_JS" uninstall --target "$AGY_TARGET" "${STATE_ARGS[@]}" "$@" || rc=1

echo ""
echo "── 4) OpenCode の全体設定を元に戻す ──────────────────"
node "$OPENCODE_JS" uninstall --config-dir "$OPENCODE_DIR" "${STATE_ARGS[@]}" "$@" || rc=1

exit $rc
