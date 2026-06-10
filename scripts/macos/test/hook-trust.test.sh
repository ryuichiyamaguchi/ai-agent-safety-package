#!/usr/bin/env bash
# hook-trust.test.sh — launch-codex-safe.sh が codex 0.135+ の「未信頼フックは
# 黙ってスキップ」仕様に対し、同梱 guard フックの trusted_hash を safe.config.toml の
# [hooks.state] に自動注入することを検証する。これが無いと受講者が /hooks を手動で
# 信頼するまで guard が一切発火せず、見守りモニターも無反応になる。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCH="$HERE/../launch-codex-safe.sh"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
ng()  { echo "FAIL $1"; fail=$((fail+1)); }

# 最小 workspace を手組みし、HOME を一時ディレクトリへ差し替えて
# launcher の CODEX_HOME ($HOME/.codex-safe) を隔離する(実 HOME を汚さない)。
TMPHOME="$(mktemp -d)"
WSROOT="$(mktemp -d)"; WS="$WSROOT/ws"
mkdir -p "$WS/.ai-safety/policy" "$WS/.codex"
echo '{}' > "$WS/.ai-safety/policy/safety-policy.json"
printf 'sandbox_mode = "workspace-write"\n' > "$WS/.codex/config.toml"
printf 'sandbox_mode = "workspace-write"\n' > "$WS/.codex/safe.config.toml"
echo '{"hooks":{}}' > "$WS/.codex/hooks.json"
WS_REAL="$(cd "$WS" && pwd)"
SP="$TMPHOME/.codex-safe/safe.config.toml"

HOME="$TMPHOME" AI_SAFE_DRY_RUN=1 bash "$LAUNCH" "$WS" >/dev/null 2>&1 || true

# 1) 5 つの guard フック (PreToolUse×3 + PostToolUse×1 + UserPromptSubmit×1) が注入される
n=$(grep -c "trusted_hash" "$SP" 2>/dev/null || true); n=${n:-0}
[ "$n" -eq 5 ] && ok "5 hook trust entries injected" || ng "5 hook trust entries injected (got $n)"

# 2) キーがその workspace の hooks.json 絶対パスで始まる (codex の --cd と一致する形)
grep -Fq "$WS_REAL/.codex/hooks.json:pre_tool_use:0:0" "$SP" 2>/dev/null \
  && ok "key uses workspace hooks.json abs path" || ng "key uses workspace hooks.json abs path"

# 3) 実機採取した既知ハッシュが含まれる (guard-bash / guard-prompt)
grep -Fq "8e3477c0afc198cec87895c92defafa4d27efa05d0913c330a82caeaa8899028" "$SP" 2>/dev/null \
  && ok "guard-bash trusted_hash present" || ng "guard-bash trusted_hash present"
grep -Fq "b5eaf03ab2de6207c7bbef7d2f96b5174caf8878eede9d009508850cb8381c7c" "$SP" 2>/dev/null \
  && ok "user_prompt_submit trusted_hash present" || ng "user_prompt_submit trusted_hash present"

# 4) 回帰: hooks.json が無ければ注入しない (config を壊さない・フェイルセーフ)
rm -f "$WS/.codex/hooks.json" "$SP"
HOME="$TMPHOME" AI_SAFE_DRY_RUN=1 bash "$LAUNCH" "$WS" >/dev/null 2>&1 || true
n2=$(grep -c "trusted_hash" "$SP" 2>/dev/null || true); n2=${n2:-0}
[ "$n2" -eq 0 ] && ok "no injection without hooks.json" || ng "no injection without hooks.json (got $n2)"

rm -rf "$TMPHOME" "$WSROOT"
echo "hook-trust.test summary: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
