#!/usr/bin/env bash
# explainer.test.sh — action-text 表示・XSS・切り捨て・TAB 保全のテスト
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
ng()  { echo "FAIL $1"; fail=$((fail+1)); }

TD="$(mktemp -d)"
cleanup() { rm -rf "$TD"; }
trap cleanup EXIT

export AI_SAFE_LOG_DIR="$TD/logs"
export AI_SAFE_CARDS_DIR="$REPO/configs/safety/cards"
export AI_SAFE_MONITOR_INTERVAL=1

# --- helper: MODE + RAW_INPUT で extract_action_text を実行し now.html を書く。
#     ACTION_TEXT は subshell 外に出せないので tmp ファイル経由で取得。---
run_explain_with_json() {
  local mode="$1" json="$2"
  (
    set -u
    export MODE="$mode"
    export RAW_INPUT="$json"
    log_dir() { printf '%s\n' "$AI_SAFE_LOG_DIR"; }
    audit_log() { :; }
    source "$REPO/scripts/macos/lib/explainer.sh" 2>/dev/null
    mkdir -p "$AI_SAFE_LOG_DIR"
    ACTION_TEXT=""; ACTION_LABEL="操作"
    extract_action_text 2>/dev/null || true
    write_now_html "🔔" "テスト" "low" "2026-06-05 00:00:00" "test-card" "/dev/null" \
      "$ACTION_TEXT" "$ACTION_LABEL" 2>/dev/null
    printf '%s' "$ACTION_TEXT" > "$AI_SAFE_LOG_DIR/action_text.tmp"
  )
}

html="$AI_SAFE_LOG_DIR/now.html"
act="$AI_SAFE_LOG_DIR/action_text.tmp"

# --- T1: bash コマンドが now.html に表示される ---
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la /tmp"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'ls -la /tmp' "$html"; then
  ok "T1: bash command appears in now.html"
else
  ng "T1: bash command appears in now.html"
fi

# --- T2: XSS - <script> タグがエスケープされる ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo <script>alert(1)</script>"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '&lt;script&gt;' "$html" && ! grep -q '<script>alert' "$html"; then
  ok "T2: <script> is HTML-escaped (no raw XSS)"
else
  ng "T2: <script> is HTML-escaped (no raw XSS)"
fi

# --- T3: & が &amp; にエスケープされる ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat a && cat b"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '&amp;&amp;' "$html"; then
  ok "T3: ampersand is HTML-escaped"
else
  ng "T3: ampersand is HTML-escaped"
fi

# --- T4: write ツールで file_path が表示される ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt","content":"hello"}}'
run_explain_with_json "write" "$json"
if [ -f "$html" ] && grep -q '/tmp/test.txt' "$html"; then
  ok "T4: write file_path appears in now.html"
else
  ng "T4: write file_path appears in now.html"
fi

# --- T5: webfetch で url が表示される ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"WebFetch","tool_input":{"url":"https://example.com/api"}}'
run_explain_with_json "webfetch" "$json"
if [ -f "$html" ] && grep -q 'example.com' "$html"; then
  ok "T5: webfetch url appears in now.html"
else
  ng "T5: webfetch url appears in now.html"
fi

# --- T6a: ASCII 900字が実際に 800字で切られる（F-J修正確認）---
# _limit_chars を直接テスト（extract_action_text の JSON パーサ経由では
# 900字の長い文字列が sed で壊れうるため、切り捨て関数を単体で検証）
rm -f "$html" "$act"
python3 - << 'PYEOF' > "$TD/t6a.result" 2>&1
import subprocess, sys
repo = sys.argv[1] if len(sys.argv) > 1 else "."
a900 = 'a' * 900
with open('/tmp/expltest_a.tmp', 'w') as f:
    f.write(a900)
r = subprocess.run(['bash', '-c',
    f"source '{repo}/scripts/macos/lib/explainer.sh' 2>/dev/null; "
    "cat /tmp/expltest_a.tmp | _limit_chars 800 > /tmp/expltest_a_out.tmp"],
    capture_output=True)
data = open('/tmp/expltest_a_out.tmp', 'rb').read()
txt = data.decode('utf-8', errors='replace')
has_marker = '省略' in txt
in_range = 800 <= len(txt) <= 810
print(f"char_count={len(txt)} has_marker={has_marker} in_range={in_range}")
PYEOF
python3 - "$REPO" << 'PYEOF' >> "$TD/t6a.result" 2>&1
import sys
PYEOF
t6a_out="$(cat "$TD/t6a.result")"
if echo "$t6a_out" | grep -q "has_marker=True" && echo "$t6a_out" | grep -q "in_range=True"; then
  ok "T6a: ASCII 900-char cut to 800 chars with marker"
else
  ng "T6a: ASCII 900-char cut to 800 chars with marker ($t6a_out)"
fi

# --- T6b: マルチバイト(日本語) 900文字で切っても文字化けしない（F-J/F-M確認）---
rm -f "$html" "$act"
python3 - << 'PYEOF' > "$TD/t6b.result" 2>&1
import subprocess, sys
repo = "/Users/ryuichi/書類/yamaguchi-hub/10_AIエージェント安全パッケージ/ai-agent-safety-package-v1"
ja900 = 'あ' * 900
with open('/tmp/expltest_ja.tmp', 'w', encoding='utf-8') as f:
    f.write(ja900)
r = subprocess.run(['bash', '-c',
    f"source '{repo}/scripts/macos/lib/explainer.sh' 2>/dev/null; "
    "cat /tmp/expltest_ja.tmp | _limit_chars 800 > /tmp/expltest_ja_out.tmp"],
    capture_output=True)
data = open('/tmp/expltest_ja_out.tmp', 'rb').read()
try:
    txt = data.decode('utf-8')
    has_marker = '省略' in txt
    in_range = 800 <= len(txt) <= 810
    print(f"char_count={len(txt)} has_marker={has_marker} in_range={in_range} iconv=OK")
except UnicodeDecodeError as e:
    print(f"iconv=FAIL {e}")
PYEOF
t6b_out="$(cat "$TD/t6b.result")"
if echo "$t6b_out" | grep -q "iconv=OK" && echo "$t6b_out" | grep -q "has_marker=True" && echo "$t6b_out" | grep -q "in_range=True"; then
  ok "T6b: Japanese 900-char cut without mojibake"
else
  ng "T6b: Japanese 900-char cut without mojibake ($t6b_out)"
fi

# --- T6c: 800字以下のコマンドは「省略」が付かない ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls /tmp"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q '省略' "$html"; then
  ok "T6c: short command has no truncation marker"
else
  ng "T6c: short command has no truncation marker"
fi

# --- T7: TAB 入りコマンドが round-trip で壊れない（F-K修正確認）---
rm -f "$html" "$act"
(
  set -u
  export MODE="bash"
  # awk コマンドに -F\t フラグ（フィールドセパレータ TAB）を含む
  export RAW_INPUT='{"tool_input":{"command":"awk -v FS=\"\t\" \"{print $1}\" file.tsv"}}'
  log_dir() { printf '%s\n' "$AI_SAFE_LOG_DIR"; }
  audit_log() { :; }
  source "$REPO/scripts/macos/lib/explainer.sh" 2>/dev/null
  mkdir -p "$AI_SAFE_LOG_DIR"
  ACTION_TEXT=""; ACTION_LABEL="操作"
  extract_action_text 2>/dev/null || true
  write_now_html "🔔" "タブテスト" "low" "ts" "test" "/dev/null" \
    "$ACTION_TEXT" "$ACTION_LABEL" 2>/dev/null
  printf '%s' "$ACTION_TEXT" > "$AI_SAFE_LOG_DIR/action_text.tmp"
)
if [ -f "$html" ] && grep -q 'awk' "$html" && grep -q 'file.tsv' "$html"; then
  ok "T7: TAB-containing command appears intact in now.html"
else
  ng "T7: TAB-containing command round-trip broken"
fi

# --- T8: now.html に charset/refresh/setInterval タグが存在する (doctor 互換) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] \
  && grep -q '<meta charset="utf-8">' "$html" \
  && grep -q '<meta http-equiv="refresh"' "$html" \
  && grep -q 'setInterval' "$html"; then
  ok "T8: required tags (charset/refresh/setInterval) present"
else
  ng "T8: required tags (charset/refresh/setInterval) present"
fi

# --- T9: action-label と action-cmd クラスが HTML に存在する ---
if grep -q 'class="action"' "$html" && grep -q 'class="action-cmd"' "$html"; then
  ok "T9: action/action-cmd div present in now.html"
else
  ng "T9: action/action-cmd div present in now.html"
fi

# --- T10: F-I 維持 — 既存 now.html がある時 placeholder は上書きしない ---
existing_content="REAL_CONTENT_$(date +%s)"
printf '%s' "$existing_content" > "$html"
(
  set -u
  log_dir() { printf '%s\n' "$AI_SAFE_LOG_DIR"; }
  source "$REPO/scripts/macos/lib/explainer.sh" 2>/dev/null
  write_now_html_placeholder "$AI_SAFE_LOG_DIR" 2>/dev/null
)
after="$(cat "$html")"
if [ "$after" = "$existing_content" ]; then
  ok "T10: placeholder does not overwrite existing now.html (F-I)"
else
  ng "T10: placeholder does not overwrite existing now.html (F-I)"
fi

# --- T11: 一覧（Get-ChildItem 単独）→ 「現在のフォルダ」 ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"Get-ChildItem"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'これは何をする' "$html" && grep -q '現在のフォルダ' "$html" && grep -q '一覧' "$html"; then
  ok "T11: Get-ChildItem alone -> 一覧/現在のフォルダ"
else
  ng "T11: Get-ChildItem alone -> 一覧/現在のフォルダ"
fi

# --- T12: 一覧（対象パスあり）→ パスが具体表示 ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"Get-ChildItem -Path C:\\\\Users\\\\foo\\\\Temp"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'これは何をする' "$html" && grep -q 'Users' "$html" && grep -q '一覧' "$html"; then
  ok "T12: Get-ChildItem -Path -> 対象パス具体表示"
else
  ng "T12: Get-ChildItem -Path -> 対象パス具体表示 ($(grep -o 'whatdo-body[^<]*<[^>]*>[^<]*' "$html" 2>/dev/null | head -1))"
fi

# --- T13: 読む（cat foo.txt）→ 読む・対象=foo.txt ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'これは何をする' "$html" && grep -q 'foo.txt' "$html" && grep -q '読' "$html"; then
  ok "T13: cat foo.txt -> 読む/対象=foo.txt"
else
  ng "T13: cat foo.txt -> 読む/対象=foo.txt"
fi

# --- T14: 削除（Remove-Item -Recurse）→ 削除 + 完全削除警告（危険語）---
#  ※安全フック対策: 実 rm -rf は使わず PowerShell 系で確認
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"Remove-Item -Recurse build"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '削除' "$html" && grep -q 'whatdo-danger' "$html" && grep -q '完全削除' "$html"; then
  ok "T14: Remove-Item -Recurse -> 削除 + 完全削除警告"
else
  ng "T14: Remove-Item -Recurse -> 削除 + 完全削除警告"
fi

# --- T15: 通信（curl URL）→ 通信・対象=URL ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"curl https://example.com/api"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'これは何をする' "$html" && grep -q 'example.com' "$html" && grep -q '通信' "$html"; then
  ok "T15: curl URL -> 通信/対象=URL"
else
  ng "T15: curl URL -> 通信/対象=URL"
fi

# --- T16: 未知コマンド → フォールバック（嘘解説なし＝whatdo セクションを出さない）---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"xyzzy --foo bar"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'xyzzy' "$html" && ! grep -q '<p class="whatdo-body"' "$html"; then
  ok "T16: unknown command -> no fake explanation (fallback)"
else
  ng "T16: unknown command -> no fake explanation (fallback)"
fi

# --- T17: 権限昇格（sudo）→ 危険語強調（主コマンドに関わらず）---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"sudo ls /etc"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'whatdo-danger' "$html" && grep -q '権限' "$html"; then
  ok "T17: sudo -> 権限昇格警告"
else
  ng "T17: sudo -> 権限昇格警告"
fi

# --- T18: XSS — 対象パスに <script> → エスケープされる（whatdo セクション内）---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat <script>x</script>"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '&lt;script&gt;' "$html" && ! grep -q '<script>x' "$html"; then
  ok "T18: whatdo target XSS is escaped"
else
  ng "T18: whatdo target XSS is escaped"
fi

# --- T19: パイプライン → 「ほかにも処理が続きます」が添えられる ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt | grep abc"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'foo.txt' "$html" && grep -q 'ほかにも処理が続きます' "$html"; then
  ok "T19: pipeline -> 'ほかにも処理が続きます' note"
else
  ng "T19: pipeline -> 'ほかにも処理が続きます' note"
fi

# --- T20: write モードでは whatdo（bash 専用）を出さない（既存挙動維持）---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt","content":"hi"}}'
run_explain_with_json "write" "$json"
if [ -f "$html" ] && grep -q '/tmp/x.txt' "$html" && ! grep -q '<div class="whatdo-label"' "$html"; then
  ok "T20: write mode does not emit bash whatdo section"
else
  ng "T20: write mode does not emit bash whatdo section"
fi

echo ""
echo "explainer.test summary: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
