#!/bin/bash
# apply-global-guard.sh — この Mac の Claude と Codex の「全体設定」に、危険コマンドのガードを反映する。
#
#   Claude (~/.claude/settings.json):
#     - permissions.deny を union し、さらに guard スクリプトの絶対パスを指す hooks を追加。
#       どのフォルダから claude を起動しても、rm -r / cat .env / curl|sh 等を確実にブロックする。
#   Codex (~/.codex/config.toml + ~/.codex/hooks.json):
#     - approval_policy=on-request / approvals_reviewer=auto_review / sandbox_mode=workspace-write /
#       shell_environment_policy.exclude(APIキー) 等の「決定的な」保護を反映(常時有効)。
#     - guard の絶対パス hooks も配線する(発火には codex の /hooks で一度だけ信頼する操作が要る)。
#
# 既存設定は壊さない(union / 管理キーのみ変更)。反映前に自動バックアップ。取り消しは
# uninstall-global-guard.sh で確実に元へ戻せる。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 配置: <workspace>/.ai-safety/hooks/macos/apply-global-guard.sh
WORKSPACE="$(cd "$HERE/../../.." && pwd)"
GUARD_DIR="$HERE"                                  # guard-*.sh はこのフォルダにある(絶対パス)
COMMON="$HERE/../common"
CLAUDE_JS="$COMMON/apply-global-guard.js"
CODEX_JS="$COMMON/apply-global-codex.js"

SRC="${AI_SAFE_DENY_SRC:-$WORKSPACE/.claude/settings.json}"
CLAUDE_TARGET="${AI_SAFE_GLOBAL_CLAUDE:-$HOME/.claude/settings.json}"
CODEX_CONFIG="${AI_SAFE_GLOBAL_CODEX:-$HOME/.codex/config.toml}"
CODEX_HOOKS="${AI_SAFE_GLOBAL_CODEX_HOOKS:-$HOME/.codex/hooks.json}"
STATE_ARGS=()
[ -n "${AI_SAFE_GLOBAL_STATE:-}" ] && STATE_ARGS=(--state "$AI_SAFE_GLOBAL_STATE")

if ! command -v node >/dev/null 2>&1; then
  echo "エラー: node が見つかりません。Node.js を入れてから実行してください。" >&2
  exit 2
fi
if [ ! -f "$SRC" ]; then
  echo "エラー: deny の元設定が見つかりません: $SRC" >&2
  echo "  → 先に「1_安全パッケージを準備」を実行してください。" >&2
  exit 2
fi
if [ ! -f "$CLAUDE_JS" ] || [ ! -f "$CODEX_JS" ]; then
  echo "エラー: 反映スクリプトが見つかりません($COMMON)。先に「1_安全パッケージを準備」を実行してください。" >&2
  exit 2
fi

rc=0
echo "── Claude 全体設定に反映 ─────────────────────────────"
node "$CLAUDE_JS" apply --source "$SRC" --target "$CLAUDE_TARGET" --os macos --guard-dir "$GUARD_DIR" "${STATE_ARGS[@]}" "$@" || rc=1

echo ""
echo "── Codex 全体設定に反映 ──────────────────────────────"
node "$CODEX_JS" apply --config-target "$CODEX_CONFIG" --hooks-target "$CODEX_HOOKS" --os macos --guard-dir "$GUARD_DIR" "${STATE_ARGS[@]}" "$@" || rc=1
echo "  ※ Codex の guard hook を発火させるには、一度だけ codex を起動して /hooks で信頼してください。"
echo "     常時有効な保護(サンドボックス・承認・APIキー除外)は上の config.toml で決定的に効きます。"

exit $rc
