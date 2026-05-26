#!/usr/bin/env bash
# launch-agy-safe.sh
#
# Antigravity CLI (`agy`) を安全装置付きで起動する macOS 用 launcher。
# v1.3.0 で新規追加（Gemini CLI から Antigravity CLI への移行対応）。
#
# 強制する防御:
#   - --sandbox          : agy のターミナル制限サンドボックスを必須化
#   - --add-dir <ws>     : 作業ディレクトリを明示（workspace 外への混入を抑制）
# 渡さないフラグ:
#   - --dangerously-skip-permissions（絶対に付けない）

set -euo pipefail
workspace="${1:-$(pwd)}"
prompt="${2:-}"
workspace="$(cd "$workspace" && pwd)"

export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

# agy バイナリ検出
AGY="${AGY:-}"
if [ -z "$AGY" ]; then
  if [ -x "$HOME/.local/bin/agy" ]; then
    AGY="$HOME/.local/bin/agy"
  elif command -v agy >/dev/null 2>&1; then
    AGY="$(command -v agy)"
  else
    cat <<MSG >&2
Error: Antigravity CLI (agy) が見つかりません。

インストール手順:
  curl -fsSL https://antigravity.google/cli/install.sh | bash

インストール後、以下のいずれかを満たしてください:
  - \$HOME/.local/bin が \$PATH に含まれている
  - 環境変数 AGY=<agy バイナリのフルパス> をセット
MSG
    exit 2
  fi
fi

# 推奨設定の案内（初回のみ）
RECOMMENDED="$AI_SAFE_ROOT/configs/agy/recommended-settings.json"
HINT_FLAG="$HOME/.ai-safety/.agy-recommended-shown"
if [ -f "$RECOMMENDED" ] && [ ! -f "$HINT_FLAG" ]; then
  mkdir -p "$(dirname "$HINT_FLAG")" 2>/dev/null || true
  cat <<MSG >&2
[初回ヒント] agy の推奨セキュリティ設定があります:
  $RECOMMENDED

agy 起動後、画面右下の \`/settings\` を開いて、上記 JSON の各キーと同じ値に
合わせてください（特に allow_access_gitignore / allow_edit_gitignore /
allow_auto_run_commands は OFF 推奨）。

このヒントは次回以降は表示されません（再表示する場合は次のファイルを削除:
  $HINT_FLAG）
MSG
  touch "$HINT_FLAG" 2>/dev/null || true
fi

if [ -n "$prompt" ]; then
  "$AGY" --sandbox --add-dir "$workspace" --prompt "$prompt"
else
  "$AGY" --sandbox --add-dir "$workspace"
fi
