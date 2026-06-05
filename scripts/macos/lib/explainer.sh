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

# ----- now.html 書き出し (Phase 1: HTML モニター足場) ---------------------
# now.md と「並立」する追加出力。now.md の挙動は一切変えない。
# meta refresh による file:// 直開きの自動更新を前提に、自己完結 HTML
# (外部 CSS/JS/フォントなし) を原子書換 (tmp -> mv) で吐く。

# HTML 特殊文字をエスケープ (jq 非依存・sed のみ)。& を先に処理する。
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# decision -> HTML クラス名 (色) を返す。3値 judge はまだ無いので
# 既存 decision (block/allow/explain) ベース。
decision_class() {
  case "$1" in
    block) printf 'd-block' ;;
    allow) printf 'd-allow' ;;
    explain) printf 'd-explain' ;;
    *) printf 'd-other' ;;
  esac
}

# decision -> アイコン (monitor.sh と同じ表現)。
decision_icon() {
  case "$1" in
    block) printf '⛔' ;;
    allow) printf '✅' ;;
    explain) printf '💬' ;;
    *) printf '•' ;;
  esac
}

# strip_frontmatter 済みのカード本文 (markdown) を最小限の HTML に変換する。
# 完全な markdown パーサは作らない (over-engineering 回避)。
#   '# 見出し' -> <h2>、'- 項目' -> <ul><li>、空行 -> 段落区切り、その他 -> <p>。
# 入力は標準入力。
card_md_to_html() {
  awk '
    function flush_list() { if (in_list) { print "</ul>"; in_list=0 } }
    function esc(s) {
      gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
      gsub(/"/, "\\&quot;", s)
      return s
    }
    BEGIN { in_list=0 }
    {
      line=$0
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^#+[[:space:]]/) {
        flush_list()
        h=line; sub(/^#+[[:space:]]+/, "", h)
        print "<h2>" esc(h) "</h2>"
        next
      }
      if (line ~ /^[-*][[:space:]]/) {
        if (!in_list) { print "<ul>"; in_list=1 }
        item=line; sub(/^[-*][[:space:]]+/, "", item)
        print "<li>" esc(item) "</li>"
        next
      }
      if (line ~ /^[[:space:]]*$/) { flush_list(); next }
      flush_list()
      print "<p>" esc(line) "</p>"
    }
    END { flush_list() }
  '
}

# 本日の events-YYYY-MM-DD.jsonl の末尾 N 件を HTML テーブル行に変換する。
# 監査ログ (jsonl) を再パースするだけ。1件も無ければ空文字を返す。
# monitor.sh の format_event と同じ抽出 (sed) を踏襲し、jq 非依存を保つ。
events_to_html_rows() {
  local dir events tail_n line ts decision mode reason short_ts cls icon
  dir="$(log_dir)"
  events="$dir/events-$(date +%F).jsonl"
  tail_n="${AI_SAFE_MONITOR_TAIL:-12}"
  [ -r "$events" ] || return 0
  # 末尾 N 件を新しい順に並べ替える。tac は macOS に無いので awk で逆順化
  # (BSD/GNU 両対応・追加依存なし)。
  tail -n "$tail_n" "$events" | awk '{ a[NR]=$0 } END { for (i=NR;i>=1;i--) print a[i] }' | while IFS= read -r line; do
    [ -z "$line" ] && continue
    ts="$(printf '%s' "$line" | sed -nE 's/.*"ts"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
    decision="$(printf '%s' "$line" | sed -nE 's/.*"decision"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
    mode="$(printf '%s' "$line" | sed -nE 's/.*"mode"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
    reason="$(printf '%s' "$line" | sed -nE 's/.*"reason"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
    short_ts="${ts##*T}"; short_ts="${short_ts%Z}"; short_ts="${short_ts%.*}"
    cls="$(decision_class "$decision")"
    icon="$(decision_icon "$decision")"
    printf '<tr class="%s"><td class="ev-ts">%s</td><td class="ev-dec">%s %s</td><td class="ev-mode">%s</td><td class="ev-reason">%s</td></tr>\n' \
      "$cls" "$(html_escape "$short_ts")" "$icon" "$(html_escape "$decision")" "$(html_escape "$mode")" "$(html_escape "$reason")"
  done
}

# now.html の <head>（meta + style + JS reload）を出力する。
# write_now_html と write_now_html_placeholder で共通利用し、体裁を一元化する。
# 引数: refresh（自動更新間隔・秒）
now_html_head() {
  local refresh="$1"
  printf '<!DOCTYPE html>\n<html lang="ja">\n<head>\n'
  printf '<meta charset="utf-8">\n'
  printf '<meta http-equiv="refresh" content="%s">\n' "$refresh"
  printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
  printf '<title>agent-monitor — AI の動きを見る</title>\n'
  printf '<style>\n'
  printf '*{box-sizing:border-box}\n'
  printf 'body{margin:0;padding:16px;font-family:-apple-system,"Hiragino Sans","Yu Gothic",sans-serif;background:#0f1115;color:#e6e6e6;word-break:keep-all;line-height:1.7}\n'
  printf '.wrap{max-width:880px;margin:0 auto}\n'
  printf 'h1.hdr{font-size:18px;margin:0 0 14px;color:#9ad}\n'
  printf '.card{border-radius:12px;padding:18px 20px;margin-bottom:20px;border-left:8px solid #888;background:#1a1d24}\n'
  printf '.card-high{border-left-color:#e5534b;background:#2a1718}\n'
  printf '.card-medium{border-left-color:#e0b341;background:#2a2417}\n'
  printf '.card-low{border-left-color:#3fb950;background:#15241a}\n'
  printf '.card-wait{border-left-color:#6e7681;background:#1a1d24}\n'
  printf '.card .ctitle{font-size:22px;font-weight:700;margin:0 0 6px}\n'
  printf '.card .cmeta{font-size:12px;opacity:.7;margin-bottom:10px}\n'
  printf '.card h2{font-size:15px;margin:14px 0 6px;color:#cfd}\n'
  printf '.card ul{margin:4px 0 4px 1.2em;padding:0}\n'
  printf '.card li{margin:3px 0}\n'
  printf '.card p{margin:6px 0}\n'
  printf '.events h2{font-size:15px;color:#9ad;margin:0 0 8px}\n'
  printf 'table{width:100%%;border-collapse:collapse;font-size:13px}\n'
  printf 'th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #2a2f3a;vertical-align:top}\n'
  printf 'th{color:#9aa;font-weight:600}\n'
  printf '.ev-ts{white-space:nowrap;opacity:.8}\n'
  printf '.ev-mode{white-space:nowrap;opacity:.85}\n'
  printf 'tr.d-block .ev-dec{color:#ff7b72}\n'
  printf 'tr.d-allow .ev-dec{color:#56d364}\n'
  printf 'tr.d-explain .ev-dec{color:#79c0ff}\n'
  printf '.empty{opacity:.6;font-size:13px}\n'
  printf '.foot{margin-top:18px;font-size:11px;opacity:.5}\n'
  printf '</style>\n'
  # JS リロード: meta refresh が file:// で効かないブラウザ向けの補完。
  # ユーザ値を JS 内に一切流し込まない (XSS 不発生)。
  # JS が無効な環境では meta refresh にフォールバックする。
  printf '<script>setInterval(function(){ location.reload(); }, 1000);</script>\n'
  printf '</head>\n<body>\n<div class="wrap">\n'
  printf '<h1 class="hdr">agent-monitor — いま AI がやろうとしていること</h1>\n'
}

# 待機カード placeholder の now.html を書き出す。
# ガード未発火（now.html がまだ無い）状態でモニター起動ボタンを押したとき、
# 空白 / file-not-found を防ぐために本物 now.html と同じパス・同じ体裁で吐く。
# ガード発火後は write_now_html が同じパスを上書きするので自動で切り替わる。
# 引数: log_dir（明示。safety_policy.sh の source 不要で単体動作する）
write_now_html_placeholder() {
  local dir="$1"
  local out tmp refresh
  [ -n "$dir" ] || return 1
  out="$dir/now.html"
  # F-I: 本物 now.html が既に存在する場合は何もしない（レース安全化）。
  # write_now_html（本物）は従来どおり上書きするが、placeholder は上書きしない。
  [ -f "$out" ] && return 0
  refresh="${AI_SAFE_MONITOR_INTERVAL:-1}"
  case "$refresh" in (''|*[!0-9]*) refresh=1 ;; esac
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$dir/now.html.tmp.$$"
  {
    now_html_head "$refresh"
    printf '<div class="card card-wait">\n'
    printf '<div class="ctitle">🟢 見守り中です</div>\n'
    printf '<div class="cmeta">まだ承認待ちのアクションはありません</div>\n'
    printf '<p>AI が tool（コマンド実行・ファイル書き込みなど）を呼ぶと、ここに「いま何をしようとしているか」が表示されます。</p>\n'
    printf '<p>この画面は開いたままにしておいてください。AI が動き出すと自動で切り替わります。</p>\n'
    printf '</div>\n'
    printf '<div class="foot">この画面は %s 秒ごとに自動更新されます (JS reload + meta refresh フォールバック)。判断はこの画面ではなくターミナル側で行ってください。</div>\n' "$refresh"
    printf '</div>\n</body>\n</html>\n'
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$out" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  if [ -f "$out" ] && [ -O "$out" ]; then
    chmod 600 "$out" 2>/dev/null || true
  fi
  return 0
}

# now.html を原子書換で書き出す。
# 引数: icon title body_risk ts card_id body_html_path
write_now_html() {
  local icon="$1" title="$2" body_risk="$3" ts="$4" card_id="$5" body_html_path="$6"
  local dir out tmp refresh cardcls
  dir="$(log_dir)"
  out="$dir/now.html"
  # refresh 間隔 (秒)。monitor の再描画間隔と揃える。既定 1。
  refresh="${AI_SAFE_MONITOR_INTERVAL:-1}"
  case "$refresh" in (''|*[!0-9]*) refresh=1 ;; esac
  # カード自身の risk から帯色を選ぶ (high=赤系 / それ以外=緑系)。
  case "$body_risk" in
    high) cardcls="card-high" ;;
    medium) cardcls="card-medium" ;;
    *) cardcls="card-low" ;;
  esac
  tmp="$dir/now.html.tmp.$$"
  {
    now_html_head "$refresh"
    printf '<div class="card %s">\n' "$cardcls"
    printf '<div class="ctitle">%s %s</div>\n' "$(html_escape "$icon")" "$(html_escape "$title")"
    printf '<div class="cmeta">%s ・ tool=%s ・ risk=%s ・ card=%s</div>\n' \
      "$(html_escape "$ts")" "$(html_escape "$MODE")" "$(html_escape "$body_risk")" "$(html_escape "$card_id")"
    if [ -r "$body_html_path" ]; then
      card_md_to_html < "$body_html_path"
    fi
    printf '</div>\n'
    printf '<div class="events">\n<h2>直近の出来事 (events-%s.jsonl)</h2>\n' "$(date +%F)"
    local rows
    rows="$(events_to_html_rows)"
    if [ -n "$rows" ]; then
      printf '<table>\n<thead><tr><th>時刻</th><th>判定</th><th>種類</th><th>理由</th></tr></thead>\n<tbody>\n'
      printf '%s\n' "$rows"
      printf '</tbody>\n</table>\n'
    else
      printf '<p class="empty">本日の監査ログはまだありません。AI が tool を呼ぶとここに出ます。</p>\n'
    fi
    printf '</div>\n'
    printf '<div class="foot">この画面は %s 秒ごとに自動更新されます (JS reload + meta refresh フォールバック)。判断はこの画面ではなくターミナル側で行ってください。</div>\n' "$refresh"
    printf '</div>\n</body>\n</html>\n'
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  # 原子書換: 同一ディレクトリ内 tmp -> mv で rename (リロード途中の半端読み回避)。
  mv -f "$tmp" "$out" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  if [ -f "$out" ] && [ -O "$out" ]; then
    chmod 600 "$out" 2>/dev/null || true
  fi
  return 0
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
  # now.html を「並立」出力 (now.md は上で確定済み・不変)。失敗しても explain を止めない。
  write_now_html "$icon" "$title" "$body_risk" "$ts" "$card_id" "$body_path" 2>/dev/null || true
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
