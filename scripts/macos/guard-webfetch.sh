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
is_allowed_domain "$host" || block "domain is not allow-listed: $host"
allow "domain allowed: $host"
