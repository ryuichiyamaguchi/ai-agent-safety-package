#!/usr/bin/env bash
# clipboard-safe-paste.sh
#
# クリップボードのテキストを secret-scan でマスキングし、結果を再度
# クリップボードに書き戻す便利ツール（v1.4.0 で新規追加）。
#
# 使い方:
#   safe-paste              # クリップボードをスキャン＋マスキング＋書き戻し
#   safe-paste --check      # マスキングせず検出件数だけ表示
#   safe-paste --quiet      # 警告抑制（ログには記録）

set -u
LANG=${LANG:-en_US.UTF-8}

PKG_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SECRET_SCAN="$PKG_ROOT/scripts/macos/secret-scan.sh"

if [ ! -x "$SECRET_SCAN" ]; then
  echo "safe-paste: secret-scan not found at $SECRET_SCAN" >&2
  exit 2
fi

if ! command -v pbpaste >/dev/null 2>&1; then
  echo "safe-paste: pbpaste not available (macOS only)" >&2
  exit 2
fi

if [ -t 1 ]; then
  C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_RST=$'\033[0m'
else
  C_GRN=""; C_RED=""; C_RST=""
fi

# 引数をそのまま secret-scan に渡す（--check / --quiet 等）
# 引数なしで呼ぶのが既定の使い方（safe-paste）なので ARGS は空になりうる。
# macOS 標準の bash 3.2 + set -u では空配列の "${ARGS[@]}" 展開が
# unbound variable でクラッシュするため、以降 ${ARGS[@]+"${ARGS[@]}"} を使う。
ARGS=("$@")

# クリップボード内容を取得
RAW="$(pbpaste)"
if [ -z "$RAW" ]; then
  echo "${C_RED}safe-paste: クリップボードが空です${C_RST}" >&2
  exit 1
fi

# --check モードか判定
CHECK_MODE=0
for arg in ${ARGS[@]+"${ARGS[@]}"}; do
  if [ "$arg" = "--check" ]; then
    CHECK_MODE=1
    break
  fi
done

if [ "$CHECK_MODE" -eq 1 ]; then
  # check モード: 結果を stderr に出すだけ、クリップボードは触らない
  printf '%s' "$RAW" | "$SECRET_SCAN" ${ARGS[@]+"${ARGS[@]}"}
  exit $?
fi

# mask モード: スキャン結果をクリップボードに書き戻し
MASKED="$(printf '%s' "$RAW" | "$SECRET_SCAN" ${ARGS[@]+"${ARGS[@]}"})"
SCAN_EXIT=$?

if [ $SCAN_EXIT -ne 0 ]; then
  echo "${C_RED}safe-paste: secret-scan が exit $SCAN_EXIT で失敗しました${C_RST}" >&2
  exit $SCAN_EXIT
fi

printf '%s' "$MASKED" | pbcopy
echo "${C_GRN}✓ クリップボードを更新しました（マスキング適用済）${C_RST}" >&2
echo "${C_GRN}  → 外部 LLM に ⌘V で貼り付けて使ってください${C_RST}" >&2
exit 0
