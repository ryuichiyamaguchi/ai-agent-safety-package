#!/usr/bin/env bash
# lib-load-fail-closed.test.sh — 共通部品が読めないときにガードが素通しにならないことの回帰テスト（v1.19.8）
#
# ガードは lib/safety_policy.sh を読み込んでから判定する。以前は読み込みに失敗しても先へ進み、
# 関数が「見つからない」(127) で終わっていた。Claude Code・Codex・Gemini は 2 以外の終了を
# 「止めない」と扱うので、部品が壊れたり消えたりすると、どのコマンドも素通しになっていた。
# 操作を止める役のガード 4 本（bash / write / webfetch / post-output）が、
#   ・部品が壊れている（構文エラー）
#   ・部品が無い
#   ・部品の中身が空（関数が定義されない）
# のどれでも exit 2（FAILED CLOSED）で終わること、ふつうの判定は変わらないことを確かめる。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# パッケージの必要な部分を一時フォルダへ写して、そちらの部品を壊す（本物には触らない）。
mkdir -p "$TD/pkg/scripts"
cp -R "$REPO/scripts/macos" "$REPO/scripts/common" "$TD/pkg/scripts/"
cp -R "$REPO/policy" "$REPO/configs" "$TD/pkg/"
G="$TD/pkg/scripts/macos"
LIB="$G/lib/safety_policy.sh"
cp "$LIB" "$TD/lib.bak"

input_for() {
  case "$1" in
    bash) printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"npm test"}}' ;;
    write) printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Write","cwd":"/tmp","tool_input":{"file_path":"/tmp/notes.txt","content":"hello"}}' ;;
    webfetch) printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"WebFetch","cwd":"/tmp","tool_input":{"url":"https://github.com/example/repo","prompt":"summarize"}}' ;;
    post-output) printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_response":{"stdout":"hi"}}' ;;
  esac
}

run_guard() {
  input_for "$1" | AI_SAFE_LOG_DIR="$TD/logs" bash "$G/guard-$1.sh" >"$TD/out" 2>"$TD/err"
  echo $?
}

# ふつうの判定は変わらない（壊す前）
for g in bash write webfetch post-output; do
  rc="$(run_guard "$g")"
  if [ "$rc" -eq 0 ]; then ok "部品が正常なら $g はふつうに許可する"; else ng "部品が正常なのに $g が止まった (rc=$rc): $(head -c 200 "$TD/err")"; fi
done

check_closed() {
  local label="$1" g="$2" rc
  rc="$(run_guard "$g")"
  if [ "$rc" -eq 2 ] && grep -q "FAILED CLOSED" "$TD/err"; then
    ok "$label: $g は止める (exit 2)"
  else
    ng "$label: $g が止まらなかった (rc=$rc): $(head -c 200 "$TD/err")"
  fi
}

printf 'broken() {\n' >"$LIB"
for g in bash write webfetch post-output; do check_closed "部品が壊れている" "$g"; done

rm -f "$LIB"
for g in bash write webfetch post-output; do check_closed "部品が無い" "$g"; done

printf 'true\n' >"$LIB"
for g in bash write webfetch post-output; do check_closed "部品の中身が空" "$g"; done

cp "$TD/lib.bak" "$LIB"

printf '\n--- lib load fail-closed: %d passed, %d failed ---\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
