#!/usr/bin/env bash
set -u
AI_SAFE_MODE="write"
. "$(dirname "$0")/lib/safety_policy.sh"
read_hook_input
. "$(dirname "$0")/lib/explainer.sh"
explain
has_sensitive_text && block "sensitive pattern in generated file"
has_protected_path && block "protected path referenced in generated file"
has_generated_code_risk && block "generated code contains blocked read or exfil pattern"
has_dangerous_command && block "generated content embeds dangerous command"

# ワークスペース外への書き込みは「即ブロック」ではなく「人間に確認 (ask)」へ。
# 秘密・保護パス・危険コマンド生成は上で既に deny 済みなので、ここに来る外部書き込みは
# 「安全だがワークスペースの外」= 承認を挟めば許してよいもの。外部検知を誤って ask し
# 損ねても、危険物は上の deny 群が止めるため外部検知の厳密性は安全上クリティカルでない。
# 書き込み対象キーは Windows Get-WriteTarget と同順・同集合（file_path/path/target_path/
# notebook_path）。file_path 以外（NotebookEdit の notebook_path 等）でも外部書き込みを
# 検知するため先頭の非空を採る。
_wt="$(_extract_json_field "file_path")"
[ -z "$_wt" ] && _wt="$(_extract_json_field "path")"
[ -z "$_wt" ] && _wt="$(_extract_json_field "target_path")"
[ -z "$_wt" ] && _wt="$(_extract_json_field "notebook_path")"
_wc="$(_extract_json_field "cwd")"
# cwd 末尾のスラッシュを正規化（ルート "/" は除く）。未正規化だと "$_wc"/* の "//" で
# 内部パスがマッチ漏れし、内部書き込みが誤って ask になる。
[ "$_wc" != "/" ] && _wc="${_wc%/}"
if [ -n "$_wt" ]; then
  case "$_wt" in
    ../*|*/../*|*/..)
      ask "ワークスペース外への書き込みです（${_wt}）。許可しますか？" ;;
    /*)
      # 絶対パス: セッションの cwd（=ワークスペース）配下でなければ外部とみなす。
      if [ -n "$_wc" ] && { [ "$_wt" = "$_wc" ] || case "$_wt" in "$_wc"/*) true ;; *) false ;; esac; }; then
        : # workspace 内 → 通常許可へ
      else
        ask "ワークスペース外への書き込みです（${_wt}）。許可しますか？"
      fi ;;
  esac
fi
allow "write passed policy"
