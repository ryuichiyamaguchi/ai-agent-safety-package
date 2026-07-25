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

codex_entry="$START_DIR/2_セーフCodexを起動.command"
if grep -q 'launch-integrated.sh' "$codex_entry" &&
   grep -q '"$WORKSPACE" codex standard' "$codex_entry" &&
   ! grep -q 'TARGET=.*launch-codex-safe' "$codex_entry"; then
  ok "legacy Codex start button routes through integrated standard mode"
else
  ng "legacy Codex start button bypasses integrated launcher"
fi

claude_entry="$START_DIR/3_セーフClaudeを起動.command"
if grep -q 'launch-integrated.sh' "$claude_entry" &&
   grep -q '"$WORKSPACE" claude standard' "$claude_entry" &&
   ! grep -q 'TARGET=.*launch-claude-safe' "$claude_entry"; then
  ok "legacy Claude start button routes through integrated standard mode"
else
  ng "legacy Claude start button bypasses integrated launcher"
fi

if grep -q 'launch-integrated.sh' "$REPO/scripts/macos/install-one-click.command" &&
   ! grep -q 'echo .*launch-codex-safe.sh' "$REPO/scripts/macos/install-one-click.command"; then
  ok "Mac installer completion guidance points to integrated launcher"
else
  ng "Mac installer completion guidance still points to a legacy launcher"
fi

if grep -q 'launch-integrated.sh.*codex standard' "$REPO/docs/00_クイックスタート.md" &&
   grep -q '統合版の標準モード' "$REPO/スタート.html"; then
  ok "quick start and onboarding UI describe the integrated entry point"
else
  ng "user-facing guidance does not consistently describe the integrated entry point"
fi

printf '%s\n' "integrated-convenience: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
