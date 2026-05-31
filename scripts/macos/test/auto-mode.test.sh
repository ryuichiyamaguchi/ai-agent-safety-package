#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/isolation_drills.sh"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
ng()  { echo "FAIL $1"; fail=$((fail+1)); }

# shellcheck disable=SC1090
. "$LIB"

# --- Task 1: drill_write_outside ---
# codex が無い環境では drill は「保留(非0)」を返す約束。
# codex 有無に関わらず、関数が定義され呼び出せることを確認する。
if type drill_write_outside >/dev/null 2>&1; then ok "drill_write_outside defined"; else ng "drill_write_outside defined"; fi

# --- Task 2: drill_network_egress ---
if type drill_network_egress >/dev/null 2>&1; then ok "drill_network_egress defined"; else ng "drill_network_egress defined"; fi

# 判定ロジックの単体検証: 接続結果の分類関数 classify_net_result。
#   "refused"   -> 0  (PASS: 金庫が拒否した)
#   "connected" -> 10 (FAIL: 繋がってしまった)
#   "timeout"   -> 20 (HOLD: 区別不能 → 安全側で赤)
classify_net_result refused   >/dev/null 2>&1; [ $? -eq 0 ]  && ok "classify refused=PASS"   || ng "classify refused=PASS"
classify_net_result connected >/dev/null 2>&1; [ $? -eq 10 ] && ok "classify connected=FAIL" || ng "classify connected=FAIL"
classify_net_result timeout   >/dev/null 2>&1; [ $? -eq 20 ] && ok "classify timeout=HOLD"   || ng "classify timeout=HOLD"

# --- Task 3: doctor --isolation-check ---
DOCTOR="$HERE/../doctor.sh"
# codex 未導入や保留時は非0(安全側)であることだけ保証する。
# (PASS=0 になるのは実機 codex がある green 環境のみなので、ここでは「実行できる」ことを確認)
bash "$DOCTOR" --isolation-check codex >/dev/null 2>&1; rc=$?
[ "$rc" -ne 127 ] && ok "doctor --isolation-check runs (rc=$rc)" || ng "doctor --isolation-check not found"
# 未知 engine は必ず非0
bash "$DOCTOR" --isolation-check bogus >/dev/null 2>&1; [ $? -ne 0 ] && ok "isolation-check unknown engine non-zero" || ng "isolation-check unknown engine non-zero"

# --- Task 4: launch-codex-safe.sh --auto branch (dry-run + doctor stub) ---
LAUNCH_C="$HERE/../launch-codex-safe.sh"
WS="$(mktemp -d)"; mkdir -p "$WS/.ai-safety/policy"
echo '{}' > "$WS/.ai-safety/policy/safety-policy.json"
STUB_OK="$(mktemp)";  printf '#!/bin/sh\nexit 0\n' > "$STUB_OK";  chmod +x "$STUB_OK"
STUB_NG="$(mktemp)";  printf '#!/bin/sh\necho "FAIL egress indeterminate"\nexit 1\n' > "$STUB_NG"; chmod +x "$STUB_NG"

# green: doctor が exit 0 → on-failure に解放
out_ok="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_OK" bash "$LAUNCH_C" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_ok" | grep -q -- "--ask-for-approval on-failure" && ok "codex --auto green -> on-failure" || ng "codex --auto green -> on-failure"

# 赤: doctor が exit 1 → untrusted にフォールバック
out_ng="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_NG" bash "$LAUNCH_C" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_ng" | grep -q -- "--ask-for-approval untrusted" && ok "codex --auto red -> untrusted fallback" || ng "codex --auto red -> untrusted fallback"
# 赤のとき理由が stderr に出る
err_ng="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_NG" bash "$LAUNCH_C" "$WS" "" --auto 2>&1 1>/dev/null)"
printf '%s' "$err_ng" | grep -qi "オートを有効にできません" && ok "codex red shows reason" || ng "codex red shows reason"

# --auto 無し: 従来どおり untrusted(回帰)
out_def="$(AI_SAFE_DRY_RUN=1 bash "$LAUNCH_C" "$WS" "" 2>/dev/null)"
printf '%s' "$out_def" | grep -q -- "--ask-for-approval untrusted" && ok "codex no-auto stays untrusted" || ng "codex no-auto stays untrusted"

# --- Task 5: launch-agy-safe.sh --auto branch ---
LAUNCH_A="$HERE/../launch-agy-safe.sh"
export AGY="$STUB_OK"   # agy バイナリ検出を満たすためのダミー(実行はされない=DRY_RUN)
# green: doctor 0 → --dangerously-skip-permissions が付く(--sandbox は維持)
out_a_ok="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_OK" bash "$LAUNCH_A" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_a_ok" | grep -q -- "--sandbox" && ok "agy --auto keeps --sandbox" || ng "agy --auto keeps --sandbox"
printf '%s' "$out_a_ok" | grep -q -- "--dangerously-skip-permissions" && ok "agy green -> skip-permissions" || ng "agy green -> skip-permissions"
# green でも未実証である旨を stderr に出す(overclaim 回避)
err_a_ok="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_OK" bash "$LAUNCH_A" "$WS" "" --auto 2>&1 1>/dev/null)"
printf '%s' "$err_a_ok" | grep -qi "未検証\|未実証\|verified" && ok "agy green shows unverified caveat" || ng "agy green shows unverified caveat"
# 赤(agy 無し相当): --dangerously-skip-permissions を付けずフォールバック + 理由表示
err_a_ng="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_NG" bash "$LAUNCH_A" "$WS" "" --auto 2>&1 1>/dev/null)"
printf '%s' "$err_a_ng" | grep -qi "オートを有効にできません" && ok "agy red shows reason" || ng "agy red shows reason"
out_a_ng="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_NG" bash "$LAUNCH_A" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_a_ng" | grep -q -- "--dangerously-skip-permissions" && ng "agy red must NOT skip-permissions" || ok "agy red stays safe (no skip-permissions)"

# --- Task 6: full doctor includes isolation drills ---
full_out="$(bash "$HERE/../doctor.sh" "$WS" 2>/dev/null || true)"
printf '%s' "$full_out" | grep -Eqi "egress|workspace-outside|isolation" && ok "full doctor reports isolation" || ng "full doctor reports isolation"

echo "auto-mode.test summary: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
