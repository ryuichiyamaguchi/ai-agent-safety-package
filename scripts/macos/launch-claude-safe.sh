#!/usr/bin/env bash
set -euo pipefail
# M13: Claude Code の approval 制御は CLI フラグでは渡せない（Codex の
# --ask-for-approval untrusted に相当する仕組みは settings.json 側にある）。
# 本パッケージは configs/claude/settings.mac.json の permissions / hooks 経由で
# 同等の効果（PreToolUse hook による fail-closed 判定 + 危険コマンド deny）を出している。
# 追加の保険として --permission-mode default を渡し、Claude Code 側のデフォルト
# 承認モードを明示する。古い CLI でフラグ非対応の場合はフォールバックする。
# --assisted opt-in: 2 鍵グレーゾーン自動承認を有効化（既定 OFF）。フラグを引数列から
# 取り除いてから従来の位置引数（workspace / prompt）を解釈する。事前に環境変数
# AI_SAFE_ASSISTED_APPROVAL=1 が立っている場合もそのまま尊重して引き継ぐ。
_args=()
for _a in "$@"; do
  if [ "$_a" = "--assisted" ]; then
    export AI_SAFE_ASSISTED_APPROVAL=1
  else
    _args+=("$_a")
  fi
done
# bash 3.2 + set -u では空配列展開が unbound になるため要素数で分岐する。
if [ "${#_args[@]}" -gt 0 ]; then set -- "${_args[@]}"; else set --; fi

workspace="${1:-$(pwd)}"
prompt="${2:-}"
workspace="$(cd "$workspace" && pwd)"
settings="$workspace/.claude/settings.json"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

# claude-safe は「普通の Claude（ログイン認証）」を起動する。DeepSeek 連携が残した
# ルーティング系 env を引き継ぐと無効トークンで 401 になりうるため、このシェル内で外す。
# ただし d-claude（DeepSeek 駆動）は gateway 経由でこのスクリプトを呼び、DeepSeek キー
# (ANTHROPIC_AUTH_TOKEN) と Gateway の BASE_URL/MODEL を「使う」ために渡してくる。
# その経路では gateway が DS_CLAUDE_MODE=1 を立てるので unset をスキップする
# （ここで消すと DeepSeek に繋がらず claude が "not logged in" になる）。
if [ "${DS_CLAUDE_MODE:-}" != "1" ]; then
  unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_CUSTOM_MODEL_OPTION
fi

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
