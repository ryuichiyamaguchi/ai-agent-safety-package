#!/usr/bin/env bash
set -u

MODE="${AI_SAFE_MODE:-unknown}"
RAW_INPUT=""

read_hook_input() {
  RAW_INPUT="$(cat)"
  if [ "${#RAW_INPUT}" -gt 262144 ]; then
    RAW_INPUT="${RAW_INPUT:0:262144}"
  fi
}

log_dir() {
  if [ -n "${AI_SAFE_LOG_DIR:-}" ]; then
    printf '%s\n' "$AI_SAFE_LOG_DIR"
  else
    printf '%s\n' "$HOME/.ai-safety/logs"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n'
}

redact_text() {
  printf '%s' "$1" \
    | sed -E 's/sk-(proj-)?[A-Za-z0-9_-]{20,}/[REDACTED:openai]/g' \
    | sed -E 's/sk-ant-[A-Za-z0-9_-]{20,}/[REDACTED:anthropic]/g' \
    | sed -E 's/AIza[0-9A-Za-z_-]{25,}/[REDACTED:google]/g' \
    | sed -E 's/(AKIA|ASIA)[0-9A-Z]{16}/[REDACTED:aws]/g' \
    | sed -E 's/gh[pousr]_[A-Za-z0-9_]{36,255}/[REDACTED:github]/g' \
    | sed -E 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED:slack]/g'
}

audit_log() {
  local decision="$1"
  local reason="$2"
  local observed
  observed="$(redact_text "$RAW_INPUT")"
  local dir path ts user cwd
  dir="$(log_dir)"
  # M4: 監査ログはマルチユーザー環境で他ユーザーから見られないよう、
  # 作成時に umask 077 を一時適用してパーミッションを所有者のみに制限する。
  local prev_umask
  prev_umask="$(umask)"
  umask 077
  mkdir -p "$dir"
  # 既存ディレクトリの mode は変えない（再作成時のみ 700 で作る）
  path="$dir/events-$(date +%F).jsonl"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  user="${USER:-unknown}"
  cwd="$(pwd)"
  printf '{"ts":"%s","user":"%s","mode":"%s","decision":"%s","reason":"%s","cwd":"%s","observed":"%s"}\n' \
    "$ts" "$(json_escape "$user")" "$(json_escape "$MODE")" "$(json_escape "$decision")" "$(json_escape "$reason")" "$(json_escape "$cwd")" "$(json_escape "$observed")" >> "$path"
  # 既存ファイル（過去日に 644 で作られたもの）も自分の所有なら 600 に締め直す。
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

grep_ext() {
  printf '%s' "$RAW_INPUT" | LC_ALL=C grep -E -i -q "$1"
}

has_sensitive_text() {
  grep_ext 'sk-(proj-)?[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{25,}|(AKIA|ASIA)[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{36,255}|xox[baprs]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|(api[_-]?key|secret|token|password|passwd|pwd)[[:space:]]*[:=][[:space:]]*['\''"]?[A-Za-z0-9_.\/+=-]{12,}'
}

has_protected_path() {
  grep_ext '(^|[[:space:]"'\''/\\])([.]env([.][A-Za-z0-9_-]+)?|[.]ssh|[.]aws|[.]azure|[.]gnupg|[.]kube|[.]docker|[.]npmrc|[.]pypirc|id[_-]rsa|id[_-]ed25519|known[_-]hosts)([[:space:]"'\''/\\]|$)'
}

has_dangerous_command() {
  grep_ext '\b(cat|type|Get-Content|gc|more|less)\b.*[.]env|\bpython3?\b.*open[[:space:]]*\([[:space:]]*['\''"][^'\''"]*[.]env|\b(curl|wget|Invoke-WebRequest|iwr|Invoke-RestMethod|irm|nc|ncat|netcat)\b|\brm[[:space:]]+(-[A-Za-z]*r[A-Za-z]*f|-rf|-fr)\b|\bRemove-Item\b.*\b-Recurse\b.*\b-Force\b|\b(git[[:space:]]+push|npm[[:space:]]+publish|twine[[:space:]]+upload)\b'
}

has_generated_code_risk() {
  grep_ext 'open[[:space:]]*\([[:space:]]*['\''"][^'\''"]*[.]env|(readFileSync|read_file|Get-Content|File[.]read|Path\().*[.]env|(requests[.]|fetch[[:space:]]*\(|axios[.]|urllib[.]|Invoke-WebRequest|curl_exec)|(subprocess|child_process|ProcessStartInfo).*[.]env'
}

extract_url() {
  printf '%s' "$RAW_INPUT" | sed -nE 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1
}

is_blocked_domain() {
  local host="$1"
  case "$host" in
    gist.github.com|*.gist.github.com|gist.githubusercontent.com|*.gist.githubusercontent.com|*.pages.dev|*.workers.dev|pastebin.com|*.pastebin.com|hastebin.com|*.hastebin.com|0x0.st|transfer.sh|*.transfer.sh|file.io|*.file.io|anonfiles.com|*.anonfiles.com)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_allowed_domain() {
  local host="$1"
  if is_blocked_domain "$host"; then
    return 1
  fi
  case "$host" in
    developers.openai.com|*.developers.openai.com|platform.openai.com|*.platform.openai.com|docs.anthropic.com|*.docs.anthropic.com|code.claude.com|*.code.claude.com|github.com|api.github.com|raw.githubusercontent.com|objects.githubusercontent.com|docs.github.com|gemini.google.com|*.gemini.google.com|ai.google.dev|*.ai.google.dev|cloud.google.com|*.cloud.google.com|registry.npmjs.org|pypi.org|files.pythonhosted.org)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
