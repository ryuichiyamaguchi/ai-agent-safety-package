#!/bin/bash
# install-statusline.sh — 軽量ステータスライン(statusline.mjs)を Claude 全体設定
# (~/.claude/settings.json) に登録する。claude / d-claude 両方に効く。
# 配置: <workspace>/.ai-safety/hooks/macos/install-statusline.sh
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
js="$here/../common/install-statusline.js"
script="$here/../common/statusline.mjs"
target="${AI_SAFE_GLOBAL_CLAUDE:-$HOME/.claude/settings.json}"

if ! command -v node >/dev/null 2>&1; then
  echo "node が見つかりません。Node.js を入れてから実行してください。" >&2
  exit 2
fi
if [ ! -f "$js" ] || [ ! -f "$script" ]; then
  echo "スクリプトが見つかりません（先に「1_安全パッケージを準備」を実行してください）: $js" >&2
  exit 2
fi

mode="${1:-install}"
if [ "$mode" = "uninstall" ]; then
  node "$js" uninstall --target "$target"
else
  node "$js" install --target "$target" --script "$script" --os macos
fi
