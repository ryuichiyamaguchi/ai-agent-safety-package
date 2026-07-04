#!/bin/bash
# uninstall-global-guard.sh — apply-global-guard.sh で反映した「全体設定」への変更を取り消し、
# 適用前のバックアップから ~/.claude/settings.json と ~/.codex/config.toml / hooks.json を元へ戻す。
# 記録(~/.ai-safety/global-guard-state.json)を辿って復元するので確実に元に戻せる。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$HERE/../../.." && pwd)"
COMMON="$HERE/../common"
CLAUDE_JS="$COMMON/apply-global-guard.js"
CODEX_JS="$COMMON/apply-global-codex.js"

CLAUDE_TARGET="${AI_SAFE_GLOBAL_CLAUDE:-$HOME/.claude/settings.json}"
CODEX_CONFIG="${AI_SAFE_GLOBAL_CODEX:-$HOME/.codex/config.toml}"
CODEX_HOOKS="${AI_SAFE_GLOBAL_CODEX_HOOKS:-$HOME/.codex/hooks.json}"
STATE_ARGS=()
[ -n "${AI_SAFE_GLOBAL_STATE:-}" ] && STATE_ARGS=(--state "$AI_SAFE_GLOBAL_STATE")

if ! command -v node >/dev/null 2>&1; then
  echo "エラー: node が見つかりません。Node.js を入れてから実行してください。" >&2
  exit 2
fi
if [ ! -f "$CLAUDE_JS" ] || [ ! -f "$CODEX_JS" ]; then
  echo "エラー: 取り消しスクリプトが見つかりません($COMMON)。" >&2
  exit 2
fi

rc=0
echo "── Claude 全体設定を元に戻す ─────────────────────────"
node "$CLAUDE_JS" uninstall --target "$CLAUDE_TARGET" "${STATE_ARGS[@]}" "$@" || rc=1

echo ""
echo "── Codex 全体設定を元に戻す ──────────────────────────"
node "$CODEX_JS" uninstall --config-target "$CODEX_CONFIG" --hooks-target "$CODEX_HOOKS" "${STATE_ARGS[@]}" "$@" || rc=1

exit $rc
