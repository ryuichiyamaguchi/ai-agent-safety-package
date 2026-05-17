#!/usr/bin/env bash
# agent-monitor: 承認解説カードのロード/表示ライブラリ。
# safety_policy.sh が source 済みであることを前提とする。
# 提供関数: explain （フェイルセーフ。失敗してもポリシー判定を阻害しない）

set -u

# ----- 設定 ---------------------------------------------------------------

# カード配置ディレクトリ。install.sh が
#   $CLAUDE_PROJECT_DIR/.ai-safety/cards/
# に展開する想定。explainer.sh は
#   $CLAUDE_PROJECT_DIR/.ai-safety/hooks/macos/lib/explainer.sh
# にあるので、相対パスでは ../../../cards にあたる。
cards_dir() {
  if [ -n "${AI_SAFE_CARDS_DIR:-}" ]; then
    printf '%s\n' "$AI_SAFE_CARDS_DIR"
    return
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  local guess="$here/../../../cards"
  if [ -d "$guess" ]; then
    (cd "$guess" && pwd)
  else
    # 開発時 fallback: リポジトリ直下の configs/safety/cards/
    printf '%s\n' "$here/../../../../configs/safety/cards"
  fi
}

# ----- 抽出ヘルパ ---------------------------------------------------------

# 一行 JSON 風入力からキーの文字列値を雑に抽出する（jq 依存を避ける）。
# 注意: エスケープシーケンスが含まれる場合は完全には正しくない。教育用途では十分。
extract_json_string() {
  local key="$1"
  printf '%s' "$RAW_INPUT" | tr '\n' ' ' | sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"((\\\\.|[^\"\\\\])*)\".*/\\1/p" | head -n 1
}

# 解説対象として抽出する文字列（MODE 依存）。
extract_target() {
  case "$MODE" in
    bash)
      extract_json_string "command"
      ;;
    write)
      extract_json_string "file_path"
      ;;
    webfetch)
      local url
      url="$(extract_url)"
      printf '%s' "$url" | sed -E 's#^https?://([^/:?#]+).*#\1#' | tr '[:upper:]' '[:lower:]'
      ;;
    prompt|post-output)
      printf '%s' "$RAW_INPUT"
      ;;
    *)
      printf '%s' "$RAW_INPUT"
      ;;
  esac
}

# ----- index.tsv 走査 -----------------------------------------------------

# 引数: target_text
# 出力: <card_id>\t<risk>  （マッチしなければ非0 終了）
lookup_card() {
  local target="$1"
  local index_path
  index_path="$(cards_dir)/index.tsv"
  [ -r "$index_path" ] || return 1

  local tool pattern risk card_id
  while IFS=$'\t' read -r tool pattern risk card_id; do
    case "$tool" in
      ""|"#"*) continue ;;
    esac
    [ "$tool" = "$MODE" ] || continue
    if printf '%s' "$target" | LC_ALL=C grep -E -q -- "$pattern" 2>/dev/null; then
      printf '%s\t%s\n' "$card_id" "$risk"
      return 0
    fi
  done < "$index_path"
  return 1
}

# ----- frontmatter 読み取り -----------------------------------------------

read_frontmatter_value() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    BEGIN { in_fm=0; matched=0 }
    /^---$/ {
      if (in_fm==0 && NR==1) { in_fm=1; next }
      if (in_fm==1) { exit }
    }
    in_fm==1 {
      regex = "^" key "[[:space:]]*:[[:space:]]*(.*)$"
      if (match($0, regex)) {
        val = substr($0, RSTART, RLENGTH)
        sub("^" key "[[:space:]]*:[[:space:]]*", "", val)
        sub(/[[:space:]]+$/, "", val)
        print val
        exit
      }
    }
  ' "$file"
}

strip_frontmatter() {
  local file="$1"
  awk '
    BEGIN { in_fm=0; done_fm=0 }
    /^---$/ {
      if (NR==1) { in_fm=1; next }
      if (in_fm==1) { in_fm=0; done_fm=1; next }
    }
    done_fm==1 { print }
  ' "$file"
}

# ----- now.md 書き出し ---------------------------------------------------

write_now_card() {
  local card_id="$1"
  local risk_default="$2"
  local cdir body_path
  cdir="$(cards_dir)"
  body_path="$cdir/$card_id.md"
  if [ ! -r "$body_path" ]; then
    body_path="$cdir/default-$MODE.md"
  fi
  [ -r "$body_path" ] || return 1

  local title icon body_risk ts dir prev_umask out
  title="$(read_frontmatter_value "$body_path" "title")"
  icon="$(read_frontmatter_value "$body_path" "icon")"
  body_risk="$(read_frontmatter_value "$body_path" "risk")"
  [ -z "$body_risk" ] && body_risk="$risk_default"
  [ -z "$title" ] && title="（タイトル未設定）"
  [ -z "$icon" ] && icon="💡"
  ts="$(date '+%Y-%m-%d %H:%M:%S')"

  dir="$(log_dir)"
  prev_umask="$(umask)"
  umask 077
  mkdir -p "$dir"
  out="$dir/now.md"
  {
    printf '%s %s  (risk: %s)\n' "$icon" "$title" "$body_risk"
    printf -- '─────────────────────────────────────────\n'
    printf '[%s  tool=%s  card=%s]\n\n' "$ts" "$MODE" "$card_id"
    strip_frontmatter "$body_path"
  } > "$out"
  if [ -f "$out" ] && [ -O "$out" ]; then
    chmod 600 "$out" 2>/dev/null || true
  fi
  umask "$prev_umask"
  printf '%s' "$card_id"
}

# ----- 公開 API ----------------------------------------------------------

# explain: tool 名と引数から最適なカードを選んで now.md を更新し、
# audit_log に decision="explain" のエントリを追加する。
# どこかで失敗してもポリシー判定を止めないように常に成功する。
explain() {
  {
    local target hit card_id risk written
    target="$(extract_target)"
    hit="$(lookup_card "$target" 2>/dev/null)"
    if [ -n "$hit" ]; then
      card_id="$(printf '%s' "$hit" | cut -f1)"
      risk="$(printf '%s' "$hit" | cut -f2)"
    else
      card_id="default-$MODE"
      risk="low"
    fi
    written="$(write_now_card "$card_id" "$risk" 2>/dev/null || true)"
    if [ -n "$written" ]; then
      audit_log "explain" "card=$written risk=$risk"
    fi
  } 2>/dev/null || true
  return 0
}
