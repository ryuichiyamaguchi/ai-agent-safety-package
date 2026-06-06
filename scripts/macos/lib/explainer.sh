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
# 抽出後に最低限の JSON escape をデコード: \\ → \, \" → ", \/ → /
# 注意: 完全な JSON パーサではない。教育用途では十分。
extract_json_string() {
  local key="$1"
  printf '%s' "$RAW_INPUT" | tr '\n' ' ' \
    | sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"((\\\\.|[^\"\\\\])*)\".*/\\1/p" \
    | head -n 1 \
    | sed 's/\\\\/\\/g; s/\\"/"/g; s/\\\//\//g'
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

# ツール別に「AI が実際にしようとしていること」の文字列を組み立てる。
# 結果はグローバル変数 ACTION_TEXT / ACTION_LABEL に格納する。
# TAB/改行を含むコマンドでも round-trip を破壊しないよう戻り値を使わない。
# XSS対策は呼び出し側(write_now_html)で html_escape するので、ここはプレーンテキスト。
#
# 切り捨て: perl -CSDA で Unicode 文字単位の 800 字。実際に切った時だけ「…(省略)」を付ける。
# (macOS awk は バイト単位のため不使用。perl は isolation_drills.sh で既に前提)
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

# グローバル変数（explain() から参照する）
ACTION_TEXT=""
ACTION_LABEL="操作"

extract_action_text() {
  local text label fp content_first
  case "$MODE" in
    bash)
      text="$(extract_json_string "command")"
      label="コマンド実行"
      ;;
    write)
      fp="$(extract_json_string "file_path")"
      # content 先頭を文字単位 120 字で切る（F-M: head -c はバイト切り）
      content_first="$(extract_json_string "content" | _limit_chars 120)"
      if [ -n "$content_first" ]; then
        text="${fp} (内容: ${content_first})"
      else
        text="$fp"
      fi
      label="ファイル書き込み"
      ;;
    webfetch)
      text="$(printf '%s' "$RAW_INPUT" | sed -nE 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)"
      label="Web アクセス"
      ;;
    prompt|post-output)
      # プロンプトは先頭 300 字（F-M: head -c はバイト切り）
      text="$(printf '%s' "$RAW_INPUT" | _limit_chars 300)"
      label="プロンプト"
      ;;
    *)
      text="$(printf '%s' "$RAW_INPUT" | _limit_chars 200)"
      label="操作"
      ;;
  esac
  # 空の場合は不明
  [ -z "$text" ] && text="（取得できませんでした）"
  # 800字で切り捨て（F-J: 実際に切ったときだけ「…(省略)」を付ける）
  text="$(printf '%s' "$text" | _limit_chars 800)"
  # グローバル変数に格納（F-K: TAB round-trip 破壊を避けるため戻り値を使わない）
  ACTION_TEXT="$text"
  ACTION_LABEL="$label"
}

# ----- コマンド解説エンジン (パターン式・LLM不要・オフライン・決定的) ----
# 設計原則: 「証明されない限り安全と言わない(保守的)」。
# 安心文「(中身を見るだけ。削除や書き換えはしません)」は全セグメントが
# read-only と証明できた時のみ出す。少しでも危険性があれば省く。
#
# 出力グローバル変数:
#   EXPLAIN_WHATDO  平易な日本語の「何をする？」本文（未知コマンドは空）
#   EXPLAIN_ICON    セクション見出しアイコン（既定 📂）
#   EXPLAIN_DANGER  危険強調行（複数あれば改行区切り。無ければ空）
EXPLAIN_WHATDO=""
EXPLAIN_ICON="📂"
EXPLAIN_DANGER=""

# コマンド全文を | ; && || で分割し、各セグメント(前後空白除去)をプリントする。
# awk で文字走査して分割（BSD/GNU 両対応）。
_explain_split_segments() {
  printf '%s' "$1" | awk '
    BEGIN { seg="" }
    function flush() {
      gsub(/^[[:space:]]+/,"",seg); gsub(/[[:space:]]+$/,"",seg)
      if (seg!="") print seg
      seg=""
    }
    {
      L=length($0)
      for (i=1;i<=L;i++) {
        c=substr($0,i,1)
        c2=substr($0,i,2)
        # 改行は区切り
        if (c=="\n") { flush(); continue }
        if (c=="|" || c==";") { flush()
        } else if (c2=="&&" || c2=="||") { flush(); i++  # skip second char
        } else if (c=="&" && c2!="&&" && c2!="&>") {
          # 単独 & (バックグラウンド区切り): && と &> ではない場合
          flush()
        } else {
          seg=seg c
        }
      }
      flush()
    }
  '
}

# セグメント文字列から先頭の sudo を剥がす。
_explain_strip_sudo() {
  printf '%s' "$1" | awk '{ if (tolower($1)=="sudo" && NF>=2) { $1=""; sub(/^[[:space:]]+/,""); print } else print }'
}

# セグメント先頭の動詞トークンを返す（小文字化なし）。
_explain_verb() {
  printf '%s' "$1" | awk '{ print $1 }'
}

# 単一・二重引用符 両方の内側テキストをスペースに置換して返す。
# リダイレクト演算子(> < | ;)の検出前処理に使用。
# 注: 二重引用符内でも $(...) は有効なため、コマンド置換検出には使わないこと。
_explain_strip_quoted() {
  printf '%s' "$1" | sed -E \
    -e 's/"[^"]*"/ /g' \
    -e "s/'[^']*'/ /g"
}

# 単一引用符 のみ の内側テキストをスペースに置換して返す。
# コマンド置換($(...) `...` <(...))の検出前処理に使用。
# 二重引用符内では $(...)/backtick がアクティブなため二重引用符は除去しない。
_explain_strip_single_quoted() {
  printf '%s' "$1" | sed -E "s/'[^']*'/ /g"
}

# stderr リダイレクト(2> 2>> のみ)かどうかを判定するヘルパ。
# 除外するのは 2> / 2>> のみ。
# 1> / 1>> / &> / &>> は content-write として検出する(標準出力・両出力をファイルに書く)。
_explain_is_stderr_redir() {
  case "$1" in
    '2>'*|'2>>'*) return 0 ;;
    *) return 1 ;;
  esac
}

# セグメント文字列からリダイレクト先(content-write)を抽出する。
# 除外: 2>/2>> (stderr のみ)。引用符内の > も除外。
# 検出: bare>/>> / 1>/1>> / Nfd>/Nfd>> / &>/&>> から対象を抽出。
# 引用符付き対象("out file.txt")は引用符を除去して返す。
# 元文字列を使ってトークン境界と引用符を同時に処理する。
_explain_redir_target() {
  printf '%s' "$1" | awk '
    # 引用符スパンを認識しながらトークンを取り出す
    function next_token(str, pos,    c, q, t) {
      # skip spaces
      while (pos<=length(str) && substr(str,pos,1)==" ") pos++
      if (pos>length(str)) return ""
      t=""; q=""
      while (pos<=length(str)) {
        c=substr(str,pos,1)
        if (q!="") {
          if (c==q) { q=""; pos++; continue }
          t=t c; pos++; continue
        }
        if (c=="\"" || c=="'"'"'") { q=c; pos++; continue }
        if (c==" ") break
        t=t c; pos++
      }
      return t
    }
    {
      pos=1; len=length($0)
      while (pos<=len) {
        # skip spaces
        while (pos<=len && substr($0,pos,1)==" ") pos++
        if (pos>len) break
        # read token with quote awareness
        t=""; raw=""; q=""
        spos=pos
        while (pos<=len) {
          c=substr($0,pos,1)
          if (q!="") {
            if (c==q) { q=""; pos++; continue }
            t=t c; pos++; continue
          }
          if (c=="\"" || c=="'"'"'") { q=c; pos++; continue }
          if (c==" ") break
          t=t c; pos++
        }
        # t is the dequoted token
        # 2>/2>> はスキップ
        if (t ~ /^2>>?([^>]|$)/) continue
        # standalone 任意fd> / &> / bare > → 次のトークン(dequoted)がターゲット
        if (t ~ /^[0-9]*>>?$/ || t ~ /^&>>?$/) {
          tgt=next_token($0, pos)
          if (tgt!="") { print tgt; exit }
        }
        # Nfd>payload / &>payload 連結 → 先頭 fd/& と > を取り除いたもの
        if ((t ~ /^[0-9]+>>?[^>]/ || t ~ /^&>>?[^>]/) && t !~ /^2>>?/) {
          sub(/^([0-9]+|&)>>?/, "", t); print t; exit
        }
        # bare >file (2> 以外)
        if (t ~ /^>>?[^>]/ && t !~ /^2>>?/) {
          sub(/^>>?/, "", t); print t; exit
        }
      }
    }
  ' | head -n1
}

# セグメントに content-write リダイレクトが含まれるか判定。
# 除外: 2>/2>> (stderr のみ) と引用符内の >
# 検出: bare >/>> / 1>/1>> / &>/&>> / 3> / 9> など任意数字 fd (standalone or 連結形)
# RED1: 2> のみ除外。他の数字 fd (1>,3>,9> 等) は content-write として検出する。
_explain_has_redir() {
  local stripped
  stripped="$(_explain_strip_quoted "$1")"
  printf '%s' "$stripped" | awk '
    {
      n=split($0, tok, /[[:space:]]+/)
      for (i=1; i<=n; i++) {
        t=tok[i]
        # 2>/2>> (stderr のみ) はスキップ — それ以外の数字 fd は content-write
        if (t ~ /^2>>?([^>]|$)/) continue
        # bare > / >> / 任意数字fd> / &> standalone
        if (t ~ /^[0-9]*>>?$/ || t ~ /^&>>?$/) { print "1"; exit }
        # >file / Nfd>file / &>file 連結形 (2> 以外)
        if ((t ~ /^[0-9]*>>?[^>]/ || t ~ /^&>>?[^>]/) && t !~ /^2>>?/) {
          print "1"; exit
        }
      }
      print "0"
    }
  ' | grep -q '^1$'
}

# 対象抽出。カテゴリ別の補正ルール:
#   category=grep/findstr/select-string/sls → 最初の非フラグ位置引数を2番目以降から探す(第1引数=パターン除外)
#   category=chmod/chown/icacls → mode(数字/記号)を除外してpath
#   category=del → / スイッチを除外
#   > リダイレクト演算子+直後トークンを対象候補から除外(全カテゴリ)
#   fd リダイレクト(2>/dev/null 等)を除外
# $env:... や変数はそのまま返す。取れなければ空。
_explain_target() {
  local seg="$1" cat="$2"
  printf '%s' "$seg" | awk -v cat="$cat" '
    # 文字列全体を走査して引用符内テキストを空白に置換する
    function strip_quoted(s,    r,i,c,in_dq,in_sq) {
      r=""; in_dq=0; in_sq=0
      for (i=1;i<=length(s);i++) {
        c=substr(s,i,1)
        if (c=="\"" && !in_sq) { in_dq=!in_dq; r=r c; continue }
        if (c=="'"'"'" && !in_dq) { in_sq=!in_sq; r=r c; continue }
        if (in_dq || in_sq) { r=r " "; continue }
        r=r c
      }
      return r
    }
    {
      # 引用符内の > をスペースに置換した版でトークン境界を計算
      sq=strip_quoted($0)
      n=split(sq, tok, /[[:space:]]+/)
      # 元の入力からも同じ区切りでトークンを取る（位置対応のため）
      split($0, orig, /[[:space:]]+/)
      # リダイレクト演算子とその後トークンを除外インデックスに登録
      # 除外(無視): 2>/2>> (stderr のみ)
      # 検出してredir_idxに入れる: >/>>/ 1>/1>>/&>/&>> (content-write)
      delete redir_idx
      for (i=1; i<=n; i++) {
        t=tok[i]
        # 全種リダイレクト(2> を含む)を対象候補から除外
        # 2>/2>> はスキップのみ(content-write 解説は出ない)
        if (t ~ /^2>>?([^>]|$)/) { redir_idx[i]=1; continue }
        # standalone 任意fd> / &> / bare > → このトークンと次トークンを除外
        if (t ~ /^[0-9]*>>?$/ || t ~ /^&>>?$/) {
          redir_idx[i]=1
          if (i+1<=n) redir_idx[i+1]=1
        }
        # Nfd>file / &>file / >file 連結形 → このトークンだけ除外
        if ((t ~ /^[0-9]*>>?[^>]/ || t ~ /^&>>?[^>]/) && t !~ /^2>>?/) {
          redir_idx[i]=1
        }
        # 入力リダイレクト < << <> → このトークンと次トークンを除外(< が対象にならないよう)
        if (t ~ /^<<?(>|$)/ || t ~ /^<$/) {
          redir_idx[i]=1
          if (i+1<=n) redir_idx[i+1]=1
        }
        # <file 連結形
        if (t ~ /^<[^<>(]/ && t !~ /^\$\(/ && t !~ /^<\(/) {
          redir_idx[i]=1
        }
      }

      # URL を tok(strip済み)で確認しつつ orig から返す
      for (i=1; i<=n; i++) {
        if (redir_idx[i]) continue
        if (orig[i] ~ /^https?:\/\//) { print orig[i]; exit }
      }
      # 名前付き -Path/-LiteralPath/-Destination/-Url の次 (tok で確認, orig で返す)
      for (i=2; i<=n; i++) {
        if (redir_idx[i]) continue
        lf=tolower(tok[i])
        if (lf=="-path"||lf=="-literalpath"||lf=="-destination"||lf=="-url"||lf=="-uri") {
          for (j=i+1; j<=n; j++) {
            if (!redir_idx[j]) { print orig[j]; exit }
          }
        }
      }
      # カテゴリ別 positional 抽出（動詞=$1 を除く）
      skip=0
      if (cat=="grep" || cat=="findstr" || cat=="select-string" || cat=="sls") {
        skip=1  # 第1位置引数(パターン)をスキップ
      }
      pos=0; cmd_depth=0
      for (i=2; i<=n; i++) {
        if (redir_idx[i]) continue
        t=orig[i]    # 元の文字列からターゲットを返す
        ts=tok[i]    # stripped 版でフラグ判定
        # コマンド置換の depth 管理: $( や <( で depth++、対応 ) で depth--
        if (ts ~ /^\$\(/ || ts ~ /^<\(/) { cmd_depth++; continue }
        if (cmd_depth > 0) {
          # 閉じ ) を探して depth 調整
          if (index(ts, ")") > 0) { cmd_depth--; }
          continue
        }
        # - フラグ除外
        if (substr(ts,1,1)=="-") continue
        # / スイッチ除外 (Windows del /s /q など)
        if (cat=="del" && substr(ts,1,1)=="/") continue
        # 空白のみ(引用符トークンが strip された)はスキップ
        if (ts ~ /^[[:space:]]*$/) { pos++; if (pos<=skip) continue; skip=skip+1; continue }
        # chmod/chown の mode 除外 (数字のみ or ugoa+rwx 形式の完全一致・絶対パスは除外しない)
        if ((cat=="chmod"||cat=="chown") && substr(ts,1,1)!="/" && \
            (ts ~ /^[0-9]+$/ || ts ~ /^[ugoa]*[+\-=][rwxst,ugoa]+$/)) continue
        pos++
        if (pos <= skip) continue
        # m3: 引用符で始まるトークンは閉じ引用符まで連結し、引用符を除去して返す
        if (substr(t,1,1)=="\"" || substr(t,1,1)=="'"'"'") {
          q=substr(t,1,1)
          if (substr(t,length(t),1)==q && length(t)>=2) {
            # 単一トークンで完結: "foo" → foo
            res=substr(t,2,length(t)-2); print res; exit
          }
          # 複数トークンにまたがる: "my file.txt" → my file.txt
          res=substr(t,2)
          for (j=i+1; j<=n; j++) {
            p=index(orig[j],q)
            if (p > 0) {
              res=res " " substr(orig[j],1,p-1); break
            }
            res=res " " orig[j]
          }
          print res; exit
        }
        print t; exit
      }
      print ""
    }
  '
}

# 対象表示用。空なら「現在のフォルダ」。
_explain_target_display() {
  if [ -z "$1" ]; then printf '現在のフォルダ'; else printf '%s' "$1"; fi
}

# ────────────────────────────────────────────────────────────
# 全セグメント走査: danger/write/exec/sudo/delete/readonly フラグを設定する。
# グローバル変数（_ecf_ プレフィックス）に書き込む。
# ────────────────────────────────────────────────────────────
_explain_scan_flags() {
  local full="$1"
  _ecf_sudo=0
  _ecf_delete=0
  _ecf_delete_recurse=0
  _ecf_write=0     # 書き込み系動詞 or content-write リダイレクト
  _ecf_exec=0      # 実行系動詞
  _ecf_perm=0      # 権限変更
  _ecf_any_redir=0 # 全文に何らかのリダイレクト(> < << <> 等)が1つでもある
  _ecf_cmd_subst=0 # コマンド置換 $(...) <(...) `...` が含まれる
  _ecf_ro_verb=1   # 全動詞が read-only カテゴリ(list/read/search/cd)のみ
  _ecf_compound=0  # パイプ/連結(| ; && ||)が含まれる

  # コマンド置換の検出:
  # 単一引用符外に $( / <( / ` があれば検出する。
  # 二重引用符内でも $(...)/backtick はアクティブなため、単一引用符のみ除去して検出。
  local stripped_for_subst
  stripped_for_subst="$(_explain_strip_single_quoted "$full")"
  if printf '%s' "$stripped_for_subst" | grep -qE -- '(\$\(|<\(|`)'; then
    _ecf_cmd_subst=1
  fi

  # 任意のリダイレクト演算子(> >> < << <> 等)の存在チェック(安心文禁止トリガー)
  # 両引用符を除去してから検出(引用符内の > < は literal)
  local stripped_for_redir
  stripped_for_redir="$(_explain_strip_quoted "$full")"
  if printf '%s' "$stripped_for_redir" | grep -qE -- '(>>?|[0-9]>>?|&>>?|<+)'; then
    _ecf_any_redir=1
  fi

  # 区切り(| ; && || & 改行)の存在チェック(安心文禁止トリガー)
  # _explain_split_segments の出力が2セグメント以上あれば複合コマンドとみなす。
  # これにより | ; && || & 改行 を全て正確に検出できる。
  local seg_count
  seg_count="$(_explain_split_segments "$full" | wc -l | tr -d ' ')"
  if [ "${seg_count:-0}" -gt 1 ] 2>/dev/null; then
    _ecf_compound=1
  fi

  local seg verb_lc lc_seg
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    seg="$(_explain_strip_sudo_flag "$seg")"
    verb_lc="$(printf '%s' "$seg" | awk '{ print tolower($1) }')"
    lc_seg="$(printf '%s' "$seg" | tr '[:upper:]' '[:lower:]')"

    # sudo / 権限昇格
    case " $(_orig_seg_lc "$1") " in
      *" sudo "*) _ecf_sudo=1 ;;
    esac
    if printf '%s' "$lc_seg" | grep -qE -- '(runas|\-verb[[:space:]]+runas)'; then _ecf_sudo=1; fi

    # content-write リダイレクト(2> 除く)→ write フラグ
    if _explain_has_redir "$seg"; then _ecf_write=1; fi

    # reassurance-safe 集合: フラグでも絶対に実行/書き込みできない純粋リーダーのみ。
    # 除外理由: file -C(magic DB 書込) / date <arg>(時刻設定) / more/less(!cmd でshell out)
    # find/grep/awk/sed 等は -exec/-w 等でexec/write 可能なため除外する。
    # このフラグが 0 の時は安心文「見るだけ・しません」を出さない。
    case "$verb_lc" in
      ls|dir|get-childitem|gci|ll|la|\
cat|type|get-content|gc|head|tail|\
wc|stat|pwd|whoami) ;;
      *) _ecf_ro_verb=0 ;;
    esac

    case "$verb_lc" in
      # 削除動詞
      rm|rmdir|del|erase|remove-item|ri)
        _ecf_delete=1
        # 削除動詞 + 再帰フラグ: 語境界を考慮
        # rm に -r/-f/-rf/-fr/-recursive、Remove-Item に -recurse、del に /s
        if printf '%s' "$lc_seg" | grep -qE -- '(\brm\b.*[[:space:]]-[a-z]*r[a-z]*|remove-item.*[[:space:]]-recurse|\bdel\b.*/s\b)'; then
          _ecf_delete_recurse=1
        fi
        # find -delete, xargs rm
        ;;
      # 書き込み系
      touch|new-item|set-content|out-file|add-content|tee|echo|printf|mv|move|move-item|cp|copy|copy-item)
        _ecf_write=1
        ;;
      # 実行系
      bash|sh|zsh|python|python3|node|source|invoke-expression|iex|start-process)
        _ecf_exec=1
        ;;
      # call operator (PowerShell &)
      '&')
        _ecf_exec=1
        ;;
      # 権限変更
      chmod|chown|icacls|set-acl|set-itemproperty)
        _ecf_perm=1
        ;;
    esac
    # xargs rm: xargs が先頭 verb でその引数に rm が来る時のみ削除扱い
    # (引数の中に "xargs rm" が含まれるだけでは削除扱いしない)
    if [ "$verb_lc" = "xargs" ] && printf '%s' "$lc_seg" | grep -qE -- '\bxargs\b[[:space:]]+(\-[^ ]+ +)*rm\b'; then
      _ecf_delete=1
      if printf '%s' "$lc_seg" | grep -qE -- '\bxargs\b[[:space:]]+(\-[^ ]+ +)*rm\b.*[[:space:]]-[a-z]*r'; then
        _ecf_delete_recurse=1
      fi
    fi
    # find -delete → 削除
    if [ "$verb_lc" = "find" ] && printf '%s' "$lc_seg" | grep -qE -- '[[:space:]]-delete\b'; then
      _ecf_delete=1
    fi
    # find -exec/-execdir/-ok/-okdir → 実行(任意コマンドを呼ぶ)
    if [ "$verb_lc" = "find" ] && printf '%s' "$lc_seg" | grep -qE -- '[[:space:]]-(exec|execdir|ok|okdir)\b'; then
      _ecf_exec=1
    fi
  done <<EOF
$(_explain_split_segments "$full")
EOF
}

# 全文を小文字化（ヘルパ）
_orig_seg_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# sudo 除去（フラグスキャン内部用。戻り値版）
_explain_strip_sudo_flag() {
  printf '%s' "$1" | awk '{ if (tolower($1)=="sudo" && NF>=2) { $1=""; sub(/^[[:space:]]+/,""); print } else print }'
}

# ────────────────────────────────────────────────────────────
# メイン公開関数
# ────────────────────────────────────────────────────────────
explain_command() {
  local full="$1"
  EXPLAIN_WHATDO=""
  EXPLAIN_ICON="📂"
  EXPLAIN_DANGER=""
  [ -z "$full" ] && return 0

  # 全セグメントを走査してフラグを確定
  _ecf_sudo=0; _ecf_delete=0; _ecf_delete_recurse=0
  _ecf_write=0; _ecf_exec=0; _ecf_perm=0
  _ecf_any_redir=0; _ecf_cmd_subst=0; _ecf_ro_verb=1; _ecf_compound=0
  _explain_scan_flags "$full"

  # 主コマンド(先頭セグメント)の動詞を先に取得(DANGER 組み立てで参照)
  local first_seg verb verb_lc
  first_seg="$(printf '%s' "$full" | _explain_split_segments_first)"
  first_seg="$(_explain_strip_sudo "$first_seg")"
  verb="$(_explain_verb "$first_seg")"
  verb_lc="$(printf '%s' "$verb" | tr '[:upper:]' '[:lower:]')"

  # EXPLAIN_DANGER の組み立て (危険度降順・重複しないよう条件を分ける)
  local dangers=""
  _danger_append() { dangers="${dangers:+$dangers
}$1"; }
  if [ "$_ecf_sudo" -eq 1 ]; then
    _danger_append "⚠️ 管理者権限への昇格を含みます（PC全体に影響する可能性）"
  fi
  if [ "$_ecf_delete_recurse" -eq 1 ]; then
    _danger_append "⚠️ フォルダごとの完全削除（復元できません）を含みます"
  elif [ "$_ecf_delete" -eq 1 ]; then
    _danger_append "⚠️ ファイル・フォルダの削除を含みます"
  fi
  if [ "$_ecf_exec" -eq 1 ] && [ "$_ecf_sudo" -eq 0 ]; then
    case "$verb_lc" in
      bash|sh|zsh|python|python3|node|source|invoke-expression|iex|start-process|'&') ;;
      *) _danger_append "⚠️ スクリプト/プログラムの実行を含みます" ;;
    esac
  fi
  # RED2: コマンド置換が含まれる場合、内側の実行/削除動詞を best-effort で警告
  if [ "$_ecf_cmd_subst" -eq 1 ]; then
    _danger_append "（コマンド内に別のコマンドが埋め込まれています。全文を確認してください）"
  fi
  EXPLAIN_DANGER="$dangers"

  # ホワイトリスト方式の readonly_all:
  # 以下を全て満たす「単一の単純な読み取りコマンド」の時のみ安心文を出す。
  # 1. 全動詞が reassurance-safe 集合(ls/cat/head/tail 等の純粋リーダー)のみ
  #    find/grep/awk/sed 等は -exec/-w 等でexec/write 可能なため対象外
  # 2. 任意のリダイレクトが一切ない(> < << 等。2> 含む)
  # 3. コマンド置換が一切ない($(...) `...` <(...))
  # 4. パイプ/連結が一切ない(| ; && ||)
  # 5. delete/exec/sudo/perm/write フラグが全て 0
  local readonly_all=0
  if [ "$_ecf_sudo" -eq 0 ] && [ "$_ecf_delete" -eq 0 ] && \
     [ "$_ecf_write" -eq 0 ] && [ "$_ecf_exec" -eq 0 ] && [ "$_ecf_perm" -eq 0 ] && \
     [ "$_ecf_any_redir" -eq 0 ] && [ "$_ecf_cmd_subst" -eq 0 ] && \
     [ "$_ecf_compound" -eq 0 ] && [ "$_ecf_ro_verb" -eq 1 ]; then
    readonly_all=1
  fi

  # 複合コマンドか判定(is_compound は extra メッセージ用)
  local is_compound=0
  [ "$_ecf_compound" -eq 1 ] && is_compound=1

  # > リダイレクト先(全文から最初の >)
  local redir_tgt
  redir_tgt="$(_explain_redir_target "$full")"

  # 全文に > リダイレクトがあれば書き込み解説に差し替え
  if [ -n "$redir_tgt" ] && _explain_has_redir "$full"; then
    EXPLAIN_ICON="✏️"
    local redir_op="書き込み(上書き)"
    if printf '%s' "$full" | grep -qE -- '>>'; then redir_op="追記"; fi
    EXPLAIN_WHATDO="${redir_tgt} にファイルを${redir_op}しようとしています。"
    [ "$is_compound" -eq 1 ] && EXPLAIN_WHATDO="${EXPLAIN_WHATDO}（ほかにも処理が続きます。全文は上のコマンドを確認してください）"
    return 0
  fi

  local target tdisp
  target="$(_explain_target "$first_seg" "$verb_lc")"
  tdisp="$(_explain_target_display "$target")"

  # 複合時の一言(リダイレクトなし複合)
  local extra=""
  [ "$is_compound" -eq 1 ] && extra="（ほかにも処理が続きます。全文は上のコマンドを確認してください）"

  case "$verb_lc" in
    # 一覧
    ls|dir|get-childitem|gci|ll|la)
      EXPLAIN_ICON="📂"
      if [ "$readonly_all" -eq 1 ]; then
        EXPLAIN_WHATDO="${tdisp} の中のファイル・フォルダ一覧を見ようとしています。（中身を見るだけ。削除や書き換えはしません）"
      else
        EXPLAIN_WHATDO="${tdisp} の中のファイル・フォルダ一覧を見ようとしています。"
      fi
      ;;
    # 読む(純粋リーダー。フラグで exec/write 不可のもの)
    cat|head|tail|less|more|type|get-content|gc|wc|file|stat|pwd|whoami|date)
      EXPLAIN_ICON="📄"
      if [ "$readonly_all" -eq 1 ]; then
        EXPLAIN_WHATDO="${tdisp} の中身を読もうとしています。（読むだけ。書き換えはしません）"
      else
        EXPLAIN_WHATDO="${tdisp} の中身を読もうとしています。"
      fi
      ;;
    # 削除
    rm|rmdir|del|erase|remove-item|ri)
      EXPLAIN_ICON="🗑"
      EXPLAIN_WHATDO="${tdisp} を削除しようとしています。"
      ;;
    # 書く/作る
    touch|new-item|set-content|out-file|add-content|tee)
      EXPLAIN_ICON="✏️"
      EXPLAIN_WHATDO="${tdisp} を作成または書き換えようとしています。"
      ;;
    echo|printf)
      EXPLAIN_ICON="📄"
      EXPLAIN_WHATDO="画面に文字を表示しようとしています。"
      ;;
    # 移動/コピー
    mv|move|move-item)
      EXPLAIN_ICON="📦"
      EXPLAIN_WHATDO="${tdisp} を別の場所に移動しようとしています。"
      ;;
    cp|copy|copy-item)
      EXPLAIN_ICON="📦"
      EXPLAIN_WHATDO="${tdisp} を別の場所にコピーしようとしています。"
      ;;
    # ダウンロード/通信
    curl|wget|invoke-webrequest|iwr|invoke-restmethod|irm|nc|ncat|netcat)
      EXPLAIN_ICON="🌐"
      if [ -n "$target" ]; then
        EXPLAIN_WHATDO="${target} とインターネット通信（ダウンロードまたは送信）をしようとしています。"
      else
        EXPLAIN_WHATDO="インターネット通信（ダウンロードまたは送信）をしようとしています。"
      fi
      ;;
    # インストール
    npm|pip|pip3|winget|choco|brew|apt|apt-get|yum|gem)
      if printf '%s' "$first_seg" | grep -Eqi -- '(^|[[:space:]])(install|add|i)([[:space:]]|$)'; then
        EXPLAIN_ICON="📥"
        local pkg
        pkg="$(printf '%s' "$first_seg" | awk '{for(i=3;i<=NF;i++){if(substr($i,1,1)!="-"){print $i;exit}}}')"
        [ -z "$pkg" ] && pkg="パッケージ"
        EXPLAIN_WHATDO="${pkg} をインターネットからインストール（PC に新しいプログラムを追加）しようとしています。"
      else
        EXPLAIN_ICON="⚙️"
        EXPLAIN_WHATDO="${verb} コマンドを実行しようとしています。"
      fi
      ;;
    # 実行
    bash|sh|zsh|python|python3|node|source|invoke-expression|iex|start-process|'&')
      EXPLAIN_ICON="⚙️"
      EXPLAIN_WHATDO="${tdisp} を実行しようとしています。（別のプログラムやスクリプトを動かします）"
      ;;
    # 権限変更
    chmod|chown|icacls|set-acl|set-itemproperty)
      EXPLAIN_ICON="🔑"
      EXPLAIN_WHATDO="${tdisp} のアクセス権限や設定を変更しようとしています。"
      ;;
    # 移動(cd)
    cd|set-location|sl|pushd)
      EXPLAIN_ICON="📁"
      EXPLAIN_WHATDO="作業フォルダを ${tdisp} に移動しようとしています。"
      ;;
    # 検索
    grep|findstr|select-string|sls|find)
      EXPLAIN_ICON="🔍"
      if [ "$readonly_all" -eq 1 ]; then
        EXPLAIN_WHATDO="${tdisp} から文字列やファイルを検索しようとしています。（読むだけ。書き換えはしません）"
      else
        EXPLAIN_WHATDO="${tdisp} から文字列やファイルを検索しようとしています。"
      fi
      ;;
    *)
      EXPLAIN_WHATDO=""
      ;;
  esac

  # extra を本文末尾に添える
  if [ -n "$EXPLAIN_WHATDO" ] && [ -n "$extra" ]; then
    EXPLAIN_WHATDO="${EXPLAIN_WHATDO}${extra}"
  fi
  return 0
}

# 全セグメントの先頭を1行だけ返す（_explain_split_segments のパイプ版ヘルパ）。
_explain_split_segments_first() {
  awk '
    BEGIN { seg="" }
    {
      L=length($0)
      for (i=1;i<=L;i++) {
        c=substr($0,i,1)
        c2=substr($0,i,2)
        if (c=="\n" || c=="|" || c==";") {
          gsub(/^[[:space:]]+/,"",seg); gsub(/[[:space:]]+$/,"",seg)
          if (seg!="") { print seg; exit }
          seg=""
        } else if (c2=="&&" || c2=="||") {
          gsub(/^[[:space:]]+/,"",seg); gsub(/[[:space:]]+$/,"",seg)
          if (seg!="") { print seg; exit }
          seg=""
          i++
        } else if (c=="&" && c2!="&&" && c2!="&>") {
          gsub(/^[[:space:]]+/,"",seg); gsub(/[[:space:]]+$/,"",seg)
          if (seg!="") { print seg; exit }
          seg=""
        } else {
          seg=seg c
        }
      }
      gsub(/^[[:space:]]+/,"",seg); gsub(/[[:space:]]+$/,"",seg)
      if (seg!="") print seg
    }
  '
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

# now.html を原子書換で書き出す。
# 引数: icon title body_risk ts card_id body_html_path action_text action_label
write_now_html() {
  local icon="$1" title="$2" body_risk="$3" ts="$4" card_id="$5" body_html_path="$6"
  local action_text="${7:-}" action_label="${8:-操作}"
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
    if [ -n "$action_text" ]; then
      printf '<div class="action">\n'
      printf '<div class="action-label">🤖 AI がしようとしていること（%s）</div>\n' "$(html_escape "$action_label")"
      printf '<pre class="action-cmd">%s</pre>\n' "$(html_escape "$action_text")"
      printf '</div>\n'
      # 「これは何をする？」具体解説（bash モードのみ・決定的・LLM不要）。
      if [ "${MODE:-}" = "bash" ]; then
        explain_command "$action_text" 2>/dev/null || true
        if [ -n "$EXPLAIN_WHATDO" ] || [ -n "$EXPLAIN_DANGER" ]; then
          printf '<div class="whatdo">\n'
          if [ -n "$EXPLAIN_WHATDO" ]; then
            printf '<div class="whatdo-label">%s これは何をする？</div>\n' "$(html_escape "$EXPLAIN_ICON")"
            printf '<p class="whatdo-body">%s</p>\n' "$(html_escape "$EXPLAIN_WHATDO")"
          fi
          if [ -n "$EXPLAIN_DANGER" ]; then
            # 複数行 danger を各 <p> に分けて出力（subshell 回避のため awk で処理）
            printf '%s\n' "$EXPLAIN_DANGER" | awk '
              NF>0 {
                line=$0
                gsub(/&/,"\\&amp;",line); gsub(/</,"\\&lt;",line)
                gsub(/>/,"\\&gt;",line); gsub(/"/,"\\&quot;",line)
                print "<p class=\"whatdo-danger\">" line "</p>"
              }
            '
          fi
          printf '</div>\n'
        fi
      fi
    fi
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

# 引数: card_id risk_default action_text action_label
write_now_card() {
  local card_id="$1"
  local risk_default="$2"
  local action_text="${3:-}"
  local action_label="${4:-操作}"
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
    printf '[%s  tool=%s  card=%s]\n' "$ts" "$MODE" "$card_id"
    # 実際の操作を最上部に表示（コンソール monitor が読む）。
    if [ -n "$action_text" ]; then
      printf '\n▶ %s:\n  %s\n' "$action_label" "$action_text"
      # 「これは何をする？」具体解説（bash モードのみ）。
      if [ "$MODE" = "bash" ]; then
        explain_command "$action_text" 2>/dev/null || true
        if [ -n "$EXPLAIN_WHATDO" ]; then
          printf '%s これは何をする？\n  %s\n' "$EXPLAIN_ICON" "$EXPLAIN_WHATDO"
        fi
        [ -n "$EXPLAIN_DANGER" ] && printf '  %s\n' "$EXPLAIN_DANGER"
      fi
    fi
    printf '\n'
    strip_frontmatter "$body_path"
  } > "$out"
  if [ -f "$out" ] && [ -O "$out" ]; then
    chmod 600 "$out" 2>/dev/null || true
  fi
  # now.html を「並立」出力 (now.md は上で確定済み・不変)。失敗しても explain を止めない。
  write_now_html "$icon" "$title" "$body_risk" "$ts" "$card_id" "$body_path" \
    "$action_text" "$action_label" 2>/dev/null || true
  umask "$prev_umask"
  printf '%s' "$card_id"
}

# ----- 公開 API ----------------------------------------------------------

# explain: tool 名と引数から最適なカードを選んで now.md を更新し、
# audit_log に decision="explain" のエントリを追加する。
# どこかで失敗してもポリシー判定を止めないように常に成功する。
explain() {
  {
    local target hit card_id risk written action_raw action_text action_label
    target="$(extract_target)"
    hit="$(lookup_card "$target" 2>/dev/null)"
    if [ -n "$hit" ]; then
      card_id="$(printf '%s' "$hit" | cut -f1)"
      risk="$(printf '%s' "$hit" | cut -f2)"
    else
      card_id="default-$MODE"
      risk="low"
    fi
    # 実際の操作文字列を抽出（グローバル変数 ACTION_TEXT/ACTION_LABEL に格納）。
    # F-K: TAB round-trip 破壊を避けるためグローバル変数経由。
    ACTION_TEXT=""; ACTION_LABEL="操作"
    extract_action_text 2>/dev/null || true
    written="$(write_now_card "$card_id" "$risk" "$ACTION_TEXT" "$ACTION_LABEL" 2>/dev/null || true)"
    if [ -n "$written" ]; then
      audit_log "explain" "card=$written risk=$risk"
    fi
  } 2>/dev/null || true
  return 0
}
