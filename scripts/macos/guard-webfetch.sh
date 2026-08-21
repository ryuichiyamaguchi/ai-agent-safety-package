#!/usr/bin/env bash
set -u
AI_SAFE_MODE="webfetch"
. "$(dirname "$0")/lib/safety_policy.sh"
read_hook_input
. "$(dirname "$0")/lib/explainer.sh"
explain
has_sensitive_text && block "sensitive pattern in WebFetch input"
url="$(extract_url)"
[ -z "$url" ] && block "WebFetch URL is missing"
case "$url" in
  http://*|https://*) ;;
  *) block "blocked URL scheme" ;;
esac
host="$(printf '%s' "$url" | sed -E 's#^https?://([^/:?#]+).*#\1#' | tr '[:upper:]' '[:lower:]')"
printf '%s' "$host" | grep -E -q '^(localhost|127[.]|10[.]|172[.](1[6-9]|2[0-9]|3[0-1])[.]|192[.]168[.]|::1)' && block "local/private network URL is blocked"
# 拒否リスト方式（2026-08-21〜）: blockedDomains に載っている宛先だけ止め、それ以外は通す。
# 先に blocked を明示的に見るのは、止まった理由を「拒否リストに載っている」と正しく出すため
# （Windows の guard-webfetch.ps1 と同じ順序）。判定そのものは is_allowed_domain と同じ。
is_blocked_domain "$host" && block "domain is block-listed: $host"
is_allowed_domain "$host" || block "domain is not allow-listed: $host"
allow "domain allowed: $host"
