#!/usr/bin/env bash
set -u
AI_SAFE_MODE="post-output"
. "$(dirname "$0")/lib/safety_policy.sh"
read_hook_input
. "$(dirname "$0")/lib/explainer.sh"
# 注: post-output はカードを書かない。書くと、ターン終了の Stop イベントで直前の
# コマンドカードを汎用カード(「AI の出力を確認しています」)で上書きし、シェルコマンドが
# モニターに残らなくなる。検査(下の block/allow)は維持。
# 出力側は outputSecretRegex（本物のキー書式のみ。Generic sensitive assignment は除外）で
# 検査する。汎用代入パターンで技術出力全体が誤ブロックされる over-blocking を回避する。
# 入力側(guard-bash/guard-write の has_sensitive_text)は secretRegex 全体のまま不変。
has_sensitive_output_text && block "sensitive pattern in tool or AI output"

# 回答モニター用のスナップショット保存。PostToolUse のツール出力は helper 側で除外し、
# Stop / AfterModel / AfterAgent など、回答本文を取れるイベントだけ latest-answer.json に残す。
# 保存失敗・node 不在は安全判定に影響させない。
write_answer_snapshot() {
  local node_bin helper common_dir
  node_bin="$(command -v node 2>/dev/null || true)"
  [ -n "$node_bin" ] || return 0
  common_dir="$(cd "$(dirname "$0")/../common" 2>/dev/null && pwd)"
  helper="$common_dir/answer-snapshot.js"
  [ -r "$helper" ] || return 0
  printf '%s' "$RAW_INPUT" | "$node_bin" "$helper" >/dev/null 2>&1 || true
}
write_answer_snapshot

allow "output passed policy"
