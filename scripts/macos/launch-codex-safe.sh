#!/usr/bin/env bash
set -euo pipefail
workspace="${1:-$(pwd)}"
prompt="${2:-}"
auto=0
[ "${3:-}" = "--auto" ] && auto=1
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
if [ "${AI_SAFE_DRY_RUN:-}" != "1" ]; then
  [ -f "$SAFE_CONFIG" ] || { echo "Codex safety config was not found: $SAFE_CONFIG" >&2; exit 2; }
fi

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
if [ "${AI_SAFE_DRY_RUN:-}" != "1" ]; then
  if [ ! -f "$SRC_AUTH" ]; then
    echo "Codex auth not found at $SRC_AUTH. Please run 'codex login' first." >&2
    exit 2
  fi
  if [ ! -e "$SAFE_AUTH" ]; then
    ln -sf "$SRC_AUTH" "$SAFE_AUTH"
  fi
fi

# Safe Auto Mode: --auto かつ doctor の隔離チェックが green のときだけ承認を下げる。
# フェイルクローズ: doctor が非0(HOLD/FAIL)なら理由を表示して従来の untrusted に留まる。
approval="untrusted"
if [ "$auto" -eq 1 ]; then
  doctor="${AI_SAFE_DOCTOR:-}"
  if [ -z "$doctor" ]; then
    doctor="$(cd "$(dirname "$0")" && pwd)/doctor.sh"
  fi
  # codex sandbox 初期化がハングしても launcher が無限ブロックしないよう上限 60 秒。
  # macOS に timeout コマンドは無いので perl の alarm でラップ(perl は macOS 標準)。
  # alarm で殺された場合 perl は非0で返る → else(フォールバック)に落ちる = フェイルクローズ。
  # `or exit 127`: exec 失敗(doctor 不在/実行ビット無し/パスがディレクトリ等)時に
  # perl が exit 0 で抜けて green に倒れる(フェイルオープン)のを防ぐ。失敗時は 127 → else。
  if command -v perl >/dev/null 2>&1; then
    isolation_ok() { perl -e 'alarm shift; exec @ARGV or exit 127' 60 "$doctor" --isolation-check codex >/dev/null 2>&1; }
  else
    isolation_ok() { "$doctor" --isolation-check codex >/dev/null 2>&1; }
  fi
  if isolation_ok; then
    approval="on-failure"
  else
    echo "⚠ オートを有効にできません: OS 隔離(金庫)を確認できませんでした。" >&2
    echo "  → 安全のため都度承認モードで起動します。直すには doctor を実行してください。" >&2
    approval="untrusted"
  fi
fi

# A-2: -c features.hooks=true を明示渡し。config.mac.toml の hooks=true と合わせて二重保証。
cmd=(codex --cd "$workspace" --profile safe --sandbox workspace-write --ask-for-approval "$approval" -c features.hooks=true)
if command -v caffeinate >/dev/null 2>&1; then
  cmd=(caffeinate -dimsu "${cmd[@]}")
fi

if [ "${AI_SAFE_DRY_RUN:-}" = "1" ]; then
  printf '%s ' "${cmd[@]}"; [ -n "$prompt" ] && printf '%q' "$prompt"; printf '\n'
  exit 0
fi

if [ -n "$prompt" ]; then
  "${cmd[@]}" "$prompt"
else
  "${cmd[@]}"
fi
