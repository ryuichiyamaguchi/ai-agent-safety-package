#!/usr/bin/env bash
# =============================================================
# mac-verdicts.sh — 3 エンジン横断テストの mac 側ランナー
#
# cases.json の command を 1 件ずつ本物の guard-bash.sh に流し、
#   <id><TAB>block|ask|pass
# を 1 行ずつ標準出力に出す。判定ロジックはここには一切書かない
# （書くと「ガードを直したのにテストが古い判定を見ている」事故になる）。
#
# 使い方: bash mac-verdicts.sh <cases.json>
# =============================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
GUARD="$REPO/scripts/macos/guard-bash.sh"
CASES="${1:-$HERE/cases.json}"

[ -f "$CASES" ] || { echo "cases.json がありません: $CASES" >&2; exit 1; }
[ -x "$GUARD" ] || [ -f "$GUARD" ] || { echo "guard-bash.sh がありません: $GUARD" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 が必要です" >&2; exit 1; }

TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT INT TERM

# 2 鍵 assisted approval はグレー確定後の層。床の判定には関係しないが、
# 呼び出し元の環境変数で ask に化けると判定が揺れるので明示的に切る。
unset AI_SAFE_ASSISTED_APPROVAL DS_CLAUDE_MODE AI_SAFE_POLICY AI_SAFE_ROOT 2>/dev/null || true

# id と「そのまま guard へ渡せるフック JSON」を 1 行ずつ吐かせる。
# command 内の改行・タブは JSON エスケープのまま埋め込む（＝ Claude Code が実際に送る形。
# 復号はガード側の仕事であり、その復号漏れこそ cycle1 RED-1 だった）。
python3 - "$CASES" "$TD" <<'PY' > "$TD/lines"
import json, sys
cases = json.load(open(sys.argv[1], encoding="utf-8"))["cases"]
cwd = sys.argv[2]
for c in cases:
    payload = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "cwd": cwd,
        "tool_input": {"command": c["command"]},
    }
    print(c["id"] + "\t" + json.dumps(payload, ensure_ascii=False))
PY

while IFS=$'\t' read -r id payload; do
  [ -n "$id" ] || continue
  printf '%s' "$payload" \
    | AI_SAFE_LOG_DIR="$TD/logs" bash "$GUARD" >"$TD/out" 2>"$TD/err"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    # 床が壊れているときの FATAL も exit 2 なので、block と取り違えないよう分ける。
    if grep -q 'FATAL' "$TD/err" 2>/dev/null; then
      printf '%s\tfatal\n' "$id"
    else
      printf '%s\tblock\n' "$id"
    fi
  elif [ "$rc" -ne 0 ]; then
    printf '%s\terror(rc=%s)\n' "$id" "$rc"
  elif grep -q '"permissionDecision":"ask"' "$TD/out" 2>/dev/null; then
    printf '%s\task\n' "$id"
  else
    printf '%s\tpass\n' "$id"
  fi
done < "$TD/lines"
