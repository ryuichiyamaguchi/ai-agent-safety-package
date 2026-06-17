#!/usr/bin/env bash
# observe-coverage.test.sh — catch-all observe フック (案A') の網羅テスト。
# 検証: WebSearch/Read/Glob/Grep → カードが書かれ tool 名 + 入力要約が見える。
#       Bash/PowerShell → カードを書かない（専用ガードが所有）。
#       observe は permissionDecision を絶対に出さず、ゴミ入力でも exit 0（fail-open）。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
GUARD="$REPO/scripts/macos/guard-observe.sh"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
ng()  { echo "FAIL $1"; fail=$((fail+1)); }

TD="$(mktemp -d)"
cleanup() { rm -rf "$TD"; }
trap cleanup EXIT

export AI_SAFE_LOG_DIR="$TD/logs"
export AI_SAFE_CARDS_DIR="$REPO/configs/safety/cards"
export AI_SAFE_POLICY="$REPO/policy/safety-policy.json"
export AI_SAFE_MONITOR_INTERVAL=1
mkdir -p "$AI_SAFE_LOG_DIR"
HTML="$AI_SAFE_LOG_DIR/now.html"

# run <json> -> sets RC and OUT (stdout), refreshes now.html state
run() {
  rm -f "$HTML"
  OUT="$(printf '%s' "$1" | bash "$GUARD" 2>/dev/null)"
  RC=$?
}

# --- T1: WebSearch → カードが書かれ、tool 名 + query が見える ---
run '{"hook_event_name":"PreToolUse","tool_name":"WebSearch","tool_input":{"query":"deploy nextjs to vercel"}}'
if [ "$RC" -eq 0 ] && [ -f "$HTML" ] && grep -q 'WebSearch' "$HTML" && grep -q 'deploy nextjs to vercel' "$HTML"; then
  ok "T1: WebSearch writes card with tool name + query"
else
  ng "T1: WebSearch writes card with tool name + query (rc=$RC)"
fi

# --- T2: Read → カードが書かれ、tool 名 + path が見える ---
run '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/Users/x/p/index.ts"}}'
if [ "$RC" -eq 0 ] && [ -f "$HTML" ] && grep -q 'Read' "$HTML" && grep -q '/Users/x/p/index.ts' "$HTML"; then
  ok "T2: Read writes card with tool name + path"
else
  ng "T2: Read writes card with tool name + path (rc=$RC)"
fi

# --- T3: Glob → カードが書かれ、pattern が見える ---
run '{"hook_event_name":"PreToolUse","tool_name":"Glob","tool_input":{"pattern":"**/*.ts","path":"/Users/x/p"}}'
if [ "$RC" -eq 0 ] && [ -f "$HTML" ] && grep -q 'Glob' "$HTML" && grep -q '\*\*/\*.ts' "$HTML"; then
  ok "T3: Glob writes card with tool name + pattern"
else
  ng "T3: Glob writes card with tool name + pattern (rc=$RC)"
fi

# --- T4: Grep → カードが書かれ、pattern が見える ---
run '{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"TODO","path":"/Users/x/p"}}'
if [ "$RC" -eq 0 ] && [ -f "$HTML" ] && grep -q 'Grep' "$HTML" && grep -q 'TODO' "$HTML"; then
  ok "T4: Grep writes card with tool name + pattern"
else
  ng "T4: Grep writes card with tool name + pattern (rc=$RC)"
fi

# --- T5: Bash → カードを書かない（専用ガードが所有する） ---
run '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"}}'
if [ "$RC" -eq 0 ] && [ ! -f "$HTML" ]; then
  ok "T5: Bash does NOT write card (specialized guard owns it)"
else
  ng "T5: Bash does NOT write card (rc=$RC, html exists=$([ -f "$HTML" ] && echo yes || echo no))"
fi

# --- T6: PowerShell → カードを書かない（専用ガードが所有する） ---
run '{"hook_event_name":"PreToolUse","tool_name":"PowerShell","tool_input":{"command":"Get-ChildItem"}}'
if [ "$RC" -eq 0 ] && [ ! -f "$HTML" ]; then
  ok "T6: PowerShell does NOT write card (specialized guard owns it)"
else
  ng "T6: PowerShell does NOT write card (rc=$RC)"
fi

# --- T7: Agent → task prompt 全文を出さない（種別のみ） ---
run '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"prompt":"TOPSECRET internal payload do not leak"}}'
if [ "$RC" -eq 0 ] && [ -f "$HTML" ] && grep -q 'subagent/task 作成' "$HTML" && ! grep -q 'TOPSECRET' "$HTML"; then
  ok "T7: Agent shows 'subagent/task 作成' and does NOT leak task prompt"
else
  ng "T7: Agent leaks task prompt or missing summary"
fi

# --- T8: observe は permissionDecision を絶対に出さない（全 tool） ---
decision_seen=0
for j in \
  '{"tool_name":"WebSearch","tool_input":{"query":"x"}}' \
  '{"tool_name":"Read","tool_input":{"file_path":"/a"}}' \
  '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  '{"tool_name":"Unknown","tool_input":{"foo":"bar"}}' ; do
  run "$j"
  if printf '%s' "$OUT" | grep -q 'permissionDecision'; then decision_seen=1; fi
done
if [ "$decision_seen" -eq 0 ]; then
  ok "T8: observe never emits permissionDecision"
else
  ng "T8: observe emitted a permissionDecision (must never)"
fi

# --- T9: ゴミ入力でも fail-open（exit 0・decision 無し） ---
run 'this is not json at all >>> & | ;'
g1=$RC; g1dec=0; printf '%s' "$OUT" | grep -q 'permissionDecision' && g1dec=1
run ''
g2=$RC; g2dec=0; printf '%s' "$OUT" | grep -q 'permissionDecision' && g2dec=1
if [ "$g1" -eq 0 ] && [ "$g2" -eq 0 ] && [ "$g1dec" -eq 0 ] && [ "$g2dec" -eq 0 ]; then
  ok "T9: garbage/empty input → exit 0, no permissionDecision (fail-open)"
else
  ng "T9: garbage/empty input not fail-open (g1=$g1 g2=$g2 dec=$g1dec/$g2dec)"
fi

# --- T10: 未知の tool でも最小カードが書かれる（汎用フォールバック） ---
run '{"hook_event_name":"PreToolUse","tool_name":"SomeFutureTool","tool_input":{"path":"/Users/x/data.bin"}}'
if [ "$RC" -eq 0 ] && [ -f "$HTML" ] && grep -q 'SomeFutureTool' "$HTML"; then
  ok "T10: unknown tool still produces a generic card with the tool name"
else
  ng "T10: unknown tool generic card missing (rc=$RC)"
fi

# --- 案A' のもう一方の柱: deny posture は PowerShell でも不変（guard-bash） ---
GUARD_BASH="$REPO/scripts/macos/guard-bash.sh"

# --- T11: guard-bash tool_name=PowerShell + 危険コマンド → BLOCK (exit 2) ---
# rm -rf を fixture ファイル経由で渡す（テスト文字列をシェル行に直書きしない）。
PSDANGER="$TD/ps_danger.json"
printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"PowerShell","tool_input":{"command":"rm -rf /"}}' > "$PSDANGER"
bash "$GUARD_BASH" < "$PSDANGER" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "T11: guard-bash blocks dangerous PowerShell command (exit 2, deny preserved)"
else
  ng "T11: guard-bash did NOT block dangerous PowerShell command (rc=$rc)"
fi

# --- T12: guard-bash tool_name=PowerShell + 安全コマンド → 非ブロック (exit 0) ---
PSSAFE="$TD/ps_safe.json"
printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"PowerShell","tool_input":{"command":"echo hello world"}}' > "$PSSAFE"
bash "$GUARD_BASH" < "$PSSAFE" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "T12: guard-bash allows safe PowerShell command (exit 0)"
else
  ng "T12: guard-bash unexpectedly non-zero for safe PowerShell command (rc=$rc)"
fi

echo
echo "observe-coverage: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
