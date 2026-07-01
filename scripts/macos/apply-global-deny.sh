#!/bin/bash
# apply-global-deny.sh — この Mac の Claude 全体設定 (~/.claude/settings.json) に、
# 危険コマンドの deny (curl / rm -rf / .env 読取 / git push / 外部送信ドメイン等) を反映する。
# A案 (宣言的 deny のみ): 既存の hooks / env / allow / ask は壊さず、permissions.deny だけを
# union マージする。実行前に ~/.ai-safety/backups/ に自動バックアップ。
#
# install 後、受講者が「Claude をどのフォルダで起動しても基本 deny を効かせたい」ときに 1 回実行する。
# workspace + launcher 経由の従来防御とは独立（併用して二重に守れる）。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 配置: <workspace>/.ai-safety/hooks/macos/apply-global-deny.sh
WORKSPACE="$(cd "$HERE/../../.." && pwd)"
SRC="${AI_SAFE_DENY_SRC:-$WORKSPACE/.claude/settings.json}"
JS="$HERE/../common/apply-global-deny.js"
TARGET="${AI_SAFE_GLOBAL_CLAUDE:-$HOME/.claude/settings.json}"

if ! command -v node >/dev/null 2>&1; then
  echo "エラー: node が見つかりません。Node.js を入れてから実行してください。" >&2
  exit 2
fi
if [ ! -f "$SRC" ]; then
  echo "エラー: deny の元設定が見つかりません: $SRC" >&2
  echo "  → 先に安全パッケージのインストール（1_安全パッケージを準備）を実行してください。" >&2
  exit 2
fi
if [ ! -f "$JS" ]; then
  echo "エラー: apply-global-deny.js が見つかりません: $JS" >&2
  exit 2
fi

echo "この Mac の Claude 全体（~/.claude/settings.json）に、危険コマンドの deny を反映します。"
echo "（既存の設定は壊しません。反映前に自動でバックアップを取ります。）"
node "$JS" "$SRC" "$TARGET" "$@"
