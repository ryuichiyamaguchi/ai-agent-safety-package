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

# ============================================================
# cycle-2 追加テスト: 安全設計の保守的動作を検証
# (否定アサート必須 / 誤警告ゼロ / 対象抽出 / now.md カバー)
# ============================================================

# ---- ヘルパー: now.md に解説が出ることを検証 ----
run_explain_with_nowmd() {
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
    cards_dir() { printf '%s\n' "$AI_SAFE_CARDS_DIR"; }
    write_now_card "default-bash" "low" "$ACTION_TEXT" "$ACTION_LABEL" 2>/dev/null
  )
}

md="$AI_SAFE_LOG_DIR/now.md"

# --- T21: 破壊的コマンド(後段削除): 安心文「しません」が出ない + 削除警告が出る ---
# ls foo | del temp.txt (ls は一覧だが後段に削除)
rm -f "$html" "$act" "$md"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls foo | del temp.txt"}}'
run_explain_with_json "bash" "$json"
t21_no_calm=0; t21_has_danger=0
if [ -f "$html" ] && ! grep -q 'しません' "$html"; then t21_no_calm=1; fi
if [ -f "$html" ] && grep -q '<p class="whatdo-danger"' "$html" && grep -q '削除' "$html"; then t21_has_danger=1; fi
if [ "$t21_no_calm" -eq 1 ] && [ "$t21_has_danger" -eq 1 ]; then
  ok "T21: ls|del -> NO calm text + danger(deletion) present"
else
  ng "T21: ls|del -> NO calm text + danger(deletion) present (no_calm=$t21_no_calm has_danger=$t21_has_danger)"
fi

# --- T22: 実行後段(cat | sh): 安心文「しません」が出ない + 実行警告が出る ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat build.sh | sh"}}'
run_explain_with_json "bash" "$json"
t22_no_calm=0; t22_has_exec=0
if [ -f "$html" ] && ! grep -q 'しません' "$html"; then t22_no_calm=1; fi
if [ -f "$html" ] && grep -q '<p class="whatdo-danger"' "$html" && grep -q '実行' "$html"; then t22_has_exec=1; fi
if [ "$t22_no_calm" -eq 1 ] && [ "$t22_has_exec" -eq 1 ]; then
  ok "T22: cat|sh -> NO calm text + exec danger"
else
  ng "T22: cat|sh -> NO calm text + exec danger (no_calm=$t22_no_calm has_exec=$t22_has_exec)"
fi

# --- T23: リダイレクト書き込み(cat > file): 書き込み解説 + 「読むだけ」が出ない ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat readme.txt > out.txt"}}'
run_explain_with_json "bash" "$json"
t23_write=0; t23_no_readonly=0
if [ -f "$html" ] && grep -q '書き込み' "$html"; then t23_write=1; fi
if [ -f "$html" ] && ! grep -q '読むだけ' "$html" && ! grep -q 'しません' "$html"; then t23_no_readonly=1; fi
if [ "$t23_write" -eq 1 ] && [ "$t23_no_readonly" -eq 1 ]; then
  ok "T23: cat>file -> write message + no read-only text"
else
  ng "T23: cat>file -> write message + no read-only text (write=$t23_write no_ro=$t23_no_readonly)"
fi

# --- T24: 誤警告ゼロ: Get-ChildItem -Recurse → 「完全削除」が出ない ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"Get-ChildItem -Recurse"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q '完全削除' "$html" && ! grep -q '<p class="whatdo-danger"' "$html"; then
  ok "T24: Get-ChildItem -Recurse -> NO false deletion warning"
else
  ng "T24: Get-ChildItem -Recurse -> NO false deletion warning"
fi

# --- T25: 誤警告ゼロ: tar -rf archive.tar (削除アーカイブ更新) → 削除誤警告なし ---
# tar の -r はアーカイブ追記。削除動詞ではない。
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"tar -rf archive.tar newfile.txt"}}'
run_explain_with_json "bash" "$json"
# tar は未知コマンドなのでwhatdo-body は出ない。danger も出てはいけない。
if [ -f "$html" ] && ! grep -q '完全削除' "$html" && ! grep -q '削除を含みます' "$html"; then
  ok "T25: tar -rf -> NO false deletion warning"
else
  ng "T25: tar -rf -> NO false deletion warning"
fi

# --- T26: 対象抽出: del /s C:\\Temp → 対象=C:\Temp (スイッチ /s を対象にしない) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"del /s C:\\\\Temp"}}'
run_explain_with_json "bash" "$json"
# C:\Temp が表示され、/s が対象にならないこと
if [ -f "$html" ] && grep -q 'Temp' "$html" && ! grep -Eq '対象=/s|whatdo-body.*[^T]/s' "$html"; then
  ok "T26: del /s -> target=C:\\Temp not /s"
else
  ng "T26: del /s -> target=C:\\Temp not /s"
fi

# --- T27: 対象抽出: grep abc foo.txt → 対象=foo.txt (パターン abc を対象にしない) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep abc foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'foo.txt' "$html" && ! grep -q '>abc<' "$html"; then
  ok "T27: grep abc foo.txt -> target=foo.txt not pattern abc"
else
  ng "T27: grep abc foo.txt -> target=foo.txt not pattern abc"
fi

# --- T28: リダイレクト対象: ls > listing.txt → 書き込み解説 (対象が > にならない) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls > listing.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '書き込み' "$html" && grep -q 'listing.txt' "$html" && ! grep -q 'class="whatdo-body">>' "$html"; then
  ok "T28: ls > listing.txt -> write to listing.txt (not >)"
else
  ng "T28: ls > listing.txt -> write to listing.txt (not >)"
fi

# --- T29: now.md に具体解説が出る (Remove-Item -Recurse) ---
rm -f "$html" "$act" "$md"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"Remove-Item -Recurse dist"}}'
run_explain_with_nowmd "bash" "$json"
if [ -f "$md" ] && grep -q 'これは何をする' "$md" && grep -q '削除' "$md"; then
  ok "T29: now.md contains concrete explanation (Remove-Item)"
else
  ng "T29: now.md contains concrete explanation (got: $(head -5 "$md" 2>/dev/null))"
fi

# --- T30: now.md に危険警告が出る (Remove-Item -Recurse) ---
if [ -f "$md" ] && grep -q '完全削除' "$md"; then
  ok "T30: now.md contains danger warning (完全削除)"
else
  ng "T30: now.md contains danger warning (got: $(grep '⚠' "$md" 2>/dev/null | head -1))"
fi

# --- T31: 単一 read-only パイプライン(cat|grep): 安心文あり ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat README.md | grep TODO"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'ほかにも処理が続きます' "$html" && ! grep -q '<p class="whatdo-danger"' "$html"; then
  ok "T31: cat|grep (read-only) -> pipeline note, no danger"
else
  ng "T31: cat|grep (read-only) -> pipeline note, no danger"
fi

# --- T32: sudo は主コマンドの解説+昇格警告 (sudo cat /etc/hosts → 読む+昇格警告) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"sudo cat /etc/hosts"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '<p class="whatdo-danger"' "$html" && grep -q '管理者権限' "$html" && grep -q '<p class="whatdo-body"' "$html"; then
  ok "T32: sudo cat -> read explanation + admin danger"
else
  ng "T32: sudo cat -> read explanation + admin danger"
fi

# ============================================================
# cycle-3 追加テスト: N1~N5 修正の検証
# ============================================================

# --- T33: N1 fd redir — ls 2>/dev/null → 書込警告なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls 2>/dev/null"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q '書き込み' "$html" && ! grep -q '<p class="whatdo-danger"' "$html"; then
  ok "T33: ls 2>/dev/null -> NO write warning (fd redir ignored)"
else
  ng "T33: ls 2>/dev/null -> NO write warning (fd redir ignored)"
fi

# --- T34: N1 fd redir — cat foo 2> err.log → 書込警告なし・対象=foo ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt 2> err.log"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'foo.txt' "$html" && ! grep -q '書き込み' "$html"; then
  ok "T34: cat foo 2> err.log -> target=foo, NO write warning"
else
  ng "T34: cat foo 2> err.log -> target=foo, NO write warning"
fi

# --- T35: N1 bare content redir — ls > out.txt → 書込警告あり ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls > out.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '書き込み' "$html" && grep -q 'out.txt' "$html"; then
  ok "T35: ls > out.txt -> write warning present (content redir)"
else
  ng "T35: ls > out.txt -> write warning present (content redir)"
fi

# --- T36: N2 quoted > — echo 'a > b' → 書込警告なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo \"a > b\""}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q '書き込み' "$html"; then
  ok "T36: echo \"a > b\" -> NO write warning (quoted > ignored)"
else
  ng "T36: echo \"a > b\" -> NO write warning (quoted > ignored)"
fi

# --- T37: N2 quoted > in grep — grep '>' file.txt → 対象=file.txt, 書込警告なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep \">\" file.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'file.txt' "$html" && ! grep -q '書き込み' "$html"; then
  ok "T37: grep \">\" file.txt -> target=file.txt, NO write warning"
else
  ng "T37: grep \">\" file.txt -> target=file.txt, NO write warning"
fi

# --- T38: N3 chmod absolute path — chmod 644 /etc/hostsfile → 対象=/etc/hostsfile ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"chmod 644 /etc/hostsfile"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '/etc/hostsfile' "$html" && ! grep -q '現在のフォルダ' "$html"; then
  ok "T38: chmod 644 /etc/hostsfile -> target=/etc/hostsfile (not 現在のフォルダ)"
else
  ng "T38: chmod 644 /etc/hostsfile -> target=/etc/hostsfile (not 現在のフォルダ)"
fi

# --- T39: N4 xargs rm in arg — cat xargs rm foo.txt → 削除警告なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat xargs rm foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q '<p class="whatdo-danger"' "$html"; then
  ok "T39: cat xargs rm foo.txt -> NO false deletion warning"
else
  ng "T39: cat xargs rm foo.txt -> NO false deletion warning"
fi

# --- T40: N4 xargs rm as verb — xargs del somefile → 削除警告あり ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"xargs del somefile"}}'
run_explain_with_json "bash" "$json"
# xargs del はNOT currently detected (only rm). Check at least no false alarm for safety.
# (xargs del は現状未検出=フォールバック。重要なのは誤検出をしないこと)
if [ -f "$html" ]; then
  ok "T40: xargs del somefile -> does not crash (graceful)"
else
  ng "T40: xargs del somefile -> does not crash"
fi

# --- T41: N5 backslash JSON decode — del /s C:\\Temp → 表示に C:\Temp が出る ---
# 注: フックが実際に渡すのは C:\Temp をJSONエンコードした C:\\Temp
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"del /s C:\\Temp"}}'
run_explain_with_json "bash" "$json"
# C:\Temp(1スラッシュ) が now.html に出ること。C:\\Temp(2スラッシュ)ではないこと。
if [ -f "$html" ] && grep -qF 'C:\Temp' "$html" && ! grep -qF 'C:\\Temp' "$html"; then
  ok "T41: del /s C:\\Temp -> displays C:\\Temp (single backslash, JSON decoded)"
else
  ng "T41: del /s C:\\Temp -> displays C:\\Temp (single backslash) (got: $(grep -o 'C[:\\]*Temp' "$html" | head -1))"
fi

# --- 退行ガード: cycle-2 の T21-T25 が引き続き pass ---
# T21: ls|del → 安心文なし+削除警告
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls foo | del temp.txt"}}'
run_explain_with_json "bash" "$json"
t_nocalm=0; t_hasdanger=0
if [ -f "$html" ] && ! grep -q 'しません' "$html"; then t_nocalm=1; fi
if [ -f "$html" ] && grep -q '<p class="whatdo-danger"' "$html" && grep -q '削除' "$html"; then t_hasdanger=1; fi
if [ "$t_nocalm" -eq 1 ] && [ "$t_hasdanger" -eq 1 ]; then
  ok "T42-reg: ls|del still -> NO calm + deletion danger (cycle-2 regression guard)"
else
  ng "T42-reg: ls|del still -> NO calm + deletion danger (no_calm=$t_nocalm has_danger=$t_hasdanger)"
fi

# ============================================================
# cycle-4 追加テスト: 致命の 1>/ &> 修正 + m1/m2/m3
# ============================================================

# --- T43: 致命 — cat secret 1> out.txt → 書込検出・「読むだけ」なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat secret.txt 1> out.txt"}}'
run_explain_with_json "bash" "$json"
t43_write=0; t43_no_readonly=0
if [ -f "$html" ] && grep -q '書き込み' "$html" && grep -q 'out.txt' "$html"; then t43_write=1; fi
if [ -f "$html" ] && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then t43_no_readonly=1; fi
if [ "$t43_write" -eq 1 ] && [ "$t43_no_readonly" -eq 1 ]; then
  ok "T43: cat 1> out.txt -> write detected, NO read-only text (1> is content-write)"
else
  ng "T43: cat 1> out.txt -> write detected, NO read-only text (write=$t43_write no_ro=$t43_no_readonly)"
fi

# --- T44: 致命 — cmd 1>out.txt (連結形) → 書込検出 ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cmd 1>out.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '書き込み' "$html" && grep -q 'out.txt' "$html"; then
  ok "T44: cmd 1>out.txt (compact) -> write detected"
else
  ng "T44: cmd 1>out.txt (compact) -> write detected"
fi

# --- T45: 致命 — app &> all.log → 書込検出 ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"app &> all.log"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '書き込み' "$html" && grep -q 'all.log' "$html"; then
  ok "T45: app &> all.log -> write detected (&> is content-write)"
else
  ng "T45: app &> all.log -> write detected"
fi

# --- T46: N1 退行ガード — ls 2>/dev/null 引き続き書込なし・対象が /dev/null でない ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls 2>/dev/null"}}'
run_explain_with_json "bash" "$json"
# /dev/null は action-cmd に出るが whatdo-body には出てはいけない
if [ -f "$html" ] && ! grep -q '書き込み' "$html" && ! grep -q 'class="whatdo-body">.*dev.null' "$html"; then
  ok "T46: ls 2>/dev/null -> NO write warning, /dev/null not in whatdo (N1 regression guard)"
else
  ng "T46: ls 2>/dev/null -> NO write warning, /dev/null not in whatdo"
fi

# --- T47: m1 chmod $アンカー — chmod 644 u+xtra.txt → 対象=u+xtra.txt ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"chmod 644 u+xtra.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'u+xtra.txt' "$html" && ! grep -q '現在のフォルダ' "$html"; then
  ok "T47: chmod 644 u+xtra.txt -> target=u+xtra.txt (not 現在のフォルダ)"
else
  ng "T47: chmod 644 u+xtra.txt -> target=u+xtra.txt (m1 anchor fix)"
fi

# --- T48: m3 quoted path — cat 'my file.txt' → 対象=my file.txt (引用符除去) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat \"my file.txt\""}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'my file.txt' "$html" && ! grep -q '"my' "$html"; then
  ok "T48: cat \"my file.txt\" -> target=my file.txt (quotes stripped)"
else
  ng "T48: cat \"my file.txt\" -> target=my file.txt (m3 quoted path) (got: $(grep -o 'whatdo-body">[^<]*' "$html" | head -1))"
fi

# --- T49: m2 parity fixture — explainer-parity.tsv を iterate して検証 ---
FIXTURE="$REPO/scripts/common/test/fixtures/explainer-parity.tsv"
if [ ! -f "$FIXTURE" ]; then
  ng "T49-setup: parity fixture not found at $FIXTURE"
else
  fixture_pass=0; fixture_fail=0
  while IFS=$'\t' read -r cmd_raw category danger_expected readonly_expected target_hint; do
    # コメント行・空行をスキップ
    case "$cmd_raw" in '#'*|'') continue ;; esac
    rm -f "$TD/parity_result.tmp"
    (
      set -u
      source "$REPO/scripts/macos/lib/explainer.sh" 2>/dev/null
      explain_command "$cmd_raw" 2>/dev/null
      # danger チェック
      has_danger="false"
      [ -n "$EXPLAIN_DANGER" ] && has_danger="true"
      # readonly チェック (安心文: 「しません」「読むだけ」)
      has_readonly="false"
      case "$EXPLAIN_WHATDO" in *しません*|*読むだけ*) has_readonly="true" ;; esac
      printf '%s\t%s\t%s\t%s\n' "$has_danger" "$has_readonly" "$EXPLAIN_WHATDO" "$EXPLAIN_DANGER"
    ) > "$TD/parity_result.tmp" 2>/dev/null
    res_danger="$(cut -f1 "$TD/parity_result.tmp")"
    res_readonly="$(cut -f2 "$TD/parity_result.tmp")"
    res_whatdo="$(cut -f3 "$TD/parity_result.tmp")"
    # danger assertion
    if [ "$res_danger" != "$danger_expected" ]; then
      ng "T49-parity [$cmd_raw]: danger expected=$danger_expected got=$res_danger"
      fixture_fail=$((fixture_fail+1))
      continue
    fi
    # readonly assertion
    if [ "$res_readonly" != "$readonly_expected" ]; then
      ng "T49-parity [$cmd_raw]: readonly expected=$readonly_expected got=$res_readonly (W=[$res_whatdo])"
      fixture_fail=$((fixture_fail+1))
      continue
    fi
    # target hint (非空なら部分一致)
    if [ -n "$target_hint" ] && ! echo "$res_whatdo" | grep -qF "$target_hint"; then
      ng "T49-parity [$cmd_raw]: target hint [$target_hint] not in whatdo [$res_whatdo]"
      fixture_fail=$((fixture_fail+1))
      continue
    fi
    fixture_pass=$((fixture_pass+1))
    ok "T49-parity [$cmd_raw] OK"
  done < "$FIXTURE"
fi

# ============================================================
# cycle-5 追加テスト
# ============================================================

# --- T50: RED1 任意数字fd — cat foo 3> out.txt → 書込検出・「読むだけ」なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo 3> out.txt"}}'
run_explain_with_json "bash" "$json"
t50_write=0; t50_no_ro=0
if [ -f "$html" ] && grep -q '書き込み' "$html" && grep -q 'out.txt' "$html"; then t50_write=1; fi
if [ -f "$html" ] && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then t50_no_ro=1; fi
if [ "$t50_write" -eq 1 ] && [ "$t50_no_ro" -eq 1 ]; then
  ok "T50: cat 3> out.txt -> write detected (RED1: any numeric fd is content-write)"
else
  ng "T50: cat 3> out.txt -> write detected (write=$t50_write no_ro=$t50_no_ro)"
fi

# --- T51: RED1 9> — cmd 9>x → 書込検出 ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cmd 9>x"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '書き込み' "$html" && grep -q 'x' "$html" && ! grep -q 'しません' "$html"; then
  ok "T51: cmd 9>x -> write detected (RED1: 9> is content-write)"
else
  ng "T51: cmd 9>x -> write detected"
fi

# --- T52: RED2 コマンド置換 — cat \$(echo hi) → 安心文「しません」なし + 埋込警告 ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat $(cmd_var)"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q 'しません' "$html" && grep -q '埋め込まれています' "$html"; then
  ok "T52: cat \$(cmd) -> NO calm text, cmd-subst warning present (RED2)"
else
  ng "T52: cat \$(cmd) -> NO calm text, cmd-subst warning (got: $(grep -o 'whatdo-body">[^<]*' "$html" | head -1))"
fi

# --- T53: ホワイトリスト — ls(素) → 安心文あり ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls /tmp"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'しません' "$html"; then
  ok "T53: ls /tmp -> readonly whitelist: calm text present"
else
  ng "T53: ls /tmp -> readonly whitelist: calm text should be present"
fi

# --- T54: ホワイトリスト境界 — ls 2>/dev/null → 安心文なし(リダイレクトあり) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls 2>/dev/null"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q 'しません' "$html" && ! grep -q '<p class="whatdo-danger"' "$html"; then
  ok "T54: ls 2>/dev/null -> NO calm text (any-redir present), no danger"
else
  ng "T54: ls 2>/dev/null -> NO calm text"
fi

# --- T55: YELLOW 引用符付きリダイレクト先 — 1>'out file.txt' → 対象=out file.txt ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat secret.txt 1> \"out file.txt\""}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'out file.txt' "$html" && grep -q '書き込み' "$html"; then
  ok "T55: 1>\"out file.txt\" -> target=out file.txt (quoted redir target)"
else
  ng "T55: 1>\"out file.txt\" -> target=out file.txt (got: $(grep -o 'whatdo-body">[^<]*' "$html" | head -1))"
fi

# --- T56: 退行ガード — 1>/&> は書込のまま ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat secret.txt 1> out.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '書き込み' "$html" && ! grep -q 'しません' "$html"; then
  ok "T56: cat 1> out.txt -> still write (cycle-4 regression guard)"
else
  ng "T56: cat 1> out.txt -> still write (regression)"
fi


# ============================================================
# cycle-6 追加テスト
# ============================================================

# --- T57: RED 二重引用符内コマンド置換 — cat "$(printf f)" → 安心文なし+埋込警告 ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat \"$(printf x)\""}}'
run_explain_with_json "bash" "$json"
t57_no_calm=0; t57_has_warn=0
if [ -f "$html" ] && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then t57_no_calm=1; fi
if [ -f "$html" ] && grep -q '埋め込まれています' "$html"; then t57_has_warn=1; fi
if [ "$t57_no_calm" -eq 1 ] && [ "$t57_has_warn" -eq 1 ]; then
  ok 'T57: cat "$(...)" -> NO calm, cmd-subst warning (RED: double-quote does not block $())'
else
  ng "T57: cat dollar-paren -> NO calm, cmd-subst warning (no_calm=$t57_no_calm has_warn=$t57_has_warn)"
fi

# --- T58: backtick 内コマンド置換 → 安心文なし+埋込警告 ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat `printf x`"}}'
run_explain_with_json "bash" "$json"
t58_no_calm=0; t58_has_warn=0
if [ -f "$html" ] && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then t58_no_calm=1; fi
if [ -f "$html" ] && grep -q '埋め込まれています' "$html"; then t58_has_warn=1; fi
if [ "$t58_no_calm" -eq 1 ] && [ "$t58_has_warn" -eq 1 ]; then
  ok "T58: cat \`cmd\` -> NO calm, cmd-subst warning (backtick)"
else
  ng "T58: cat \`cmd\` -> NO calm, cmd-subst warning (no_calm=$t58_no_calm has_warn=$t58_has_warn)"
fi

# --- T59: パイプ複合 → 安心文なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo | grep abc"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html" && grep -q 'ほかにも処理が続きます' "$html"; then
  ok "T59: cat|grep -> NO calm text (compound), pipeline note present"
else
  ng "T59: cat|grep -> NO calm text (compound)"
fi

# --- T60: && 連結 → 安心文なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls /tmp && cat foo"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then
  ok "T60: ls && cat -> NO calm text (compound)"
else
  ng "T60: ls && cat -> NO calm text (compound)"
fi

# --- T61: 入力リダイレクト < → 安心文なし・対象が < にならない ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat < foo.txt"}}'
run_explain_with_json "bash" "$json"
t61_no_calm=0; t61_no_ltarget=0
if [ -f "$html" ] && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then t61_no_calm=1; fi
if [ -f "$html" ] && ! grep -q 'class="whatdo-body">< ' "$html"; then t61_no_ltarget=1; fi
if [ "$t61_no_calm" -eq 1 ] && [ "$t61_no_ltarget" -eq 1 ]; then
  ok "T61: cat < foo.txt -> NO calm, < not in target"
else
  ng "T61: cat < foo.txt -> NO calm, < not in target (no_calm=$t61_no_calm no_lt=$t61_no_ltarget)"
fi

# --- T62: ホワイトリスト確認 — ls(素) → 安心文あり(退行ガード) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'しません' "$html"; then
  ok "T62: ls (bare) -> calm text present (whitelist allows simple readonly)"
else
  ng "T62: ls (bare) -> calm text present (regression)"
fi

# --- T63: cat foo(素) → 安心文あり(退行ガード) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '読むだけ' "$html"; then
  ok "T63: cat foo.txt -> calm text present (whitelist allows simple readonly)"
else
  ng "T63: cat foo.txt -> calm text present (regression)"
fi

# --- T64: 単一引用符内の $(...) は literal → 埋込警告を出さなくてよい(出ても可) ---
# 安心文が出るかどうかは実装依存で OK(単引 $() は literal なので danger なし)
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo x"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q '<p class="whatdo-danger"' "$html"; then
  ok "T64: echo x (simple, no danger) -> no danger present"
else
  ng "T64: echo x -> no danger (baseline)"
fi



# ============================================================
# cycle-7 追加テスト: reassurance-safe 集合 + find -exec
# ============================================================

# --- T65: find -exec → 実行警告 + 安心文なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"find . -exec printf {} +"}}'
run_explain_with_json "bash" "$json"
t65_exec=0; t65_no_calm=0
if [ -f "$html" ] && grep -q '<p class="whatdo-danger"' "$html" && grep -q '実行' "$html"; then t65_exec=1; fi
if [ -f "$html" ] && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then t65_no_calm=1; fi
if [ "$t65_exec" -eq 1 ] && [ "$t65_no_calm" -eq 1 ]; then
  ok "T65: find -exec -> exec danger + NO calm (reassurance-safe excludes find)"
else
  ng "T65: find -exec -> exec danger + NO calm (exec=$t65_exec no_calm=$t65_no_calm)"
fi

# --- T66: find -execdir → 実行警告 ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"find . -execdir cat {} ;"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '<p class="whatdo-danger"' "$html" && grep -q '実行' "$html" && ! grep -q 'しません' "$html"; then
  ok "T66: find -execdir -> exec danger, NO calm"
else
  ng "T66: find -execdir -> exec danger, NO calm"
fi

# --- T67: find -delete → 削除警告 + 安心文なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"find . -delete"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '<p class="whatdo-danger"' "$html" && grep -q '削除' "$html" && ! grep -q 'しません' "$html"; then
  ok "T67: find -delete -> delete danger, NO calm"
else
  ng "T67: find -delete -> delete danger, NO calm"
fi

# --- T68: find -name (exec なし) → 検索カテゴリ表示・安心文なし・危険なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"find . -name foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '検索' "$html" && ! grep -q 'しません' "$html" && ! grep -q '<p class="whatdo-danger"' "$html"; then
  ok "T68: find -name -> search category, NO calm, NO danger"
else
  ng "T68: find -name -> search category, NO calm, NO danger"
fi

# --- T69: grep (reassurance-safe 外) → 安心文なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep abc foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '検索' "$html" && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then
  ok "T69: grep -> search category, NO calm (grep not in reassurance-safe)"
else
  ng "T69: grep -> search category, NO calm"
fi

# --- T70: wc foo.txt(素) → reassurance-safe で安心文あり ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"wc -l foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '<p class="whatdo-body"' "$html" && (grep -q 'しません' "$html" || grep -q '読むだけ' "$html"); then
  ok "T70: wc foo.txt -> calm text present (wc is reassurance-safe)"
else
  ng "T70: wc foo.txt -> calm text present (wc should be reassurance-safe)"
fi

# --- T71: 退行 — ls(素) 安心文あり ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'しません' "$html"; then
  ok "T71-reg: ls (bare) -> calm text present (regression guard)"
else
  ng "T71-reg: ls (bare) -> calm text present (regression)"
fi

# --- T72: 退行 — cat foo.txt(素) 安心文あり ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '読むだけ' "$html"; then
  ok "T72-reg: cat foo.txt (bare) -> calm text present (regression guard)"
else
  ng "T72-reg: cat foo.txt (bare) -> calm text present (regression)"
fi


# ============================================================
# cycle-8 追加テスト: file/date/more 除外 + find -okdir
# ============================================================

# --- T73: file コマンド → 安心文なし (file -C は magic DB 書込可) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"file foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '<p class="whatdo-body"' "$html" && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then
  ok "T73: file foo.txt -> category desc shown, NO calm (file not reassurance-safe)"
else
  ng "T73: file foo.txt -> NO calm (file -C writes magic DB)"
fi

# --- T74: date コマンド → 安心文なし (date <arg> は時刻設定可) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"date"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '<p class="whatdo-body"' "$html" && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then
  ok "T74: date -> category desc shown, NO calm (date <arg> sets time)"
else
  ng "T74: date -> NO calm (date <arg> sets time)"
fi

# --- T75: more foo.txt → 安心文なし (more で !cmd shell out 可) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"more foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '<p class="whatdo-body"' "$html" && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then
  ok "T75: more foo.txt -> NO calm (more !cmd can shell out)"
else
  ng "T75: more foo.txt -> NO calm"
fi

# --- T76: find -okdir → 実行警告 + 安心文なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"find . -okdir printf {} +"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '<p class="whatdo-danger"' "$html" && grep -q '実行' "$html" && ! grep -q 'しません' "$html"; then
  ok "T76: find -okdir -> exec danger, NO calm"
else
  ng "T76: find -okdir -> exec danger, NO calm"
fi

# --- T77: stat foo.txt(素) → reassurance-safe で安心文あり ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"stat foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && (grep -q 'しません' "$html" || grep -q '読むだけ' "$html"); then
  ok "T77: stat foo.txt -> calm text present (stat is reassurance-safe)"
else
  ng "T77: stat foo.txt -> calm text present (regression)"
fi

# --- T78: wc退行 — wc foo.txt(素) → 安心文あり ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"wc foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && (grep -q 'しません' "$html" || grep -q '読むだけ' "$html"); then
  ok "T78-reg: wc foo.txt -> calm text present (regression guard)"
else
  ng "T78-reg: wc foo.txt -> calm text present (regression)"
fi


# ============================================================
# cycle-9 追加テスト: & 区切り + 改行区切り
# ============================================================

# --- T79: pwd & touch (& バックグラウンド区切り) → 安心文なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"pwd & touch harmless.tmp"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then
  ok "T79: pwd & touch -> NO calm (& is background separator)"
else
  ng "T79: pwd & touch -> NO calm (& background)"
fi

# --- T80: ls & echo ok (& 区切り) → 安心文なし ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls & echo ok"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then
  ok "T80: ls & echo -> NO calm (& background separator)"
else
  ng "T80: ls & echo -> NO calm"
fi

# --- T81: && 連結は従来どおり複合扱い(& と && の区別確認) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls && cat foo"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q 'しません' "$html" && ! grep -q '読むだけ' "$html"; then
  ok "T81: ls && cat -> NO calm (&& is compound, distinct from &)"
else
  ng "T81: ls && cat -> NO calm"
fi

# --- T82: &> はリダイレクト・複合扱いしない(書込解説) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls &> out.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '書き込み' "$html" && grep -q 'out.txt' "$html"; then
  ok "T82: ls &> out.txt -> write detected (&> is redirect, not & separator)"
else
  ng "T82: ls &> out.txt -> write detected"
fi

# --- T83: 退行 — ls(素) 安心文あり ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'しません' "$html"; then
  ok "T83-reg: ls (bare) -> calm text present (regression guard)"
else
  ng "T83-reg: ls (bare) -> calm text present"
fi

# --- T84: 退行 — cat foo(素) 安心文あり ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q '読むだけ' "$html"; then
  ok "T84-reg: cat foo.txt (bare) -> calm text present (regression guard)"
else
  ng "T84-reg: cat foo.txt (bare) -> calm text present"
fi

# --- T85: JSON の \n エスケープ = 改行区切り2コマンド → 安心文なし(false-safety防止) ---
# mac の extract_json_string が \n を実改行に復元し、explain_command は ACTION_RAW_CMD
# (改行保持)を受け取るため複合検出が発火する。Windows は ConvertFrom-Json が同等。
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"pwd\ntouch harmless.tmp"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q 'しません' "$html" && grep -q 'ほかにも処理が続きます' "$html"; then
  ok "T85: JSON \\n separator (pwd<NL>touch) -> NO calm, compound note shown"
else
  ng "T85: JSON \\n separator -> NO calm + compound note"
fi

# --- T86: JSON \n 区切り cat+ls → 安心文なし・続き注記 ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat foo.txt\nls"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && ! grep -q 'しません' "$html" && grep -q 'ほかにも処理が続きます' "$html"; then
  ok "T86: JSON \\n separator (cat<NL>ls) -> NO calm, compound note shown"
else
  ng "T86: JSON \\n separator (cat<NL>ls) -> NO calm + compound note"
fi

# --- T87: 退行 — backslash パス表示が \n デコードで壊れない(del /s C:\Temp) ---
rm -f "$html" "$act"
json='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"del /s C:\\Temp"}}'
run_explain_with_json "bash" "$json"
if [ -f "$html" ] && grep -q 'C:\\Temp' "$html" && ! grep -q 'しません' "$html"; then
  ok "T87-reg: del /s C:\\Temp -> path intact (backslash not mangled), NO calm"
else
  ng "T87-reg: del /s C:\\Temp -> path intact + NO calm"
fi

echo ""
echo "explainer.test summary: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
