#!/usr/bin/env bash
# post-output-secret.test.sh — output over-block fix の回帰テスト。
# 検証:
#   - guard-post-output は outputSecretRegex（Generic sensitive assignment 除外）で走査する。
#     汎用代入 `api_key: "sk-your-key-here..."`（本物のキー書式ではない）は ALLOW(exit 0)。
#   - 本物のキー書式（秘密鍵ブロック / sk-ant-…）は引き続き BLOCK(exit 2)。
#   - 入力側 guard-bash は secretRegex 全体（Generic sensitive assignment 含む）のまま。
#     .env 読み出し / password=longvalue… は BLOCK(exit 2)。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
POST="$REPO/scripts/macos/guard-post-output.sh"
BASH_GUARD="$REPO/scripts/macos/guard-bash.sh"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
ng()  { echo "FAIL $1"; fail=$((fail+1)); }

TD="$(mktemp -d)"
cleanup() { rm -rf "$TD"; }
trap cleanup EXIT

export AI_SAFE_LOG_DIR="$TD/logs"
export AI_SAFE_POLICY="$REPO/policy/safety-policy.json"
mkdir -p "$AI_SAFE_LOG_DIR"

# run <guard> <json> -> sets RC
run() {
  printf '%s' "$2" | bash "$1" >/dev/null 2>&1
  RC=$?
}

# Build real-looking secrets via concatenation so they are not literal in source.
SK="sk"; ANT="-ant-"; ANT_KEY="${SK}${ANT}$(printf 'A%.0s' $(seq 1 24))"
BEGIN_PK="-----BEGIN OPENSSH PRIVATE KEY-----"
# Generic assignment value that is NOT a real key format (placeholder).
# 注意: `sk-your-key-here-1234567890` のような `sk-` 始まりの例は、それ自体が
# OpenAI キー書式 `sk-[A-Za-z0-9_-]{20,}` に一致するため出力側でも正しく BLOCK される
# （本物のキー書式は残す方針）。over-block バグの本質は「Generic sensitive assignment
# にだけ一致する正規の技術文」が落ちる点なので、real-format に当たらない placeholder を使う。
GENERIC_VAL='api_key: "your-placeholder-value-here"'
GENERIC_JSON_VAL="$(printf '%s' "$GENERIC_VAL" | sed 's/\\/\\\\/g; s/"/\\"/g')"
# Input-side: a plain password assignment with a long value.
PW_VAL="password=longvalue123456"

# --- T1: generic assignment in AI output → ALLOW (regression for the over-block bug) ---
run "$POST" "{\"hook_event_name\":\"Stop\",\"content\":\"${GENERIC_JSON_VAL}\"}"
[ "$RC" -eq 0 ] && ok "T1: generic api_key placeholder in output -> ALLOW (exit 0)" \
                || ng "T1: generic api_key placeholder in output still blocked (rc=$RC) — over-block NOT fixed"
SNAP="$AI_SAFE_LOG_DIR/latest-answer.json"
if [ -f "$SNAP" ] && grep -q 'REDACTED:Generic sensitive assignment' "$SNAP" 2>/dev/null; then
  ok "T1b: allowed Stop output writes redacted latest-answer.json"
else
  ng "T1b: allowed Stop output did not write redacted latest-answer.json"
fi

# --- T2: private key block in AI output → still BLOCK ---
run "$POST" "{\"hook_event_name\":\"Stop\",\"content\":\"${BEGIN_PK}\\nMIIxxxx\"}"
[ "$RC" -eq 2 ] && ok "T2: private key block in output -> BLOCK (exit 2)" \
                || ng "T2: private key block in output not blocked (rc=$RC)"

# --- T3: real-format Anthropic token in AI output → still BLOCK ---
run "$POST" "{\"hook_event_name\":\"Stop\",\"content\":\"here is the key ${ANT_KEY}\"}"
[ "$RC" -eq 2 ] && ok "T3: real sk-ant- token in output -> BLOCK (exit 2)" \
                || ng "T3: real sk-ant- token in output not blocked (rc=$RC)"

# --- T4 (input sanity): guard-bash reading .env → still BLOCK (full secretRegex/dangerous unchanged) ---
run "$BASH_GUARD" '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat .env"}}'
[ "$RC" -eq 2 ] && ok "T4: input guard-bash .env read -> BLOCK (exit 2)" \
                || ng "T4: input guard-bash .env read NOT blocked (rc=$RC) — input side changed!"

# --- T5 (input sanity): guard-bash with password=longvalue → still BLOCK on Generic sensitive assignment ---
run "$BASH_GUARD" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"export ${PW_VAL}\"}}"
[ "$RC" -eq 2 ] && ok "T5: input guard-bash password=longvalue -> BLOCK (exit 2)" \
                || ng "T5: input guard-bash generic assignment NOT blocked (rc=$RC) — input side weakened!"

echo "----"
echo "post-output-secret: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
