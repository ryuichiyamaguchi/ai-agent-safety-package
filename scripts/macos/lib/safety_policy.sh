#!/usr/bin/env bash
# safety_policy.sh — Mac runtime policy loader
# SSOT: policy/safety-policy.json (parsed via /usr/bin/plutil, no jq required)
# Fail-closed: any policy load failure causes exit 2 before guard logic runs.
set -u

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
_PLUTIL=/usr/bin/plutil
_POLICY_REQUIRED_KEYS="secretRegex dangerousCommandRegex protectedPathRegex blockedDomains allowedDomains packageVersion"

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
MODE="${AI_SAFE_MODE:-unknown}"
RAW_INPUT=""

# Policy-derived variables (populated by load_policy_or_fail)
SECRET_PATTERNS=""
DANGEROUS_PATTERNS=""
PROTECTED_PATH_PATTERNS=""
BLOCKED_DOMAINS=""
ALLOWED_DOMAINS=""
_POLICY_LOADED=0

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_policy_path() {
  if [ -n "${AI_SAFE_POLICY:-}" ]; then
    printf '%s' "$AI_SAFE_POLICY"
  else
    # Fallback: resolve relative to this script's location
    printf '%s' "$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)/policy/safety-policy.json"
  fi
}

_cache_dir() {
  if [ -n "${AI_SAFE_LOG_DIR:-}" ]; then
    # Place cache alongside logs: …/logs/../cache → …/cache
    printf '%s' "$(dirname "$AI_SAFE_LOG_DIR")/cache"
  else
    printf '%s' "$HOME/.ai-safety/cache"
  fi
}

# Extract a value from the policy file via plutil.
# Usage: _plutil_extract <key> <policy_path>
# Returns the raw string on stdout; exits 1 on failure (caller must handle).
_plutil_extract() {
  local key="$1"
  local path="$2"
  "$_PLUTIL" -extract "$key" raw -o - "$path" 2>/dev/null
}

# Build a newline-delimited list of .pattern fields from a secretRegex-style
# array.  Uses the array length returned by `plutil -extract <key> raw`.
_extract_pattern_list() {
  local key="$1"
  local path="$2"
  local count
  count="$("$_PLUTIL" -extract "$key" raw -o - "$path" 2>/dev/null)" || return 1
  local i=0
  local out=""
  while [ "$i" -lt "$count" ]; do
    local pat
    pat="$("$_PLUTIL" -extract "${key}.${i}.pattern" raw -o - "$path" 2>/dev/null)" || return 1
    if [ -n "$out" ]; then
      out="${out}
${pat}"
    else
      out="$pat"
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# Build a newline-delimited list from a plain string array.
_extract_string_list() {
  local key="$1"
  local path="$2"
  local count
  count="$("$_PLUTIL" -extract "$key" raw -o - "$path" 2>/dev/null)" || return 1
  local i=0
  local out=""
  while [ "$i" -lt "$count" ]; do
    local val
    val="$("$_PLUTIL" -extract "${key}.${i}" raw -o - "$path" 2>/dev/null)" || return 1
    if [ -n "$out" ]; then
      out="${out}
${val}"
    else
      out="$val"
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# Compute a stable cache key: sha256 of (mtime + file size).
# Pure bash + stat; no python3/openssl required for the key itself.
_policy_cache_key() {
  local path="$1"
  local mtime size
  mtime="$(stat -f '%m' "$path" 2>/dev/null)" || mtime="0"
  size="$(stat -f '%z' "$path" 2>/dev/null)" || size="0"
  printf '%s' "${mtime}-${size}" | shasum -a 256 | cut -c1-16
}

# ---------------------------------------------------------------------------
# load_policy_or_fail
# ---------------------------------------------------------------------------
# Loads policy/safety-policy.json into shell variables.
# On any failure: logs to stderr and calls exit 2 (fail-closed).
# On success: sets _POLICY_LOADED=1 and all pattern variables.
# Uses a mtime+size keyed cache under _cache_dir() to avoid repeated parse.
load_policy_or_fail() {
  # Guard: already loaded (e.g. sourced by multiple guard scripts in same shell)
  [ "$_POLICY_LOADED" -eq 1 ] && return 0

  # 1. plutil must exist
  if [ ! -x "$_PLUTIL" ]; then
    printf 'AI Safety Guard FATAL: /usr/bin/plutil not found — cannot parse policy\n' >&2
    exit 2
  fi

  # 2. Resolve policy path
  local policy
  policy="$(_policy_path)"

  # 3. Policy file must exist and be readable
  if [ ! -f "$policy" ]; then
    printf 'AI Safety Guard FATAL: policy file not found: %s\n' "$policy" >&2
    exit 2
  fi
  if [ ! -r "$policy" ]; then
    printf 'AI Safety Guard FATAL: policy file not readable: %s\n' "$policy" >&2
    exit 2
  fi

  # 4. Validate JSON by extracting packageVersion (plutil exits 1 on parse error)
  local pkg_ver
  if ! pkg_ver="$("$_PLUTIL" -extract packageVersion raw -o - "$policy" 2>/dev/null)"; then
    printf 'AI Safety Guard FATAL: policy file is invalid or missing required key "packageVersion": %s\n' "$policy" >&2
    exit 2
  fi

  # 5. Check all required keys exist
  local key
  for key in $_POLICY_REQUIRED_KEYS; do
    if ! "$_PLUTIL" -extract "$key" raw -o - "$policy" >/dev/null 2>&1; then
      printf 'AI Safety Guard FATAL: policy missing required key "%s": %s\n' "$key" "$policy" >&2
      exit 2
    fi
  done

  # 6. Try cache
  local cache_dir cache_key cache_file
  cache_dir="$(_cache_dir)"
  cache_key="$(_policy_cache_key "$policy")"
  cache_file="${cache_dir}/policy-${cache_key}.cache"

  if [ -f "$cache_file" ] && [ -r "$cache_file" ]; then
    # shellcheck disable=SC1090
    . "$cache_file"
    _POLICY_LOADED=1
    return 0
  fi

  # 7. Parse policy via plutil
  local secret_patterns dangerous_patterns protected_patterns blocked_domains allowed_domains

  if ! secret_patterns="$(_extract_pattern_list "secretRegex" "$policy")"; then
    printf 'AI Safety Guard FATAL: failed to parse secretRegex from policy\n' >&2
    exit 2
  fi
  if ! dangerous_patterns="$(_extract_string_list "dangerousCommandRegex" "$policy")"; then
    printf 'AI Safety Guard FATAL: failed to parse dangerousCommandRegex from policy\n' >&2
    exit 2
  fi
  if ! protected_patterns="$(_extract_string_list "protectedPathRegex" "$policy")"; then
    printf 'AI Safety Guard FATAL: failed to parse protectedPathRegex from policy\n' >&2
    exit 2
  fi
  if ! blocked_domains="$(_extract_string_list "blockedDomains" "$policy")"; then
    printf 'AI Safety Guard FATAL: failed to parse blockedDomains from policy\n' >&2
    exit 2
  fi
  if ! allowed_domains="$(_extract_string_list "allowedDomains" "$policy")"; then
    printf 'AI Safety Guard FATAL: failed to parse allowedDomains from policy\n' >&2
    exit 2
  fi

  # 8. Write cache (best-effort; failure must NOT block execution — fall through)
  local prev_umask
  prev_umask="$(umask)"
  umask 077
  if mkdir -p "$cache_dir" 2>/dev/null; then
    # Write to temp then rename for atomicity
    local tmp_cache
    tmp_cache="${cache_file}.tmp.$$"
    {
      # Use printf %q to safely quote multiline strings for re-sourcing
      printf 'SECRET_PATTERNS=%q\n' "$secret_patterns"
      printf 'DANGEROUS_PATTERNS=%q\n' "$dangerous_patterns"
      printf 'PROTECTED_PATH_PATTERNS=%q\n' "$protected_patterns"
      printf 'BLOCKED_DOMAINS=%q\n' "$blocked_domains"
      printf 'ALLOWED_DOMAINS=%q\n' "$allowed_domains"
      printf '_POLICY_LOADED=1\n'
    } > "$tmp_cache" 2>/dev/null && mv "$tmp_cache" "$cache_file" 2>/dev/null || rm -f "$tmp_cache" 2>/dev/null || true
  fi
  umask "$prev_umask"

  # 9. Assign to global variables
  SECRET_PATTERNS="$secret_patterns"
  DANGEROUS_PATTERNS="$dangerous_patterns"
  PROTECTED_PATH_PATTERNS="$protected_patterns"
  BLOCKED_DOMAINS="$blocked_domains"
  ALLOWED_DOMAINS="$allowed_domains"
  _POLICY_LOADED=1
}

# ---------------------------------------------------------------------------
# Utility functions (called by guard scripts)
# ---------------------------------------------------------------------------

read_hook_input() {
  RAW_INPUT="$(cat)"
  if [ "${#RAW_INPUT}" -gt 262144 ]; then
    RAW_INPUT="${RAW_INPUT:0:262144}"
  fi
  # Ensure policy is loaded before any guard logic runs
  load_policy_or_fail
}

log_dir() {
  if [ -n "${AI_SAFE_LOG_DIR:-}" ]; then
    printf '%s\n' "$AI_SAFE_LOG_DIR"
  else
    printf '%s\n' "$HOME/.ai-safety/logs"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS=""} NR>1{printf "\\n"} {print}'
}

redact_text() {
  local text="$1"
  local pat
  # Apply each secret pattern as a sed substitution
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    text="$(printf '%s' "$text" | LC_ALL=C sed -E "s/${pat}/[REDACTED]/g" 2>/dev/null || printf '%s' "$text")"
  done <<EOF
$SECRET_PATTERNS
EOF
  printf '%s' "$text"
}

audit_log() {
  local decision="$1"
  local reason="$2"
  local observed
  observed="$(redact_text "$RAW_INPUT")"
  local dir path ts user cwd
  dir="$(log_dir)"
  local prev_umask
  prev_umask="$(umask)"
  umask 077
  mkdir -p "$dir"
  path="$dir/events-$(date +%F).jsonl"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  user="${USER:-unknown}"
  cwd="$(pwd)"
  printf '{"ts":"%s","user":"%s","mode":"%s","decision":"%s","reason":"%s","cwd":"%s","observed":"%s"}\n' \
    "$ts" "$(json_escape "$user")" "$(json_escape "$MODE")" "$(json_escape "$decision")" "$(json_escape "$reason")" "$(json_escape "$cwd")" "$(json_escape "$observed")" >> "$path"
  if [ -f "$path" ] && [ -O "$path" ]; then
    chmod 600 "$path" 2>/dev/null || true
  fi
  umask "$prev_umask"
}

block() {
  local reason="$1"
  audit_log "block" "$reason"
  printf 'AI Safety Guard BLOCKED: %s\n' "$reason" >&2
  exit 2
}

allow() {
  local reason="$1"
  audit_log "allow" "$reason"
  exit 0
}

# ---------------------------------------------------------------------------
# Guard predicates (policy-driven, no hardcoded patterns)
# ---------------------------------------------------------------------------

grep_ext() {
  printf '%s' "$RAW_INPUT" | LC_ALL=C grep -E -i -q "$1"
}

# Build a single |-joined regex from a newline-delimited pattern list.
_join_patterns() {
  local list="$1"
  local joined=""
  local pat
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if [ -z "$joined" ]; then
      joined="$pat"
    else
      joined="${joined}|${pat}"
    fi
  done <<EOF
$list
EOF
  printf '%s' "$joined"
}

# Extract the plain-text value of a JSON string field from RAW_INPUT.
# Handles common cases: single-line values without embedded backslash escapes.
# Returns empty string when field is absent.
_extract_json_field() {
  local field="$1"
  printf '%s' "$RAW_INPUT" \
    | sed -nE "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]*)\".*/\1/p" \
    | head -n 1
}

# Build a multi-line string of the candidate texts to inspect:
# RAW_INPUT itself + extracted values of known string fields.
# This ensures patterns with strict anchors (e.g. (\s|$)) match correctly
# even when the value is embedded inside a JSON blob.
_inspection_corpus() {
  printf '%s\n' "$RAW_INPUT"
  _extract_json_field "command"
  _extract_json_field "prompt"
  _extract_json_field "content"
  _extract_json_field "url"
  _extract_json_field "file_path"
}

_grep_corpus() {
  _inspection_corpus | LC_ALL=C grep -E -i -q "$1"
}

has_sensitive_text() {
  local combined
  combined="$(_join_patterns "$SECRET_PATTERNS")"
  [ -z "$combined" ] && return 1
  _grep_corpus "$combined"
}

has_protected_path() {
  local combined
  combined="$(_join_patterns "$PROTECTED_PATH_PATTERNS")"
  [ -z "$combined" ] && return 1
  _grep_corpus "$combined"
}

has_dangerous_command() {
  local combined
  combined="$(_join_patterns "$DANGEROUS_PATTERNS")"
  [ -z "$combined" ] && return 1
  _grep_corpus "$combined"
}

has_generated_code_risk() {
  # Uses generatedCodeDenyRegex from policy if available; graceful skip if key absent
  local count
  count="$("$_PLUTIL" -extract generatedCodeDenyRegex raw -o - "$(_policy_path)" 2>/dev/null)" || return 1
  local i=0
  while [ "$i" -lt "$count" ]; do
    local pat
    pat="$("$_PLUTIL" -extract "generatedCodeDenyRegex.${i}" raw -o - "$(_policy_path)" 2>/dev/null)" || { i=$((i+1)); continue; }
    if printf '%s' "$RAW_INPUT" | LC_ALL=C grep -E -i -q "$pat"; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

extract_url() {
  printf '%s' "$RAW_INPUT" | sed -nE 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1
}

# Domain matching helpers using policy-driven lists.
# Supports exact match and wildcard prefix (*.example.com).
_domain_matches_list() {
  local host="$1"
  local list="$2"
  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$entry" in
      \*.*)
        # Wildcard: *.example.com matches sub.example.com and example.com
        local suffix="${entry#\*.}"
        case "$host" in
          "$suffix"|*."$suffix") return 0 ;;
        esac
        ;;
      *)
        [ "$host" = "$entry" ] && return 0
        ;;
    esac
  done <<EOF
$list
EOF
  return 1
}

is_blocked_domain() {
  local host="$1"
  _domain_matches_list "$host" "$BLOCKED_DOMAINS"
}

is_allowed_domain() {
  local host="$1"
  # blocked takes priority
  is_blocked_domain "$host" && return 1
  _domain_matches_list "$host" "$ALLOWED_DOMAINS"
}
