#!/usr/bin/env bash
# ci-opencode-latest.sh — 最新の OpenCode で、OpenCode ランチャーの起動前点検を本当に通す（mac）
#
# なぜ要るか: パッケージは OpenCode を「常に最新版」で入れる。OpenCode 側の変更で起動前点検が
# 止まると（v1.19.2: 1.18.26 から設定の一部が *** で伏せて表示されるようになり、受講者の PC で
# OpenCode が起動しなくなった）、受講者のほうが先に気づくことになる。週 1 回、最新の OpenCode で
# ランチャーを最後まで流して、受講者より先に見つける（.github/workflows/latest-tools.yml）。
#
# やり方: OPENCODE_BIN を代役に差し替える。代役は「版の確認」と「設定の出力（debug config）」を
# 本物の OpenCode に渡し、画面（TUI）の起動の代わりに印を残して終わる。ランチャーは
#   1) 解決済み設定で deny 床が生きているか（opencode-config.js --verify-resolved）
#   2) 安全プラグインが実際に読み込まれたか（BOUNCER_READY_OK）
# を確かめてから起動するので、印が残れば「最新の OpenCode でも点検を通った」ことになる。
# 無料モデルのモード（--free）で流すので、DeepSeek のキーは要らない。
#
# 使い方: bash scripts/macos/test/ci-opencode-latest.sh [本物の opencode のパス]
#   省略時は PATH の opencode を使う。HOME は使い捨て（本物のホームには触らない）。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
REAL="${1:-$(command -v opencode 2>/dev/null || true)}"
case "$REAL" in /*) ;; *) REAL="$(PATH="$PATH" /usr/bin/which opencode 2>/dev/null || true)" ;; esac
if [ -z "$REAL" ] || [ ! -x "$REAL" ]; then
  echo "FAIL 本物の opencode が見つかりません（引数か PATH で渡してください）"
  exit 1
fi
echo "OpenCode: $REAL ($("$REAL" --version 2>/dev/null | head -n1))"

BASE="${RUNNER_TEMP:-$HOME/.cache}"
mkdir -p "$BASE"
TD="$(mktemp -d "$BASE/asp-oc-latest-XXXXXX")"
trap 'rm -rf "$TD"' EXIT
H="$TD/home"
WS="$H/AI作業フォルダ"
mkdir -p "$H"

echo "===== 1/2 導入（使い捨てのホームへ） ====="
if ! HOME="$H" ZDOTDIR="$H" bash "$REPO/scripts/macos/install.sh" "$WS" >"$TD/install.log" 2>&1; then
  tail -n 30 "$TD/install.log"
  echo "FAIL 導入に失敗しました"
  exit 1
fi
LAUNCHER="$WS/.ai-safety/hooks/macos/opencode/launch-opencode-deepseek.sh"
[ -f "$LAUNCHER" ] || { echo "FAIL 導入後にランチャーが見つかりません: $LAUNCHER"; exit 1; }

MARKER="$TD/tui-started"
WRAPPER="$TD/opencode-wrapper"
cat >"$WRAPPER" <<'EOF'
#!/usr/bin/env bash
# 版の確認と設定の出力だけ本物へ。それ以外（TUI の起動）は印を残して終わる。
case "${1:-}" in
  --version|-v|debug) exec "$OC_REAL" "$@" ;;
esac
printf '%s\n' "$*" >"$OC_TUI_MARKER"
exit 0
EOF
chmod +x "$WRAPPER"

echo "===== 2/2 ランチャーを最新の OpenCode で流す（--free） ====="
HOME="$H" ZDOTDIR="$H" OPENCODE_BIN="$WRAPPER" OC_REAL="$REAL" OC_TUI_MARKER="$MARKER" \
  bash "$LAUNCHER" "$WS" --free </dev/null >"$TD/launch.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ -f "$MARKER" ]; then
  echo "PASS 最新の OpenCode でも起動前点検を通り、起動まで進んだ（rc=${rc}）"
  exit 0
fi
echo "--- ランチャーの出力（末尾） ---"
tail -n 40 "$TD/launch.log"
for f in "$H"/.ai-safety/logs/opencode-resolved-failed*.json "$WS"/.ai-safety/logs/opencode-resolved-failed*.json; do
  [ -f "$f" ] || continue
  echo "--- 点検で不一致だった設定（$f の先頭） ---"
  head -c 3000 "$f"
  echo
done
echo "FAIL 最新の OpenCode で起動前点検を通らなかった（rc=${rc}、起動の印: $([ -f "$MARKER" ] && echo あり || echo なし)）"
exit 1
