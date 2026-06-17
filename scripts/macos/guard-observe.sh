#!/usr/bin/env bash
# guard-observe.sh — catch-all 可視化フック（案A': catch-all observe + per-tool deny）。
#
# 役割（可視化のみ・deny 一切なし）:
#   - PreToolUse / PermissionRequest の matcher "*" から呼ばれ、あらゆる tool を受け取る。
#   - 専用 deny ガード（guard-bash / guard-write / guard-webfetch）が担当する tool
#     {Bash, PowerShell, Write, Edit, MultiEdit, WebFetch} は now.html カードを書かない
#     （専用ガードのカードが本物。observe が上書きすると解説が消えるため）。trace だけ残す。
#   - それ以外の tool（WebSearch / Read / Glob / Grep / Agent / Task / NotebookRead など、
#     および未知の tool）は、tool_name + 安全な短い入力要約のカードを now.html に書く。
#
# 安全方針（重要）:
#   - permissionDecision を「絶対に」出さない（exit 0・JSON 無し）。allow/ask/deny の判断はしない。
#   - 外部サービス（Gemini 等）へ何も送らない。ローカル now.html + 監査ログのみ。
#   - フェイルオープン: どんなエラーでも exit 0。observe はセキュリティ責務を持たないので、
#     ここでエージェントを止めてはいけない（deny ガードだけが fail-closed）。

# フェイルオープン: load_policy_or_fail は fail-closed (exit 2) なので、その前に最小限の
# tool_name 判定だけ済ませ、専用ガード担当 tool なら policy 読み込み自体を行わずに即 exit 0。
# こうすることで observe が policy 不在等で agent を止める経路を作らない。

set -u

# ---- フェイルオープンの保険: 予期せぬシグナルでも 0 で抜ける ----
# 通常終了(EXIT)では明示 exit 0 を使う。中断系シグナルだけ trap で 0 終了に倒す。
trap 'exit 0' INT TERM HUP PIPE

# stdin の hook JSON を一度だけ読む（safety_policy.sh の read_hook_input より前に欲しい）。
_OBSERVE_RAW="$(cat 2>/dev/null || true)"
if [ "${#_OBSERVE_RAW}" -gt 262144 ]; then
  _OBSERVE_RAW="${_OBSERVE_RAW:0:262144}"
fi

# tool_name を雑に抽出（jq 非依存・safety_policy.sh より前なので自前で）。
_observe_extract_tool() {
  local key="$1"
  printf '%s' "$_OBSERVE_RAW" | tr '\n' ' ' \
    | sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/p" \
    | head -n 1
}
_OBSERVE_TOOL="$(_observe_extract_tool "tool_name")"
[ -z "$_OBSERVE_TOOL" ] && _OBSERVE_TOOL="$(_observe_extract_tool "toolName")"
[ -z "$_OBSERVE_TOOL" ] && _OBSERVE_TOOL="$(_observe_extract_tool "name")"

# 専用 deny ガードが now.html カードを所有する tool（observe はカードを書かない）。
case "$_OBSERVE_TOOL" in
  Bash|PowerShell|Write|Edit|MultiEdit|WebFetch)
    # 専用ガードのカードを尊重し、ここでは何もしない（exit 0）。
    # 監査 trace すら policy 読み込みが要るため、ここでは省く（専用ガードが必ず audit する）。
    exit 0
    ;;
esac

# ここから先は「専用ガードが拾わない tool」= 可視化対象。
# explain がカードを書く。失敗しても (trap で) exit 0。
AI_SAFE_MODE="observe"
RAW_INPUT="$_OBSERVE_RAW"   # explainer は RAW_INPUT を参照する
# 重要（フェイルオープン）: observe は deny ガードと違い policy を「必要としない」。
# safety_policy.sh の load_policy_or_fail は fail-closed で exit 2 するため、ここでは絶対に
# 呼ばない。代わりに policy 由来変数を空で初期化しておく（redact_text/audit_log は空パターンを
# 許容する）。こうすれば policy 不在・破損でも可視化カードは書け、かつ agent を止めない。
(
  set +e
  here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  . "$here/lib/safety_policy.sh" 2>/dev/null || exit 0
  # policy をロードせず、explain/audit_log が参照する変数だけ空で用意する（fail-open）。
  RAW_INPUT="$_OBSERVE_RAW"
  SECRET_PATTERNS=""; DANGEROUS_PATTERNS=""; PROTECTED_PATH_PATTERNS=""
  BLOCKED_DOMAINS=""; ALLOWED_DOMAINS=""; _POLICY_LOADED=1
  . "$here/lib/explainer.sh" 2>/dev/null || exit 0
  MODE="observe"
  explain 2>/dev/null || true
  # 監査 trace（best-effort）。decision="observe" は deny でも allow でもない可視化マーカー。
  audit_log "observe" "tool=${_OBSERVE_TOOL:-unknown}" 2>/dev/null || true
  exit 0
) 2>/dev/null || true

exit 0
