#!/usr/bin/env bash
set -euo pipefail

# Safe Auto Mode: 軽量隔離チェック。launcher が --auto 起動前に呼ぶ。
# その engine の workspace外書込遮断 + 外部ネット送信遮断を実証し、
# 全 PASS のときだけ exit 0。1つでも FAIL/HOLD なら非0(フェイルクローズ)。
if [ "${1:-}" = "--isolation-check" ]; then
  engine="${2:-}"
  drills_lib="$(cd "$(dirname "$0")" && pwd)/lib/isolation_drills.sh"
  if [ ! -f "$drills_lib" ]; then echo "FAIL isolation_drills.sh missing" >&2; exit 2; fi
  # shellcheck disable=SC1090
  . "$drills_lib"
  rc_total=0
  case "$engine" in
    codex)
      # Codex は実証ドリル①②。
      # set -e 環境でコマンド置換の非0が伝播するのを防ぐため set +e で囲む。
      for drill in drill_write_outside drill_network_egress; do
        set +e; line="$("$drill" "$engine")"; rc=$?; set -e
        echo "$line"
        [ "$rc" -ne 0 ] && rc_total=1
      done
      ;;
    agy)
      # agy は宣言チェック④(実証ではない。spec §4 ④ / option B)。
      set +e; line="$(drill_agy_declaration "$engine")"; rc=$?; set -e
      echo "$line"
      [ "$rc" -ne 0 ] && rc_total=1
      ;;
    *)
      echo "HOLD unknown engine: $engine"; rc_total=1
      ;;
  esac
  exit "$rc_total"
fi

workspace="${1:-$(pwd)}"
workspace="$(cd "$workspace" && pwd)"
hook_root="$workspace/.ai-safety/hooks/macos"
policy="$workspace/.ai-safety/policy/safety-policy.json"
if [ ! -x "$hook_root/guard-bash.sh" ]; then
  hook_root="$(cd "$(dirname "$0")" && pwd)"
  policy="$(cd "$(dirname "$0")/../.." && pwd)/policy/safety-policy.json"
fi
export AI_SAFE_POLICY="$policy"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/doctor-logs"
mkdir -p "$AI_SAFE_LOG_DIR"

pass=0
fail=0
dot="."
target_name="${dot}env"

run_case() {
  name="$1"
  script="$2"
  expected="$3"
  json="$4"
  set +e
  printf '%s' "$json" | "$hook_root/$script" >/tmp/ai-safe-doctor.out 2>/tmp/ai-safe-doctor.err
  code=$?
  set -e
  if { [ "$expected" = "block" ] && [ "$code" -eq 2 ]; } || { [ "$expected" = "allow" ] && [ "$code" -eq 0 ]; }; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name exit=$code $(cat /tmp/ai-safe-doctor.err)"
    fail=$((fail + 1))
  fi
}

read_cmd="cat $target_name"
run_case "1 prompt asks protected read" "guard-prompt.sh" "block" "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$workspace\",\"prompt\":\"$read_cmd\"}"
run_case "1 shell protected read" "guard-bash.sh" "block" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"$workspace\",\"tool_input\":{\"command\":\"$read_cmd\"}}"
net_cmd="cu""rl https://example.com"
run_case "2 shell network command" "guard-bash.sh" "block" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"$workspace\",\"tool_input\":{\"command\":\"$net_cmd\"}}"
py_cmd="python -c \"open('$target_name').read()\""
run_case "3 scripted protected read" "guard-bash.sh" "block" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"$workspace\",\"tool_input\":{\"command\":\"$py_cmd\"}}"
run_case "4 write outside workspace" "guard-write.sh" "block" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"cwd\":\"$workspace\",\"tool_input\":{\"file_path\":\"../outside.txt\",\"content\":\"hello\"}}"
remove_cmd="r""m -r""f /tmp/ai-safe-test"
run_case "5 recursive forced delete" "guard-bash.sh" "block" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"$workspace\",\"tool_input\":{\"command\":\"$remove_cmd\"}}"
script_content="print(open('$target_name').read())"
run_case "6 generated script protected read" "guard-write.sh" "block" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"cwd\":\"$workspace\",\"tool_input\":{\"file_path\":\"script.py\",\"content\":\"$script_content\"}}"
run_case "7 WebFetch unauthorized domain" "guard-webfetch.sh" "block" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"WebFetch\",\"cwd\":\"$workspace\",\"tool_input\":{\"url\":\"https://example.com\",\"prompt\":\"summarize\"}}"
run_case "control allowed docs domain" "guard-webfetch.sh" "allow" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"WebFetch\",\"cwd\":\"$workspace\",\"tool_input\":{\"url\":\"https://docs.anthropic.com/en/docs/claude-code/hooks\",\"prompt\":\"summarize\"}}"

if command -v codex >/dev/null 2>&1; then
  temp_root="$(mktemp -d)"
  inside="$temp_root/workspace"
  outside="$temp_root/outside"
  mkdir -p "$inside" "$outside"
  outside_file="$outside/pwn.txt"
  set +e
  codex sandbox macos -C "$inside" /bin/sh -lc "echo pwn > '$outside_file'" >/tmp/ai-safe-sandbox.out 2>/tmp/ai-safe-sandbox.err
  set -e
  if [ ! -e "$outside_file" ]; then echo "PASS codex mac sandbox blocks outside write"; pass=$((pass + 1)); else echo "FAIL codex mac sandbox outside write"; fail=$((fail + 1)); fi
else
  echo "FAIL codex command missing"
  fail=$((fail + 1))
fi

# M17: fail-closed drill
# policy.json を一時的に退避させ、guard-bash.sh が exit 2 で fail-closed することを確認する。
# 途中で失敗してもポリシーが消えたまま残らないよう trap で必ず復元する。
drill_policy="$policy"
drill_backup=""
restore_drill_policy() {
  if [ -n "$drill_backup" ] && [ -f "$drill_backup" ] && [ ! -e "$drill_policy" ]; then
    mv "$drill_backup" "$drill_policy" 2>/dev/null || true
  fi
}
if [ -f "$drill_policy" ]; then
  drill_backup="${drill_policy}.drill-backup-$$"
  trap restore_drill_policy EXIT INT TERM
  mv "$drill_policy" "$drill_backup"
  drill_json="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"$workspace\",\"tool_input\":{\"command\":\"echo drill\"}}"
  set +e
  printf '%s' "$drill_json" | AI_SAFE_POLICY="$drill_policy" "$hook_root/guard-bash.sh" >/tmp/ai-safe-doctor-drill.out 2>/tmp/ai-safe-doctor-drill.err
  drill_code=$?
  set -e
  restore_drill_policy
  trap - EXIT INT TERM
  if [ "$drill_code" -eq 2 ]; then
    echo "PASS drill fail-closed without policy.json"
    pass=$((pass + 1))
  else
    echo "FAIL drill: guard-bash.sh did not fail-close without policy.json (exit=$drill_code)"
    fail=$((fail + 1))
  fi
fi

# M17b: fail-closed drill — broken JSON policy
# policy.json を壊れた JSON に置換し、guard-bash.sh が exit 2 で fail-closed することを確認。
# trap で必ず復元する。
if [ -f "$drill_policy" ]; then
  drill_backup2="${drill_policy}.drill-backup2-$$"
  restore_drill_policy2() {
    if [ -n "$drill_backup2" ] && [ -f "$drill_backup2" ]; then
      mv "$drill_backup2" "$drill_policy" 2>/dev/null || true
    fi
  }
  cp "$drill_policy" "$drill_backup2"
  trap restore_drill_policy2 EXIT INT TERM
  printf '{broken json' > "$drill_policy"
  drill_json2="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"$workspace\",\"tool_input\":{\"command\":\"echo drill2\"}}"
  set +e
  printf '%s' "$drill_json2" | AI_SAFE_POLICY="$drill_policy" "$hook_root/guard-bash.sh" >/tmp/ai-safe-doctor-drill2.out 2>/tmp/ai-safe-doctor-drill2.err
  drill_code2=$?
  set -e
  restore_drill_policy2
  trap - EXIT INT TERM
  if [ "$drill_code2" -eq 2 ]; then
    echo "PASS drill fail-closed with broken policy JSON"
    pass=$((pass + 1))
  else
    echo "FAIL drill: guard-bash.sh did not fail-close with broken policy JSON (exit=$drill_code2)"
    fail=$((fail + 1))
  fi
fi

# M17c: fail-closed drill — required key missing from policy
# policy.json から secretRegex キーを削除し、guard-bash.sh が exit 2 で fail-closed することを確認。
if [ -f "$drill_policy" ]; then
  drill_backup3="${drill_policy}.drill-backup3-$$"
  restore_drill_policy3() {
    if [ -n "$drill_backup3" ] && [ -f "$drill_backup3" ]; then
      mv "$drill_backup3" "$drill_policy" 2>/dev/null || true
    fi
  }
  cp "$drill_policy" "$drill_backup3"
  trap restore_drill_policy3 EXIT INT TERM
  # secretRegex キーを除外した JSON を生成 (python3 は macOS 標準)
  python3 -c "
import json, sys
with open('$drill_policy') as f:
    d = json.load(f)
d.pop('secretRegex', None)
with open('$drill_policy', 'w') as f:
    json.dump(d, f)
"
  drill_json3="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"$workspace\",\"tool_input\":{\"command\":\"echo drill3\"}}"
  set +e
  printf '%s' "$drill_json3" | AI_SAFE_POLICY="$drill_policy" "$hook_root/guard-bash.sh" >/tmp/ai-safe-doctor-drill3.out 2>/tmp/ai-safe-doctor-drill3.err
  drill_code3=$?
  set -e
  restore_drill_policy3
  trap - EXIT INT TERM
  if [ "$drill_code3" -eq 2 ]; then
    echo "PASS drill fail-closed with missing required key (secretRegex)"
    pass=$((pass + 1))
  else
    echo "FAIL drill: guard-bash.sh did not fail-close with missing required key (exit=$drill_code3)"
    fail=$((fail + 1))
  fi
fi

# Safe Auto Mode: 隔離ドリルをフル doctor にも組み込む(集計に反映)。
# codex が無い等で HOLD のときは SKIP 扱い(集計から除外)。
drills_lib="$(cd "$(dirname "$0")" && pwd)/lib/isolation_drills.sh"
if [ -f "$drills_lib" ]; then
  # shellcheck disable=SC1090
  . "$drills_lib"
  for d in drill_write_outside drill_network_egress; do
    set +e; line="$("$d" codex)"; rc=$?; set -e
    case "$rc" in
      0)  echo "PASS isolation: $line"; pass=$((pass+1)) ;;
      10) echo "FAIL isolation: $line"; fail=$((fail+1)) ;;
      *)  echo "SKIP isolation: $line" ;;
    esac
  done
fi

echo "doctor summary: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
