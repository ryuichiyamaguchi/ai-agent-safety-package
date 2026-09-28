#!/bin/bash
# uninstall-global-guard.sh — apply-global-guard.sh で入れた「全体設定」への変更を取り消し、
# 適用前のバックアップから元へ戻す。対象は 4 エンジン:
#   Claude Code (~/.claude/settings.json)
#   Codex       (~/.codex/config.toml, ~/.codex/hooks.json)
#   agy/Gemini  (~/.gemini/settings.json)
#   OpenCode    (~/.config/opencode/opencode.json | .jsonc)
# 記録(~/.ai-safety/global-guard-state.json)を辿って「入れた分だけ」を正確に戻すので、
# 入れていないエンジンには触らない。
#
# 解除したことは ~/.ai-safety/global-guard-optout に記録する。PC 全体の安全設定は
# 安全パッケージの導入・更新のたびに自動で入る（v1.19.x〜）が、この記録があるあいだは
# 入れ直さない。もう一度入れたいときは「キーと金庫/12_PC全体に安全設定を入れる」を押す
# （12 がこの記録を消す）。
# 安全ガードの本体（~/.ai-safety/global/）は消さずに残す。バックアップが見つからず
# 元に戻せなかった設定が万一 hook を残していても、その hook が「本体が無い」で
# 止まらないようにするため（中身は古いまま使われなくなるだけ）。
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
OPTOUT_MARKER="$HOME/.ai-safety/global-guard-optout"
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

# 解除の意思を先に記録する（途中で失敗しても、次の更新で勝手に入れ直さないように）。
_dry=0
for _a in "$@"; do [ "$_a" = "--dry-run" ] && _dry=1; done
if [ "$_dry" -eq 0 ]; then
  mkdir -p "$(dirname "$OPTOUT_MARKER")" 2>/dev/null || true
  {
    echo "PC 全体の安全設定は、利用者の操作（キーと金庫/13_PC全体の安全設定を解除）で解除されています。"
    echo "このファイルがあるあいだ、安全パッケージの導入・更新で PC 全体の安全設定を入れ直しません。"
    echo "もう一度入れるときは「キーと金庫/12_PC全体に安全設定を入れる」を実行してください（このファイルは自動で消えます）。"
    echo "解除した日時: $(date '+%Y-%m-%d %H:%M:%S')"
  } > "$OPTOUT_MARKER" 2>/dev/null || echo "注意: 解除した記録を書けませんでした: ${OPTOUT_MARKER}" >&2
fi

rc=0
echo "── 1) Claude Code の全体設定を元に戻す ───────────────"
node "$CLAUDE_JS" uninstall --target "$CLAUDE_TARGET" ${STATE_ARGS[@]+"${STATE_ARGS[@]}"} "$@" || rc=1

echo ""
echo "── 2) Codex の全体設定を元に戻す ─────────────────────"
node "$CODEX_JS" uninstall --config-target "$CODEX_CONFIG" --hooks-target "$CODEX_HOOKS" ${STATE_ARGS[@]+"${STATE_ARGS[@]}"} "$@" || rc=1

echo ""
echo "── 3) agy / Gemini の全体設定を元に戻す ──────────────"
node "$AGY_JS" uninstall --target "$AGY_TARGET" ${STATE_ARGS[@]+"${STATE_ARGS[@]}"} "$@" || rc=1

echo ""
echo "── 4) OpenCode の全体設定を元に戻す ──────────────────"
node "$OPENCODE_JS" uninstall --config-dir "$OPENCODE_DIR" ${STATE_ARGS[@]+"${STATE_ARGS[@]}"} "$@" || rc=1

if [ "$_dry" -eq 0 ]; then
  echo ""
  echo "これからは、安全パッケージを更新しても PC 全体の安全設定は自動で入れ直しません。"
  echo "もう一度入れたいときは「キーと金庫/12_PC全体に安全設定を入れる」を実行してください。"
fi

exit $rc
