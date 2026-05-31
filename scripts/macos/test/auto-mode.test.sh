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

echo "auto-mode.test summary: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
