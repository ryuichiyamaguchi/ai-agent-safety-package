#!/usr/bin/env bash
# agent-monitor: 「いま AI がしようとしていること」表示の入口（mac）。
# safety_policy.sh が source 済みであることを前提とする（log_dir / audit_log を使う）。
# 提供関数: explain （フェイルセーフ。失敗してもポリシー判定を阻害しない）
#
# v1.19.0: 解説の本体は scripts/common/explainer.js（Node・Mac/Windows 共通の 1 本）へ移した。
#   以前はここに約 1,300 行の解説エンジンがあり、Windows の Explainer.ps1 と二重実装だった。
#   ここに残すのは (1) explainer.js を呼ぶ入口 (2) Node が見つからないときの簡易表示
#   (3) モニター起動前の待機画面（open-monitor.sh が Node 無しでも使う）と、guard-bash.sh が使う html_escape。
#   ★ 危険コマンドを止める判定（safety_policy.sh）とは無関係。ここが壊れても判定は変わらない。

set -u

# ----- 設定 ---------------------------------------------------------------

# カード配置ディレクトリ。
#   導入後:  <ws>/.ai-safety/hooks/macos/lib/explainer.sh → <ws>/.ai-safety/cards
#   開発時:  <repo>/scripts/macos/lib/explainer.sh       → <repo>/configs/safety/cards
# （v1.19.0 で開発時の探し先を修正。以前は 1 段上のフォルダを探していて見つからなかった）
cards_dir() {
  if [ -n "${AI_SAFE_CARDS_DIR:-}" ]; then
    printf '%s\n' "$AI_SAFE_CARDS_DIR"
    return
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  if [ -d "$here/../../../cards" ]; then
    (cd "$here/../../../cards" && pwd)
  else
    printf '%s\n' "$here/../../../configs/safety/cards"
  fi
}

# explainer.js の場所（lib の 2 つ上の common/）。
_explainer_js() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../common" 2>/dev/null && pwd)" || return 1
  printf '%s/explainer.js' "$here"
}

# node の場所。フックの PATH に無いこともあるので、よくある置き場も見る。
_explainer_node() {
  local n
  # テスト用: AI_SAFE_EXPLAINER_NODE が設定されていればそれだけを使う（存在しなければ簡易表示になる）。
  if [ -n "${AI_SAFE_EXPLAINER_NODE+set}" ]; then
    [ -x "${AI_SAFE_EXPLAINER_NODE}" ] && printf '%s' "${AI_SAFE_EXPLAINER_NODE}"
    return 0
  fi
  n="$(command -v node 2>/dev/null || true)"
  if [ -z "$n" ]; then
    for n in /opt/homebrew/bin/node /usr/local/bin/node; do
      [ -x "$n" ] && break
      n=""
    done
  fi
  printf '%s' "$n"
}

# ----- Node が無いときの簡易表示で使う小道具 ------------------------------

# 一行 JSON 風入力からキーの文字列値を雑に抽出する（jq 依存を避ける）。
# 抽出後に JSON 文字列エスケープを _json_unescape で正しくデコードする(perl・1パス)。
# \" \\ \/ \b \f \n \r \t \uXXXX に対応し、\u000a(改行)や \u003e(>) を隠した入力でも検出が効く。
# 注意: 完全な JSON パーサではない。教育用途では十分。
extract_json_string() {
  local key="$1"
  printf '%s' "$RAW_INPUT" | tr '\n' ' ' \
    | sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"((\\\\.|[^\"\\\\])*)\".*/\\1/p" \
    | head -n 1 \
    | _json_unescape
}

# JSON 文字列エスケープを1パス(左→右)で正しくデコードする。
# 二重エスケープも誤って改行化せず、\uXXXX を実文字へ復元するため、
# 改行や > を \u 形式で隠した入力でも区切り・リダイレクト検出が効く。
_json_unescape() {
  perl -CSDA -0777 -pe '
    s{\\(u[0-9a-fA-F]{4}|["\\/bfnrt])}{
      my $e = $1;
        $e eq q{"}  ? q{"}  :
        $e eq q{\\} ? q{\\} :
        $e eq q{/}  ? q{/}  :
        $e eq q{b}  ? "\b"  :
        $e eq q{f}  ? "\f"  :
        $e eq q{n}  ? "\n"  :
        $e eq q{r}  ? "\r"  :
        $e eq q{t}  ? "\t"  :
        chr(hex(substr($e,1)))
    }ge;
  ' 2>/dev/null
}

_limit_chars() {
  # 引数: max_chars
  # stdin からテキストを受け取り、max_chars 文字で切り捨てる（改行を除去してから）。
  # -CSDA: stdin/stdout/stderr を Unicode として扱う。日本語を文字単位で正しく数える。
  # 省略マーカーは \x{2026}\x{FF08}\x{7701}\x{7565}\x{FF09} = …(省略)
  local max="${1:-800}"
  perl -CSDA -0777 -ne '
    s/[\r\n]+/ /g;
    if (length($_) > '"$max"') {
      print substr($_, 0, '"$max"') . "\x{2026}\x{FF08}\x{7701}\x{7565}\x{FF09}";
    } else {
      print $_;
    }
  ' 2>/dev/null
}


# HTML 特殊文字をエスケープ (jq 非依存・sed のみ)。& を先に処理する。
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
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
  printf '.action{background:#12161f;border:1px solid #2a3040;border-radius:8px;padding:12px 14px;margin:10px 0 14px}\n'
  printf '.action-label{font-size:12px;color:#8ab;margin-bottom:6px;font-weight:600}\n'
  printf '.action-cmd{margin:0;font-family:monospace,"Courier New",Courier;font-size:14px;color:#f0c080;white-space:pre-wrap;word-break:break-all;overflow-wrap:anywhere}\n'
  printf '.whatdo{background:#14211a;border:1px solid #2a4030;border-radius:8px;padding:12px 14px;margin:0 0 14px}\n'
  printf '.whatdo-label{font-size:13px;color:#7fd6a0;margin-bottom:6px;font-weight:700}\n'
  printf '.whatdo-body{margin:0;font-size:15px;color:#e6e6e6;line-height:1.7}\n'
  printf '.whatdo-danger{margin:8px 0 0;font-size:14px;color:#ffb4ad;font-weight:700}\n'
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

# Node が見つからないときの簡易表示。操作の文字列だけを出す（解説カード・「これは何をする？」は出ない）。
_explain_fallback() {
  local dir text label ts refresh out tmp prev_umask
  dir="$(log_dir)"
  case "${MODE:-}" in
    bash) text="$(extract_json_string "command")"; label="コマンド実行" ;;
    write) text="$(extract_json_string "file_path")"; label="ファイル書き込み" ;;
    webfetch) text="$(extract_json_string "url")"; label="Web アクセス" ;;
    observe) text="$(extract_json_string "tool_name")"; label="ツールの使用" ;;
    prompt|post-output) text="$(printf '%s' "$RAW_INPUT" | _limit_chars 300)"; label="プロンプト" ;;
    *) text="$(printf '%s' "$RAW_INPUT" | _limit_chars 200)"; label="操作" ;;
  esac
  [ -z "$text" ] && text="（取得できませんでした）"
  text="$(printf '%s' "$text" | _limit_chars 800)"
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  refresh="${AI_SAFE_MONITOR_INTERVAL:-1}"
  case "$refresh" in (''|*[!0-9]*) refresh=1 ;; esac
  prev_umask="$(umask)"
  umask 077
  mkdir -p "$dir" 2>/dev/null || { umask "$prev_umask"; return 1; }
  out="$dir/now.md"
  {
    printf '💡 AI が操作をしようとしています  (risk: low)\n'
    printf -- '─────────────────────────────────────────\n'
    printf '[%s  tool=%s  card=fallback]\n' "$ts" "${MODE:-}"
    printf '\n▶ %s:\n  %s\n' "$label" "$text"
    printf '\n（詳しい解説は Node.js が入っている PC で表示されます）\n'
  } > "$out" 2>/dev/null
  tmp="$dir/now.html.tmp.$$"
  {
    now_html_head "$refresh"
    printf '<div class="card card-low">\n'
    printf '<div class="ctitle">💡 AI が操作をしようとしています</div>\n'
    printf '<div class="cmeta">%s ・ tool=%s ・ risk=low ・ card=fallback</div>\n' "$(html_escape "$ts")" "$(html_escape "${MODE:-}")"
    printf '<div class="action">\n'
    printf '<div class="action-label">🤖 AI がしようとしていること（%s）</div>\n' "$(html_escape "$label")"
    printf '<pre class="action-cmd">%s</pre>\n' "$(html_escape "$text")"
    printf '</div>\n'
    printf '<p>詳しい解説は Node.js が入っている PC で表示されます。</p>\n'
    printf '</div>\n'
    printf '<div class="foot">この画面は %s 秒ごとに自動更新されます (JS reload + meta refresh フォールバック)。判断はこの画面ではなくターミナル側で行ってください。</div>\n' "$refresh"
    printf '</div>\n</body>\n</html>\n'
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/now.html" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  umask "$prev_umask"
  return 0
}

# ----- 公開 API ----------------------------------------------------------

# explain: 解説カードを選んで now.md / now.html を更新し、audit_log に decision="explain" を追加する。
# 本体は explainer.js。どこかで失敗してもポリシー判定を止めないように常に成功する。
explain() {
  {
    local js node_bin tb out card risk
    js="$(_explainer_js 2>/dev/null || true)"
    node_bin="$(_explainer_node)"
    out=""
    if [ -n "$node_bin" ] && [ -n "$js" ] && [ -r "$js" ]; then
      tb="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
      if [ -n "$tb" ]; then
        out="$(printf '%s' "$RAW_INPUT" | "$tb" 10 "$node_bin" "$js" explain --mode "${MODE:-}" --log-dir "$(log_dir)" --cards-dir "$(cards_dir)" 2>/dev/null || true)"
      else
        out="$(printf '%s' "$RAW_INPUT" | "$node_bin" "$js" explain --mode "${MODE:-}" --log-dir "$(log_dir)" --cards-dir "$(cards_dir)" 2>/dev/null || true)"
      fi
    fi
    if [ -n "$out" ]; then
      card="$(printf '%s' "$out" | head -n 1 | cut -f1)"
      risk="$(printf '%s' "$out" | head -n 1 | cut -f2)"
      audit_log "explain" "card=$card risk=$risk"
    elif _explain_fallback; then
      audit_log "explain" "card=fallback risk=low"
    fi
  } 2>/dev/null || true
  return 0
}
