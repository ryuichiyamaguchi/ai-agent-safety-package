#!/usr/bin/env bash
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
GUARD="$REPO/scripts/macos/guard-bash.sh"
POLICY="$REPO/policy/safety-policy.json"
START_DIR="$REPO/workspace-template/スタート"
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

run_guard() {
  local command="$1" input="$TD/input.json"
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$command" > "$input"
  AI_SAFE_POLICY="$POLICY" AI_SAFE_LOG_DIR="$TD/logs" bash "$GUARD" < "$input" >"$TD/out" 2>"$TD/err"
  return $?
}

run_guard "rm -rf node_modules"
rc=$?
if [ "$rc" -eq 0 ] && grep -q '"permissionDecision":"ask"' "$TD/out"; then
  ok "generated dependency cleanup asks once instead of hard blocking"
else
  ng "generated dependency cleanup should ask (rc=$rc)"
fi

run_guard "npm test"
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'permissionDecision' "$TD/out"; then
  ok "routine test command remains automatic"
else
  ng "routine test command should stay automatic (rc=$rc)"
fi

run_guard "curl http://127.0.0.1:3000/health"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "local development health check remains automatic"
else
  ng "local development health check should stay automatic (rc=$rc)"
fi

# v1.18.0: 個別のセーフ起動ボタン（2_セーフCodex / 3_セーフClaude）は「4_AIを起動する」に
# 集約され、ボタンはメニューの正本（launch-integrated.sh の menu モード）へ委譲する。
start_entry="$START_DIR/4_AIを起動する.command"
if grep -q 'launch-integrated.sh' "$start_entry" &&
   grep -q '"$WORKSPACE" menu standard' "$start_entry" &&
   ! grep -q 'TARGET=.*launch-codex-safe' "$start_entry" &&
   ! grep -q 'TARGET=.*launch-claude-safe' "$start_entry"; then
  ok "start button routes through integrated launcher menu"
else
  ng "start button bypasses integrated launcher menu"
fi

if grep -q 'agent="codex"; profile="standard"' "$REPO/scripts/macos/launch-integrated.sh" &&
   grep -q 'agent="claude"; profile="standard"' "$REPO/scripts/macos/launch-integrated.sh"; then
  ok "integrated menu maps Codex / Claude to standard mode"
else
  ng "integrated menu lost the Codex / Claude standard mappings"
fi

if grep -q 'launch-integrated.sh' "$REPO/scripts/macos/install-one-click.command" &&
   ! grep -q 'echo .*launch-codex-safe.sh' "$REPO/scripts/macos/install-one-click.command"; then
  ok "Mac installer completion guidance points to integrated launcher"
else
  ng "Mac installer completion guidance still points to a legacy launcher"
fi

if grep -q 'launch-integrated.sh.*codex standard' "$REPO/docs/00_クイックスタート.md" &&
   grep -q '4_AIを起動する' "$REPO/スタート.html"; then
  ok "quick start and onboarding UI describe the integrated entry point"
else
  ng "user-facing guidance does not consistently describe the integrated entry point"
fi

printf '%s\n' "integrated-convenience: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
