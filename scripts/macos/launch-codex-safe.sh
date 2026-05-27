#!/usr/bin/env bash
set -euo pipefail
workspace="${1:-$(pwd)}"
prompt="${2:-}"
workspace="$(cd "$workspace" && pwd)"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

# A-1: CODEX_HOME は workspace 外 ($HOME/.codex-safe) を向かせる。
# auth.json を workspace ツリーに物理コピーしないことで
# git add / クラウド同期 / workspace zip 化による平文流出を防ぐ。
SAFE_CODEX_HOME="$HOME/.codex-safe"
mkdir -p "$SAFE_CODEX_HOME"
export CODEX_HOME="$SAFE_CODEX_HOME"

# workspace 内 .codex/config.toml が存在すれば .codex-safe/ へコピーして使う。
# auth.json は絶対にコピーしない。
WORKSPACE_CONFIG="$workspace/.codex/config.toml"
SAFE_CONFIG="$SAFE_CODEX_HOME/config.toml"
if [ -f "$WORKSPACE_CONFIG" ] && [ ! -f "$SAFE_CONFIG" ]; then
  cp "$WORKSPACE_CONFIG" "$SAFE_CONFIG"
fi

[ -f "$AI_SAFE_POLICY" ] || { echo "AI Safety package is not installed in workspace: $workspace" >&2; exit 2; }
[ -f "$SAFE_CONFIG" ] || { echo "Codex safety config was not found: $SAFE_CONFIG" >&2; exit 2; }

# A-1: workspace 内 .codex/auth.json に物理ファイルが残っていれば削除する (旧バージョン残骸)。
LEGACY_AUTH="$workspace/.codex/auth.json"
if [ -f "$LEGACY_AUTH" ] && [ ! -L "$LEGACY_AUTH" ]; then
  echo "A-1: Removing legacy physical auth.json from workspace tree: $LEGACY_AUTH" >&2
  rm -f "$LEGACY_AUTH"
fi

# auth.json は $HOME/.codex/auth.json へのシンボリックリンクを .codex-safe/ に張る。
# symlink が既に正しく張られていれば何もしない。
SRC_AUTH="$HOME/.codex/auth.json"
SAFE_AUTH="$SAFE_CODEX_HOME/auth.json"
if [ ! -f "$SRC_AUTH" ]; then
  echo "Codex auth not found at $SRC_AUTH. Please run 'codex login' first." >&2
  exit 2
fi
if [ ! -e "$SAFE_AUTH" ]; then
  ln -sf "$SRC_AUTH" "$SAFE_AUTH"
fi

# A-2: -c features.hooks=true を明示渡し。config.mac.toml の hooks=true と合わせて二重保証。
cmd=(codex --cd "$workspace" --profile safe --sandbox workspace-write --ask-for-approval untrusted -c features.hooks=true)
if command -v caffeinate >/dev/null 2>&1; then
  cmd=(caffeinate -dimsu "${cmd[@]}")
fi
if [ -n "$prompt" ]; then
  "${cmd[@]}" "$prompt"
else
  "${cmd[@]}"
fi
