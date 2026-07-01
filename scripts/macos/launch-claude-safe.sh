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

# d-claude（DeepSeek 駆動）のときだけ、正直さ・身元の上書き指示を system prompt に追記する。
# DeepSeek は Claude Code の「あなたは Claude」プロンプトを受け取って Anthropic を装い、
# できないことを「できる」・やっていないことを「やった」と過剰申告する傾向がある。
# --append-system-prompt で「実際は DeepSeek」「嘘・捏造をしない」を注入して是正する。
# フラグ非対応の古い CLI では skip（起動を壊さない）。素の claude-safe には影響しない。
if [ "${DS_CLAUDE_MODE:-}" = "1" ]; then
  _honesty="$(cd "$(dirname "$0")" && pwd)/../common/deepseek-honesty-prompt.txt"
  if [ -f "$_honesty" ] && claude --help 2>&1 | grep -q -- "--append-system-prompt"; then
    claude_args+=(--append-system-prompt "$(cat "$_honesty")")
  fi

  # d-claude に web 検索を与える（Gemini grounding の MCP ツール `web_search`）。標準 WebSearch は
  # Anthropic サーバー側実装で DeepSeek バックエンドでは動かないため、検索のみの自前 MCP を追加する。
  # 既存の Gemini キー(~/.ai-safety/gemini-api-key.txt)を使い回すので受講者は新規アカウント不要。
  # d-claude 限定（DS_CLAUDE_MODE 下）で --mcp-config 追加。無効化は AI_SAFE_DCLAUDE_SEARCH=0。
  # JSON はパスのエスケープ事故を避けるため node で書き出す（d-claude 経路では node 必須）。
  _search_mcp="$(cd "$(dirname "$0")" && pwd)/../common/gemini-search-mcp.js"
  if [ "${AI_SAFE_DCLAUDE_SEARCH:-1}" = "1" ] && [ -f "$_search_mcp" ] \
     && command -v node >/dev/null 2>&1 && claude --help 2>&1 | grep -q -- "--mcp-config"; then
    _mcp_cfg="$AI_SAFE_LOG_DIR/d-claude-mcp.json"
    mkdir -p "$AI_SAFE_LOG_DIR" 2>/dev/null || true
    if node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({mcpServers:{"gemini-search":{command:"node",args:[process.argv[2]]}}}))' "$_mcp_cfg" "$_search_mcp" 2>/dev/null; then
      claude_args+=(--mcp-config "$_mcp_cfg")
    fi
  fi
fi

if [ -n "$prompt" ]; then
  claude "${claude_args[@]}" "$prompt"
else
  claude "${claude_args[@]}"
fi
