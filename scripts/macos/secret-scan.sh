#!/usr/bin/env bash
# secret-scan.sh
#
# 機微情報スキャナ（v1.4.0 で新規追加）
# 外部 LLM（DeepSeek 等）に貼り付ける前のテキストを検査し、API キー・
# 個人情報・パスワード等を [MASKED:type] に置換する。
#
# 使い方:
#   secret-scan < input.txt                 # 標準入力をスキャン
#   secret-scan input.txt                   # ファイルをスキャン
#   pbpaste | secret-scan --mask | pbcopy   # クリップボード経由
#   echo "hello" | secret-scan              # ワンライナー
#
# オプション:
#   --mask    マスキング版を stdout に出力（デフォルト ON）
#   --check   マスキングせず検出件数だけ stderr に出力、検出時 exit 1
#   --quiet   stderr の警告を抑制（ログには記録）
#
# 終了コード:
#   0 = マスキングして出力（検出 0 件も含む）
#   1 = --check モードで検出あり
#   2 = 入力読み込み失敗
#
# 監査ログ: $AI_SAFE_LOG_DIR/secret-scan-events.jsonl（既定: ~/.ai-safety/logs/）

set -u
LANG=${LANG:-en_US.UTF-8}

MODE_MASK=1
MODE_CHECK=0
QUIET=0
INPUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mask) MODE_MASK=1; MODE_CHECK=0 ;;
    --check) MODE_MASK=0; MODE_CHECK=1 ;;
    --quiet) QUIET=1 ;;
    --help|-h)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "secret-scan: unknown option: $1" >&2
      exit 2
      ;;
    *)
      INPUT_FILE="$1"
      ;;
  esac
  shift
done

if [ -n "$INPUT_FILE" ]; then
  if [ ! -r "$INPUT_FILE" ]; then
    echo "secret-scan: cannot read: $INPUT_FILE" >&2
    exit 2
  fi
  RAW="$(cat "$INPUT_FILE")"
else
  RAW="$(cat)"
fi

# ANSI 色（stderr が tty のときだけ）
if [ -t 2 ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_RST=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_RST=""
fi

count_pattern() {
  printf '%s' "$RAW" | LC_ALL=C grep -E -i -o "$1" 2>/dev/null | wc -l | tr -d ' '
}

C_OPENAI=$(count_pattern 'sk-(proj-)?[A-Za-z0-9_-]{20,}')
C_ANTHROPIC=$(count_pattern 'sk-ant-[A-Za-z0-9_-]{20,}')
C_GOOGLE=$(count_pattern 'AIza[0-9A-Za-z_-]{25,}')
C_AWS=$(count_pattern '(AKIA|ASIA)[0-9A-Z]{16}')
C_GITHUB=$(count_pattern 'gh[pousr]_[A-Za-z0-9_]{36,255}')
C_SLACK=$(count_pattern 'xox[baprs]-[A-Za-z0-9-]{10,}')
C_JWT=$(count_pattern 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+')
C_PRIV=$(count_pattern -- '-----BEGIN (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----')
C_GENERIC=$(count_pattern '(api[_-]?key|secret|token|password|passwd|pwd)[[:space:]]*[:=][[:space:]]*['\''"]?[A-Za-z0-9_.+/=-]{12,}')

TOTAL=$((C_OPENAI + C_ANTHROPIC + C_GOOGLE + C_AWS + C_GITHUB + C_SLACK + C_JWT + C_PRIV + C_GENERIC))

# 警告出力（stderr）
emit_warning() {
  [ "$QUIET" -eq 1 ] && return 0
  [ "$TOTAL" -eq 0 ] && return 0
  echo "${C_RED}⚠ secret-scan: ${TOTAL} 件の機微情報を検出しました${C_RST}" >&2
  [ "$C_OPENAI"    -gt 0 ] && echo "${C_YEL}  - OpenAI API key:    ${C_OPENAI} 件${C_RST}" >&2
  [ "$C_ANTHROPIC" -gt 0 ] && echo "${C_YEL}  - Anthropic API key: ${C_ANTHROPIC} 件${C_RST}" >&2
  [ "$C_GOOGLE"    -gt 0 ] && echo "${C_YEL}  - Google API key:    ${C_GOOGLE} 件${C_RST}" >&2
  [ "$C_AWS"       -gt 0 ] && echo "${C_YEL}  - AWS access key:    ${C_AWS} 件${C_RST}" >&2
  [ "$C_GITHUB"    -gt 0 ] && echo "${C_YEL}  - GitHub token:      ${C_GITHUB} 件${C_RST}" >&2
  [ "$C_SLACK"     -gt 0 ] && echo "${C_YEL}  - Slack token:       ${C_SLACK} 件${C_RST}" >&2
  [ "$C_JWT"       -gt 0 ] && echo "${C_YEL}  - JWT:               ${C_JWT} 件${C_RST}" >&2
  [ "$C_PRIV"      -gt 0 ] && echo "${C_YEL}  - Private key block: ${C_PRIV} 件${C_RST}" >&2
  [ "$C_GENERIC"   -gt 0 ] && echo "${C_YEL}  - Generic secret:    ${C_GENERIC} 件${C_RST}" >&2
  if [ "$MODE_MASK" -eq 1 ]; then
    echo "${C_RED}→ マスキングして出力します（本物の値は外部 LLM に送られません）${C_RST}" >&2
  fi
}

# 監査ログ
write_log() {
  local log_dir="${AI_SAFE_LOG_DIR:-$HOME/.ai-safety/logs}"
  local prev_umask
  prev_umask="$(umask)"
  umask 077
  mkdir -p "$log_dir" 2>/dev/null || { umask "$prev_umask"; return; }
  local log_path="$log_dir/secret-scan-events.jsonl"
  local ts user cwd mode
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  user="${USER:-unknown}"
  cwd="$(pwd)"
  if [ "$MODE_CHECK" -eq 1 ]; then mode="check"; else mode="mask"; fi
  printf '{"ts":"%s","user":"%s","mode":"%s","cwd":"%s","total":%d,"counts":{"openai":%d,"anthropic":%d,"google":%d,"aws":%d,"github":%d,"slack":%d,"jwt":%d,"private_key":%d,"generic":%d}}\n' \
    "$ts" "$user" "$mode" "$cwd" "$TOTAL" \
    "$C_OPENAI" "$C_ANTHROPIC" "$C_GOOGLE" "$C_AWS" "$C_GITHUB" "$C_SLACK" "$C_JWT" "$C_PRIV" "$C_GENERIC" \
    >> "$log_path"
  if [ -f "$log_path" ] && [ -O "$log_path" ]; then
    chmod 600 "$log_path" 2>/dev/null || true
  fi
  umask "$prev_umask"
}

# マスキング処理
mask_text() {
  printf '%s' "$RAW" \
    | sed -E 's/sk-(proj-)?[A-Za-z0-9_-]{20,}/[MASKED:openai]/g' \
    | sed -E 's/sk-ant-[A-Za-z0-9_-]{20,}/[MASKED:anthropic]/g' \
    | sed -E 's/AIza[0-9A-Za-z_-]{25,}/[MASKED:google]/g' \
    | sed -E 's/(AKIA|ASIA)[0-9A-Z]{16}/[MASKED:aws]/g' \
    | sed -E 's/gh[pousr]_[A-Za-z0-9_]{36,255}/[MASKED:github]/g' \
    | sed -E 's/xox[baprs]-[A-Za-z0-9-]{10,}/[MASKED:slack]/g' \
    | sed -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[MASKED:jwt]/g' \
    | sed -E 's/-----BEGIN (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----/[MASKED:private_key_begin]/g' \
    | sed -E 's/-----END (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----/[MASKED:private_key_end]/g' \
    | sed -E "s/(api[_-]?key|secret|token|password|passwd|pwd)([[:space:]]*[:=][[:space:]]*)['\"]?[A-Za-z0-9_.+\\/=-]{12,}['\"]?/\1\2[MASKED:generic]/gi"
}

emit_warning
write_log

if [ "$MODE_CHECK" -eq 1 ]; then
  if [ "$TOTAL" -gt 0 ]; then
    exit 1
  else
    exit 0
  fi
fi

mask_text
exit 0
