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

# 判定ロジックの単体検証: 2 段プローブ分類関数 classify_net_result <baseline> <blocked>。
# フェイルクローズ: ベースライン疎通 (connected) + sandbox-blocked(EPERM系) のときだけ PASS。
#   baseline=connected blocked=sandbox-blocked -> 0  (PASS: sandbox 由来の遮断を実証)
#   baseline=connected blocked=general-refused -> 20 (HOLD: ECONNREFUSED は sandbox 実証にならない)
#   baseline=connected blocked=connected       -> 10 (FAIL: 遮断プロファイルでも繋がる = 穴)
#   baseline=connected blocked=timeout         -> 20 (HOLD: 遮断結果が判定不能)
#   baseline!=connected (オフライン/到達不能)  -> 20 (HOLD: 遮断を実証できない)
classify_net_result connected sandbox-blocked >/dev/null 2>&1; [ $? -eq 0 ]  && ok "classify baseline+blocked=PASS"        || ng "classify baseline+blocked=PASS"
classify_net_result connected connected >/dev/null 2>&1; [ $? -eq 10 ] && ok "classify block-leak=FAIL"              || ng "classify block-leak=FAIL"
classify_net_result connected timeout   >/dev/null 2>&1; [ $? -eq 20 ] && ok "classify block-indeterminate=HOLD"     || ng "classify block-indeterminate=HOLD"
classify_net_result refused   skipped   >/dev/null 2>&1; [ $? -eq 20 ] && ok "classify offline-baseline=HOLD"        || ng "classify offline-baseline=HOLD"
classify_net_result timeout   skipped   >/dev/null 2>&1; [ $? -eq 20 ] && ok "classify baseline-timeout=HOLD"        || ng "classify baseline-timeout=HOLD"
# 後方互換シグネチャ(引数1個)もフェイルクローズであること: refused 単独は PASS にしない。
classify_net_result refused   >/dev/null 2>&1; [ $? -eq 20 ] && ok "classify single-refused=HOLD (no false PASS)"     || ng "classify single-refused=HOLD"
classify_net_result connected >/dev/null 2>&1; [ $? -eq 10 ] && ok "classify single-connected=FAIL"                  || ng "classify single-connected=FAIL"

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
NOEXEC=""
trap 'rm -rf "$WS" "$STUB_OK" "$STUB_NG" "$NOEXEC" 2>/dev/null' EXIT

# green: doctor が exit 0 → on-failure に解放
out_ok="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_OK" bash "$LAUNCH_C" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_ok" | grep -q -- "--ask-for-approval on-failure" && ok "codex --auto green -> on-failure" || ng "codex --auto green -> on-failure"

# 赤: doctor が exit 1 → 未実証を開示しつつ on-failure で自走を継続。
# 決定的な危険操作は approval 非依存の guard-bash が止める。
out_ng="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_NG" bash "$LAUNCH_C" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_ng" | grep -q -- "--ask-for-approval on-failure" && ok "codex --auto red -> on-failure with hooks" || ng "codex --auto red -> on-failure with hooks"
# 赤のとき理由が stderr に出る
err_ng="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_NG" bash "$LAUNCH_C" "$WS" "" --auto 2>&1 1>/dev/null)"
printf '%s' "$err_ng" | grep -qi "OSで未実証" && ok "codex red discloses isolation status" || ng "codex red discloses isolation status"

# --auto 無し: 教室プロファイル既定の on-request。
out_def="$(AI_SAFE_DRY_RUN=1 bash "$LAUNCH_C" "$WS" "" 2>/dev/null)"
printf '%s' "$out_def" | grep -q -- "--ask-for-approval on-request" && ok "codex no-auto stays on-request" || ng "codex no-auto stays on-request"

# codex: doctor 不在 → 未実証扱いで on-failure。guard-bash の決定的 deny は維持。
out_miss_c="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR=/nonexistent/doctor.sh bash "$LAUNCH_C" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_miss_c" | grep -q -- "--ask-for-approval on-failure" && ok "codex missing-doctor -> on-failure with hooks" || ng "codex missing-doctor changed auto policy"
# codex: 実行ビット無しの doctor(zip 配布/chmod 漏れ相当)も同じく未実証扱い。
NOEXEC="$(mktemp)"; printf '#!/bin/sh\nexit 0\n' > "$NOEXEC"; chmod -x "$NOEXEC"
out_noexec_c="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$NOEXEC" bash "$LAUNCH_C" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_noexec_c" | grep -q -- "--ask-for-approval on-failure" && ok "codex noexec-doctor -> on-failure with hooks" || ng "codex noexec-doctor changed auto policy"

# --- Task 5: launch-agy-safe.sh --auto branch ---
# AGY="$STUB_OK" は agy バイナリ検出を満たすためのダミー(実行はされない=DRY_RUN)。
# グローバル export は避け、各呼び出しに inline で渡す。
LAUNCH_A="$HERE/../launch-agy-safe.sh"
# green: doctor 0 → --dangerously-skip-permissions が付く(--sandbox は維持)
out_a_ok="$(AI_SAFE_DRY_RUN=1 AGY="$STUB_OK" AI_SAFE_DOCTOR="$STUB_OK" bash "$LAUNCH_A" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_a_ok" | grep -q -- "--sandbox" && ok "agy --auto keeps --sandbox" || ng "agy --auto keeps --sandbox"
printf '%s' "$out_a_ok" | grep -q -- "--dangerously-skip-permissions" && ok "agy green -> skip-permissions" || ng "agy green -> skip-permissions"
# green でも未実証である旨を stderr に出す(overclaim 回避)
err_a_ok="$(AI_SAFE_DRY_RUN=1 AGY="$STUB_OK" AI_SAFE_DOCTOR="$STUB_OK" bash "$LAUNCH_A" "$WS" "" --auto 2>&1 1>/dev/null)"
printf '%s' "$err_a_ok" | grep -qi "未検証\|未実証\|verified" && ok "agy green shows unverified caveat" || ng "agy green shows unverified caveat"
# 赤(doctor 非0): --dangerously-skip-permissions を付けずフォールバック + 理由表示
err_a_ng="$(AI_SAFE_DRY_RUN=1 AGY="$STUB_OK" AI_SAFE_DOCTOR="$STUB_NG" bash "$LAUNCH_A" "$WS" "" --auto 2>&1 1>/dev/null)"
printf '%s' "$err_a_ng" | grep -qi "オートを有効にできません" && ok "agy red shows reason" || ng "agy red shows reason"
# 赤でも --sandbox 付きで dry-run 成功(exit 0)すること = クラッシュしていないことを明示検証。
out_a_ng="$(AI_SAFE_DRY_RUN=1 AGY="$STUB_OK" AI_SAFE_DOCTOR="$STUB_NG" bash "$LAUNCH_A" "$WS" "" --auto 2>/dev/null)"; rc_ng=$?
printf '%s' "$out_a_ng" | grep -q -- "--sandbox" && [ "$rc_ng" -eq 0 ] && ok "agy red still launches with --sandbox" || ng "agy red launch broken"
printf '%s' "$out_a_ng" | grep -q -- "--dangerously-skip-permissions" && ng "agy red must NOT skip-permissions" || ok "agy red stays safe (no skip-permissions)"

# --auto 無し: 通常起動(--sandbox のみ)。bash 3.2 で空配列展開クラッシュしないことを検証。
out_a_def="$(AI_SAFE_DRY_RUN=1 AGY="$STUB_OK" bash "$LAUNCH_A" "$WS" "" 2>/dev/null)"; rc_def=$?
printf '%s' "$out_a_def" | grep -q -- "--sandbox" && [ "$rc_def" -eq 0 ] && ok "agy no-auto launches (--sandbox only)" || ng "agy no-auto broken"
printf '%s' "$out_a_def" | grep -q -- "--dangerously-skip-permissions" && ng "agy no-auto must NOT skip-permissions" || ok "agy no-auto has no skip-permissions"

# agy: doctor 不在 → exec 失敗してもフェイルクローズ(skip-permissions 無し)。
out_miss_a="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR=/nonexistent/doctor.sh AGY="$STUB_OK" bash "$LAUNCH_A" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_miss_a" | grep -q -- "--dangerously-skip-permissions" && ng "agy missing-doctor LEAKS skip-permissions" || ok "agy missing-doctor -> no skip-permissions (fail-closed)"
# agy: 実行ビット無しの doctor → フェイルクローズ。
out_noexec_a="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$NOEXEC" AGY="$STUB_OK" bash "$LAUNCH_A" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_noexec_a" | grep -q -- "--dangerously-skip-permissions" && ng "agy noexec-doctor LEAKS skip-permissions" || ok "agy noexec-doctor -> no skip-permissions (fail-closed)"

# --- Task 5b: F-A network drill — sandbox-blocked vs general refused 区別 ---
# F-A: 一般的な Connection refused(ECONNREFUSED)は sandbox 実証にならないので HOLD。
# classify_net_result に sandbox-blocked / general-refused の 2 値を渡して判定が正しいか確認。
classify_net_result connected sandbox-blocked >/dev/null 2>&1; [ $? -eq 0 ]  && ok "classify sandbox-blocked=PASS"            || ng "classify sandbox-blocked=PASS"
classify_net_result connected general-refused >/dev/null 2>&1; [ $? -eq 20 ] && ok "classify general-refused=HOLD (no false PASS)" || ng "classify general-refused=HOLD"
# 後方互換(引数 1 個): refused 単独は sandbox 由来か不明なので HOLD のまま変わらないこと。
classify_net_result refused >/dev/null 2>&1; [ $? -eq 20 ] && ok "classify 1arg-refused still HOLD (no false PASS)" || ng "classify 1arg-refused still HOLD"

# --- Task 6: full doctor includes isolation drills ---
full_out="$(bash "$HERE/../doctor.sh" "$WS" 2>/dev/null || true)"
printf '%s' "$full_out" | grep -Eqi "egress|workspace-outside|isolation" && ok "full doctor reports isolation" || ng "full doctor reports isolation"

echo "auto-mode.test summary: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
