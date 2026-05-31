#!/usr/bin/env bash
# launch-agy-safe.sh — Antigravity CLI (agy) を安全装置付きで起動。
# Safe Auto Mode: --auto かつ doctor green のとき auto-run を有効化(--sandbox は維持)。
set -euo pipefail
workspace="${1:-$(pwd)}"
prompt="${2:-}"
auto=0
[ "${3:-}" = "--auto" ] && auto=1
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

# Safe Auto Mode 分岐(宣言ベース・option B): doctor green のとき
# --dangerously-skip-permissions を付与(--sandbox は維持)。実証はしていない旨を必ず表示。
auto_args=()
if [ "$auto" -eq 1 ]; then
  doctor="${AI_SAFE_DOCTOR:-}"
  if [ -z "$doctor" ]; then
    doctor="$(cd "$(dirname "$0")" && pwd)/doctor.sh"
  fi
  if "$doctor" --isolation-check agy >/dev/null 2>&1; then
    auto_args=(--dangerously-skip-permissions)
    echo "ℹ オートを有効化しました(agy)。注意: agy の隔離は --sandbox を信頼するもので、" >&2
    echo "  Codex のように独立検証(実証・verified)されていません。重要作業では手動承認の利用も検討してください。" >&2
  else
    echo "⚠ オートを有効にできません: agy を検出できませんでした。" >&2
    echo "  → 安全のため通常モード(--sandbox のみ)で起動します。" >&2
  fi
fi

cmd=("$AGY" --sandbox --add-dir "$workspace" "${auto_args[@]}")

if [ "${AI_SAFE_DRY_RUN:-}" = "1" ]; then
  printf '%s ' "${cmd[@]}"; [ -n "$prompt" ] && printf -- '--prompt %q' "$prompt"; printf '\n'
  exit 0
fi

if [ -n "$prompt" ]; then
  "${cmd[@]}" --prompt "$prompt"
else
  "${cmd[@]}"
fi
