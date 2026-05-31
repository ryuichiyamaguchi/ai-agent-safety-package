#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/isolation-drills.sh"
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

echo "auto-mode.test summary: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
