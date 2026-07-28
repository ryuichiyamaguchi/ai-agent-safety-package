#!/usr/bin/env bash
# =============================================================
# release-version-check.sh
# SSOT: policy/safety-policy.json の packageVersion
# active docs の version 表記と SSOT が一致しているか検査する。
# exit 0: 全 OK or WARN のみ
# exit 1: FAIL あり（release blocker）
#
# FAIL 対象:
#   active docs / installer / templates のうち、
#   「このドキュメントは vX.Y.Z 向け」「パッケージ vX.Y.Z」等の
#   現行バージョン識別子がSSOTと一致しない行
#
# WARN のみ (exit code に影響しない):
#   - 引用ブロック内 (> で始まる行)
#   - changelog 風 Markdown 見出し (## vX.Y.Z ...)
#   - 「vX.Y.Z で追加」「vX.Y.Z から」「vX.Y.Z 以降」等の機能追加記述
#   - v0.X.X 形式 (CLI ツール自体のバージョン番号)
#   - docs/tested_versions.md 全体
#   - .sena/engagements/ 配下
#   - CHANGELOG.md 全体
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY_JSON="$PKG_ROOT/policy/safety-policy.json"

# ------------------------------------------------------------------
# 1. SSOT を取得
# ------------------------------------------------------------------
if [ ! -f "$POLICY_JSON" ]; then
  echo "[FAIL] policy/safety-policy.json が見つかりません (exit 2 相当)"
  exit 1
fi

if command -v /usr/bin/plutil &>/dev/null; then
  SSOT_VERSION="$(/usr/bin/plutil -extract packageVersion raw -o - "$POLICY_JSON" 2>/dev/null || true)"
elif command -v jq &>/dev/null; then
  SSOT_VERSION="$(jq -r '.packageVersion' "$POLICY_JSON" 2>/dev/null || true)"
else
  # fallback: grep
  SSOT_VERSION="$(grep -o '"packageVersion"[[:space:]]*:[[:space:]]*"[^"]*"' "$POLICY_JSON" \
    | grep -o '"[^"]*"$' | tr -d '"' || true)"
fi

if [ -z "$SSOT_VERSION" ]; then
  echo "[FAIL] policy/safety-policy.json から packageVersion を取得できませんでした"
  exit 1
fi

EXPECTED="v${SSOT_VERSION}"
echo "SSOT: $EXPECTED (policy/safety-policy.json)"
echo "---"

# ------------------------------------------------------------------
# 2. スキャン対象ファイルの定義
# ------------------------------------------------------------------

# FAIL 対象: active docs / installer / templates
ACTIVE_FILES=(
  "README.md"
  "docs/00_はじめに.md"
  "docs/01_学校PCで使う.md"
  "docs/02_自宅Windowsで使う.md"
  "docs/03_自宅Macで使う.md"
  "docs/04_Cursor_でCodexとGeminiを起動.md"
  "docs/05_Claude_Codeを安全に使う.md"
  "docs/06_環境変数とAPIキーって何.md"
  "docs/07_AIの動きをモニターする.md"
  "docs/08_外部LLMを安全に使う.md"
  "docs/10_OpenCode_DeepSeekを安全に使う.md"
  "docs/90_守れる-守れない.md"
  "docs/92_AIの仕組みと隔離技術.md"
  "docs/99_known_issues.md"
  "workspace-template/AGENTS.md"
  "scripts/macos/install-one-click.command"
  "scripts/windows/install-one-click.bat"
)

# ------------------------------------------------------------------
# 3. ヘルパー関数
# ------------------------------------------------------------------

FAIL_COUNT=0
WARN_COUNT=0
OK_COUNT=0

# バージョン表記が「現行パッケージのバージョン識別子」かどうかを判定する。
# 機能追加・変更履歴を示す文脈 ("で追加", "から", "以降", "時点" 等) は warn 扱いにする。
is_history_context() {
  local line="$1"
  local ver="$2"

  # ver の直後に「履歴」を示すキーワードがある場合は warn
  # 例: "v1.2.1 で追加", "v1.2.1 から", "v1.4.0 以降", "v1.3.0 時点"
  # 例: "v1.2.0 から変更なし", "v1.1.0 の Security Hardening"
  # 例: "v1.3.0 は...サポート", "v1.3.0〜", "v1.3.0 で新規追加"
  if echo "$line" | grep -qE "${ver}[[:space:]]*(で|から|以降|時点|では|の|は|〜|~)"; then
    return 0
  fi

  # "v1.X.X と" "v1.X.X / v1.X.X" 形式（複数バージョンの並列記載）
  if echo "$line" | grep -qE "${ver}[[:space:]]*(と|／|/)"; then
    return 0
  fi

  # 括弧付きパターンのうち、「〜」や「で」を含むもの: （v1.X.X〜）, （v1.X.X で）
  # 単なる (v1.X.X) や （v1.X.X） は現行バージョン識別子として OK/FAIL 対象のまま
  if echo "$line" | grep -qE "[（(]${ver}[[:space:]]*(〜|~|で|から|以降|時点)"; then
    return 0
  fi

  return 1
}

# ファイル内の version 表記をスキャンして分類する
# 引数: $1=ファイルパス(PKG_ROOT 相対) $2=fail_mode(fail|warn)
scan_file() {
  local rel_path="$1"
  local mode="$2"
  local abs_path="$PKG_ROOT/$rel_path"

  if [ ! -f "$abs_path" ]; then
    return
  fi

  # BAT は CP932 の可能性があるので UTF-8 に変換してスキャン
  local content
  if [[ "$rel_path" == *.bat ]]; then
    content="$(iconv -f CP932 -t UTF-8 "$abs_path" 2>/dev/null || cat "$abs_path")"
  else
    content="$(cat "$abs_path")"
  fi

  local lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # version パターン検索 (v1.X.X 以上; v0.X.X は除外 → CLI ツールバージョン)
    versions="$(echo "$line" | grep -oE 'v[1-9][0-9]*\.[0-9]+\.[0-9]+' || true)"
    [ -z "$versions" ] && continue

    for ver in $versions; do
      # --- warn 判定 (優先順) ---

      # 1. 引用ブロック行 (> で始まる)
      if echo "$line" | grep -qE '^[[:space:]]*>'; then
        echo "[WARN] $rel_path:$lineno: $ver (archive/history/blockquote)"
        WARN_COUNT=$((WARN_COUNT + 1))
        continue
      fi

      # 2. Markdown changelog 風見出し (## v1.x.x ...)
      if echo "$line" | grep -qE '^#{1,6}[[:space:]]+v[0-9]+\.[0-9]+\.[0-9]+'; then
        echo "[WARN] $rel_path:$lineno: $ver (changelog heading)"
        WARN_COUNT=$((WARN_COUNT + 1))
        continue
      fi

      # 3. tested_versions.md の [v1.0.x] プレフィックス付き行
      if [[ "$rel_path" == "docs/tested_versions.md" ]]; then
        if echo "$line" | grep -qE '\[v[0-9]+\.[0-9]+\.x\]'; then
          echo "[WARN] $rel_path:$lineno: $ver (tested_versions archive)"
          WARN_COUNT=$((WARN_COUNT + 1))
          continue
        fi
      fi

      # 4. .sena/engagements/ 配下
      if [[ "$rel_path" == .sena/engagements/* ]]; then
        echo "[WARN] $rel_path:$lineno: $ver (engagement log)"
        WARN_COUNT=$((WARN_COUNT + 1))
        continue
      fi

      # 5. CHANGELOG.md 全体
      if [[ "$rel_path" == "CHANGELOG.md" ]]; then
        echo "[WARN] $rel_path:$lineno: $ver (changelog)"
        WARN_COUNT=$((WARN_COUNT + 1))
        continue
      fi

      # 6. 機能追加・変更履歴の文脈 ("vX.X.X で追加", "vX.X.X から" 等)
      if is_history_context "$line" "$ver"; then
        echo "[WARN] $rel_path:$lineno: $ver (feature history/context)"
        WARN_COUNT=$((WARN_COUNT + 1))
        continue
      fi

      # --- SSOT 一致チェック ---
      if [ "$ver" = "$EXPECTED" ]; then
        echo "[OK] $rel_path:$lineno: $ver"
        OK_COUNT=$((OK_COUNT + 1))
      else
        if [ "$mode" = "fail" ]; then
          echo "[FAIL] $rel_path:$lineno: $ver (active SSOT mismatch, expected $EXPECTED)"
          FAIL_COUNT=$((FAIL_COUNT + 1))
        else
          echo "[WARN] $rel_path:$lineno: $ver (non-active, expected $EXPECTED)"
          WARN_COUNT=$((WARN_COUNT + 1))
        fi
      fi
    done
  done <<< "$content"
}

# ------------------------------------------------------------------
# 4. active ファイルをスキャン (fail mode)
# ------------------------------------------------------------------
for f in "${ACTIVE_FILES[@]}"; do
  scan_file "$f" "fail"
done

# ------------------------------------------------------------------
# 5. tested_versions.md は warn モード
# ------------------------------------------------------------------
scan_file "docs/tested_versions.md" "warn"

# ------------------------------------------------------------------
# 6. 配布スクリプトの実バイト検査（エンコーディング / 改行）
#    規約の SSOT は .gitattributes。git archive は eol 属性を適用せず blob の
#    バイト列をそのまま ZIP に入れるため、git の正規化ではなく実バイトで検査する。
#      (a) .ps1        -> UTF-8 BOM 必須
#          BOM が無い日本語 .ps1 は PowerShell 5.1 が CP932 と誤読して読込破綻する
#      (b) .bat / .cmd -> CRLF 必須
#          LF 単独の .bat は CMD が goto のラベルを見失う
#      (c) .bat / .cmd -> chcp 65001 禁止（その .bat 自身のコードページ指定のみ）
#          日本語 Windows の教室 PC では UTF-8 コードページで文字化けして即閉じになる。
#          行頭の chcp だけを見る。start で開く別ウィンドウ側を UTF-8 にする
#          用途（9_作業ウィンドウを開く.bat の ccmux 対策）は正当なので対象外。
#      (d) .bat / .cmd -> 中身が CP932 として復号できること
#          chcp 932 を宣言していても中身が UTF-8 なら教室 PC で文字化けする。
#          （同種の検査は scripts/common/test/onboarding.test.sh にもあるが、
#           あちらは入口の .bat だけが対象。ここはパッケージ内の .bat/.cmd 全部を見る）
#      (e) .ps1        -> CRLF 必須
#          .gitattributes の規約は .ps1=CRLF だが、2026-07-28 まで BOM しか検査して
#          いなかったため、LF のみ 4 本・CR/LF 混在 3 本が誰にも気づかれずに紛れ込んで
#          いた（同日に CRLF へ正規化済み）。BOM 欠落ほど致命ではないものの、
#          「検査の無い規約は必ず崩れる」ので BOM と同じ FAIL 扱いで見る。
# ------------------------------------------------------------------
echo "---"
echo "実バイト検査: .ps1 の BOM・CRLF / .bat・.cmd の CRLF・CP932・コードページ指定"

ENC_OK=0
ENC_FAIL=0
CP932_PROBE="$(mktemp "${TMPDIR:-/tmp}/relcheck-cp932.XXXXXX")"
trap 'rm -f "$CP932_PROBE"' EXIT INT TERM

# ファイル先頭 3 バイトが UTF-8 BOM かどうか
has_bom() {
  [ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]
}

# 改行がすべて CRLF かどうか。
#
# CR と LF の個数が一致するだけでは足りない。行の途中に紛れた CR と、CR の付いていない
# LF が同数あると相殺して素通りする（例: "a<CR><LF>b<CR>c<LF>" は CR=2 LF=2 で一致して
# しまうが、実際には壊れた改行が 2 か所ある）。「LF で区切って CR で終わる行の数
# ＝ CRLF の個数」も一致することまで見る。
is_all_crlf() {
  local n_cr n_lf n_crlf
  n_cr="$(LC_ALL=C tr -dc '\r' < "$1" | wc -c | tr -d ' ')"
  n_lf="$(LC_ALL=C tr -dc '\n' < "$1" | wc -c | tr -d ' ')"
  n_crlf="$(LC_ALL=C awk 'BEGIN{RS="\n"} /\r$/{c++} END{print c+0}' "$1")"
  [ "$n_lf" -gt 0 ] && [ "$n_cr" = "$n_lf" ] && [ "$n_crlf" = "$n_lf" ]
}

while IFS= read -r -d '' f; do
  rel="${f#"$PKG_ROOT"/}"
  case "$f" in
    *.ps1)
      if has_bom "$f"; then
        ENC_OK=$((ENC_OK + 1))
      else
        echo "[FAIL] $rel: UTF-8 BOM がありません (PowerShell 5.1 が CP932 と誤読します)"
        ENC_FAIL=$((ENC_FAIL + 1))
      fi
      # .bat/.cmd と同じ判定関数を使う（LF のみも CR/LF 混在も落とす）。
      if is_all_crlf "$f"; then
        ENC_OK=$((ENC_OK + 1))
      else
        echo "[FAIL] $rel: 改行が CRLF ではありません (.gitattributes の規約は .ps1=CRLF)"
        ENC_FAIL=$((ENC_FAIL + 1))
      fi
      ;;
    *.bat|*.cmd)
      if is_all_crlf "$f"; then
        ENC_OK=$((ENC_OK + 1))
      else
        echo "[FAIL] $rel: 改行が CRLF ではありません (CMD が goto のラベルを見失います)"
        ENC_FAIL=$((ENC_FAIL + 1))
      fi
      if LC_ALL=C grep -qiE '^[[:space:]]*@?chcp[[:space:]]+65001' "$f"; then
        echo "[FAIL] $rel: 先頭で chcp 65001 を指定しています (日本語 Windows では chcp 932)"
        ENC_FAIL=$((ENC_FAIL + 1))
      else
        ENC_OK=$((ENC_OK + 1))
      fi
      # macOS の iconv は出力先が /dev/null だと "Inappropriate ioctl for device" で
      # 失敗することがあるため、実ファイルへ書き出して判定する。
      if iconv -f CP932 -t UTF-8 "$f" > "$CP932_PROBE" 2>/dev/null; then
        ENC_OK=$((ENC_OK + 1))
      else
        echo "[FAIL] $rel: 中身が CP932 として読めません (日本語 Windows で文字化けします)"
        ENC_FAIL=$((ENC_FAIL + 1))
      fi
      ;;
  esac
done < <(find "$PKG_ROOT" \
  \( -name '.git' -o -name 'node_modules' -o -name '.tmp-ui-check' \) -prune -o \
  -type f \( -name '*.ps1' -o -name '*.bat' -o -name '*.cmd' \) -print0 | LC_ALL=C sort -z)

echo "実バイト検査: OK=$ENC_OK FAIL=$ENC_FAIL"
FAIL_COUNT=$((FAIL_COUNT + ENC_FAIL))

# ------------------------------------------------------------------
# 7. ポリシー本体（決定的 deny 床）の改ざん検査
#
#    ここが空洞化すると、他の検査が全部 PASS でも「止まるはずのコマンドが止まらない
#    パッケージ」を出荷してしまう。実際に dangerousCommandRegex を 20 本から 1 本に
#    削っても、以前はこのスクリプトが PASS を返していた。
#      (a) policy/safety-policy.json の SHA-256 が docs/tested_versions.md の行と一致するか
#          （照合方法は installer の verify_hash と同じ「最初に見つかった行」）
#      (b) 決定的 deny の規則本数が期待下限を下回っていないか
#          下限なので規則の**追加**は素通しする。削減したときだけ落ちる。
#          意図して減らしたときは、この下限と docs/tested_versions.md のハッシュを
#          両方更新すること。
# ------------------------------------------------------------------
echo "---"
echo "ポリシー改ざん検査: policy/safety-policy.json のハッシュと規則本数"

POLICY_FAIL=0
VERSIONS_FILE="$PKG_ROOT/docs/tested_versions.md"

if [ ! -f "$VERSIONS_FILE" ]; then
  echo "[FAIL] docs/tested_versions.md がありません（改ざん検知の表が無い＝配布物が壊れている）"
  POLICY_FAIL=$((POLICY_FAIL + 1))
else
  expected_policy_hash="$(grep -F "| policy/safety-policy.json |" "$VERSIONS_FILE" \
    | head -n1 | awk -F'|' '{gsub(/ /,"",$3); print $3}' || true)"
  actual_policy_hash="$(shasum -a 256 "$POLICY_JSON" | awk '{print $1}')"
  if [ -z "$expected_policy_hash" ]; then
    echo "[FAIL] docs/tested_versions.md に policy/safety-policy.json のハッシュ行がありません"
    POLICY_FAIL=$((POLICY_FAIL + 1))
  elif [ "$expected_policy_hash" != "$actual_policy_hash" ]; then
    echo "[FAIL] policy/safety-policy.json が docs/tested_versions.md のハッシュと一致しません"
    echo "       表: $expected_policy_hash"
    echo "       現物: $actual_policy_hash"
    echo "       意図した変更なら docs/tested_versions.md の該当行を更新してください（installer も同じ照合で中止します）"
    POLICY_FAIL=$((POLICY_FAIL + 1))
  else
    echo "[OK] policy/safety-policy.json のハッシュが docs/tested_versions.md と一致 ($actual_policy_hash)"
  fi
fi

# 期待下限。規則の整理統合で正当に減るときは、ここと docs/tested_versions.md の
# ハッシュを両方更新すること。下限方式なので規則の追加は素通しする
# （2026-07-28 時点の現物は dangerousCommandRegex=21 / protectedPathRegex=16 /
#   redirectProtectedPathRegex=11 / secretRegex=9。redirectProtectedPathRegex は
#   同日に Windows の PowerShell プロファイル・スタートアップの 4 本を追加して 7→11）。
POLICY_MIN_RULES="dangerousCommandRegex:20 protectedPathRegex:16 redirectProtectedPathRegex:11 secretRegex:9"
if command -v python3 >/dev/null 2>&1; then
  for spec in $POLICY_MIN_RULES; do
    key="${spec%%:*}"
    min="${spec##*:}"
    n="$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d.get(sys.argv[2])
print(len(v) if isinstance(v, list) else -1)' "$POLICY_JSON" "$key" 2>/dev/null || echo -1)"
    if [ "$n" -lt 0 ]; then
      echo "[FAIL] policy/safety-policy.json の $key が配列として読めません"
      POLICY_FAIL=$((POLICY_FAIL + 1))
    elif [ "$n" -lt "$min" ]; then
      echo "[FAIL] $key の規則が $n 本しかありません（期待下限 $min 本）"
      POLICY_FAIL=$((POLICY_FAIL + 1))
    else
      echo "[OK] $key = $n 本（期待下限 $min 本）"
    fi
  done
else
  echo "[WARN] python3 が無いため規則本数の検査をスキップしました"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

echo "ポリシー改ざん検査: FAIL=$POLICY_FAIL"
FAIL_COUNT=$((FAIL_COUNT + POLICY_FAIL))

# ------------------------------------------------------------------
# 7b. 床のカナリア照合（実行時 _verify_floor_or_fail と同じ文字列）
#
#     ハッシュ照合と本数照合だけでは「ポリシーを無害化し、同時に
#     docs/tested_versions.md のハッシュ行も更新する」形を素通しする（2026-07-28 の
#     レビューで指摘）。規則の本数を保ったまま中身を無害な正規表現へ差し替えると、
#     ハッシュも本数も整合してしまう。
#
#     ガードは起動のたびに「既知の危険文字列が実際に当たるか」を見て fail-closed して
#     いる（scripts/macos/lib/safety_policy.sh の _verify_floor_or_fail）。同じ検査を
#     出荷前にも通す。カナリア文字列は書き写さず safety_policy.sh の _CANARY_* から
#     読む（書き写すと実行時と出荷前が別々に古びる）。照合方法も実行時と同じ
#     「全パターンを | で連結して grep -E -i」に揃える。
# ------------------------------------------------------------------
echo "---"
echo "床のカナリア照合: 実行時と同じ危険文字列がポリシーに当たるか"

CANARY_FAIL=0
SAFETY_LIB="$PKG_ROOT/scripts/macos/lib/safety_policy.sh"

# $1=カナリア変数名 $2=ポリシーのキー名。当たらない行があれば非 0 を返す。
check_canary() {
  local var="$1" key="$2" combined misses
  python3 - "$SAFETY_LIB" "$var" > "$CANARY_TMP/sample" <<'PYEOF' || return 1
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^%s='([^']*)'" % re.escape(sys.argv[2]), text, re.M | re.S)
if not m:
    raise SystemExit("canary not found")
sys.stdout.write(m.group(1))
PYEOF
  if [ ! -s "$CANARY_TMP/sample" ]; then
    echo "[FAIL] $var を safety_policy.sh から取り出せませんでした"
    return 1
  fi
  python3 - "$POLICY_JSON" "$key" > "$CANARY_TMP/patterns" <<'PYEOF' || return 1
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2])
if not isinstance(value, list):
    raise SystemExit("not a list")
for item in value:
    pattern = item.get("pattern") if isinstance(item, dict) else item
    if isinstance(pattern, str) and pattern:
        print(pattern)
PYEOF
  combined="$(python3 -c 'import sys
lines = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
print("|".join(lines))' "$CANARY_TMP/patterns")"
  if [ -z "$combined" ]; then
    echo "[FAIL] $key の規則が 1 本もありません"
    return 1
  fi
  misses="$(LC_ALL=C grep -E -i -v -c "$combined" < "$CANARY_TMP/sample" 2>/dev/null || true)"
  misses="$(printf '%s' "$misses" | tr -dc '0-9')"
  if [ "${misses:-1}" != "0" ]; then
    echo "[FAIL] $key が実行時カナリア($var)の ${misses} 行に当たりません（無害化された疑い）"
    return 1
  fi
  echo "[OK] $key が $var の全行に当たる"
  return 0
}

if [ ! -f "$SAFETY_LIB" ]; then
  echo "[FAIL] scripts/macos/lib/safety_policy.sh がありません（カナリアの出所が無い）"
  CANARY_FAIL=$((CANARY_FAIL + 1))
elif ! command -v python3 >/dev/null 2>&1; then
  echo "[WARN] python3 が無いためカナリア照合をスキップしました"
  WARN_COUNT=$((WARN_COUNT + 1))
else
  CANARY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/relcheck-canary.XXXXXX")"
  check_canary _CANARY_DANGEROUS dangerousCommandRegex      || CANARY_FAIL=$((CANARY_FAIL + 1))
  check_canary _CANARY_PROTECTED protectedPathRegex         || CANARY_FAIL=$((CANARY_FAIL + 1))
  check_canary _CANARY_SECRET    secretRegex                || CANARY_FAIL=$((CANARY_FAIL + 1))
  check_canary _CANARY_SECRET    outputSecretRegex          || CANARY_FAIL=$((CANARY_FAIL + 1))
  check_canary _CANARY_REDIRECT  redirectProtectedPathRegex || CANARY_FAIL=$((CANARY_FAIL + 1))
  rm -rf "$CANARY_TMP"
fi

echo "床のカナリア照合: FAIL=$CANARY_FAIL"
FAIL_COUNT=$((FAIL_COUNT + CANARY_FAIL))

# ------------------------------------------------------------------
# 8. 検証表の節順（first-match）検査
#
#    installer は同じファイルの行が複数あっても「最初に見つかった 1 行」しか見ない。
#    そのため現行版の節が最上位に無いと、過去の版のハッシュを引いて全ファイルが
#    不一致になり、誰も導入できなくなる。並び順そのものを検査して事故を防ぐ。
# ------------------------------------------------------------------
echo "---"
echo "検証表の節順検査: 各ファイルの最初の行が現行版 (v$SSOT_VERSION) の節にあるか"

ORDER_FAIL=0
if [ ! -f "$VERSIONS_FILE" ]; then
  echo "[FAIL] docs/tested_versions.md がありません"
  ORDER_FAIL=$((ORDER_FAIL + 1))
elif command -v python3 >/dev/null 2>&1; then
  order_out="$(python3 - "$VERSIONS_FILE" "$SSOT_VERSION" "$PKG_ROOT" <<'PYEOF' || true
import os, re, sys

path, ssot, pkg_root = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().splitlines()

# 現行版の節 (### v<SSOT> ...) の範囲を求める
start = None
for i, line in enumerate(lines):
    if re.match(r"^###\s+v" + re.escape(ssot) + r"(\D|$)", line):
        start = i
        break
if start is None:
    print("FAIL\t現行版 v%s の節が見つかりません" % ssot)
    raise SystemExit(0)

end = len(lines)
for i in range(start + 1, len(lines)):
    if lines[i].startswith("### ") or lines[i].startswith("## "):
        end = i
        break

# 行頭が | のハッシュ行だけを見る (> で始まる引用=過去履歴は対象外)
first = {}
for i, line in enumerate(lines):
    m = re.match(r"^\|\s*([^|]+?)\s*\|\s*[0-9a-f]{64}\s*\|", line)
    if m:
        rel = m.group(1)
        # installer は「実在するファイル」しか照合しない。配布 zip 全体の記録など、
        # ツリーに存在しない行は installer の first-match に関係しないので除外する。
        if os.path.isfile(os.path.join(pkg_root, rel)):
            first.setdefault(rel, i)

bad = [(rel, i) for rel, i in first.items() if not (start <= i < end)]
for rel, i in sorted(bad, key=lambda x: x[1]):
    print("FAIL\t%s: 最初の行が %d 行目で、現行版の節 (%d-%d 行目) の外にあります"
          % (rel, i + 1, start + 1, end))
print("INFO\t%d ファイル中 %d 件が現行版の節を先頭に持つ" % (len(first), len(first) - len(bad)))
PYEOF
)"
  while IFS=$'\t' read -r kind msg; do
    [ -z "${kind:-}" ] && continue
    if [ "$kind" = "FAIL" ]; then
      echo "[FAIL] $msg"
      ORDER_FAIL=$((ORDER_FAIL + 1))
    else
      echo "[OK] $msg"
    fi
  done <<< "$order_out"
else
  echo "[WARN] python3 が無いため節順検査をスキップしました"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

echo "検証表の節順検査: FAIL=$ORDER_FAIL"
FAIL_COUNT=$((FAIL_COUNT + ORDER_FAIL))

# ------------------------------------------------------------------
# 9. 3 エンジン横断テスト（mac / Windows / OpenCode の判定一致）
#
#    2026-07-28 のレビュー 2 巡目の総括:
#      「パターンの集合を共有していても、それを適用するコードがエンジンごとに別実装
#        である限り同じ事故が繰り返します」
#    実際、1 巡目で mac だけ直した箇所が Windows と OpenCode に届いておらず、2 巡目で
#    `echo evil> ~/.zshrc` が Windows / OpenCode だけ素通しであることが実測された。
#    エンジンごとのテストをいくら足してもこの「片側だけ直っている」型は見つからない。
#    同じ入力を 3 エンジンに流し、判定が割れていたら出荷を止める。
#
#    ⚠️ pwsh が無い環境では Windows 側を測れないので FAIL にする。
#       出荷前チェックは pwsh のある機械で回すこと（mac では brew install powershell）。
# ------------------------------------------------------------------
echo "---"
echo "3 エンジン横断テスト: 同じ入力を mac / Windows / OpenCode に流して判定が一致するか"

TRI_FAIL=0
TRI_TEST="$PKG_ROOT/scripts/common/test/tri-engine-parity.test.js"

if [ ! -f "$TRI_TEST" ]; then
  echo "[FAIL] scripts/common/test/tri-engine-parity.test.js がありません（3 エンジンの一致を誰も見ていない）"
  TRI_FAIL=$((TRI_FAIL + 1))
elif ! command -v node >/dev/null 2>&1; then
  echo "[FAIL] node が無いため 3 エンジン横断テストを実行できません"
  TRI_FAIL=$((TRI_FAIL + 1))
elif ! command -v pwsh >/dev/null 2>&1; then
  echo "[FAIL] pwsh が無いため Windows 側の判定を測れません（mac では brew install powershell）"
  TRI_FAIL=$((TRI_FAIL + 1))
else
  TRI_LOG="$(mktemp "${TMPDIR:-/tmp}/relcheck-tri.XXXXXX")"
  if node --test "$TRI_TEST" > "$TRI_LOG" 2>&1; then
    echo "[OK] 3 エンジンの判定が全ケースで一致（$(grep -cE '^\s*\{?\s*"id"' "$PKG_ROOT/scripts/common/test/tri-engine/cases.json" 2>/dev/null || echo '?') ケース）"
    # 未解消の 3 エンジン差（cases.json の knownGap）は WARN として必ず表に出す。
    while IFS= read -r line; do
      echo "[WARN] 未解消の 3 エンジン差: $line"
      WARN_COUNT=$((WARN_COUNT + 1))
    done < <(sed -n '/未解消の 3 エンジン差/,/^[^ ]/p' "$TRI_LOG" \
      | grep -E '^[[:space:]]+[a-z0-9-]+ / (mac|win|js):' \
      | sed -E 's/^[[:space:]]+//' || true)
  elif grep -q '判定が割れています\|knownGap は' "$TRI_LOG"; then
    echo "[FAIL] 3 エンジンの判定が割れています（片側だけ直っている箇所があります）"
    sed -n '/判定が割れています/,/^$/p' "$TRI_LOG" | head -40
    grep -E '直ったなら cases.json の knownGap を消すこと' "$TRI_LOG" | head -20
    echo "       詳細: node --test $TRI_TEST"
    TRI_FAIL=$((TRI_FAIL + 1))
  else
    # 判定が取れなかった場合（マシン負荷でのタイムアウト、実行の中断、ランナーの起動失敗）。
    # これを「判定が割れた」と書くと、環境の問題をパリティ崩れと読み違える嘘の失敗になる。
    # 出荷は止めるが、原因が別物であることを明示する。
    echo "[FAIL] 3 エンジンの判定を測定できませんでした（パリティが壊れたという意味ではありません）"
    grep -E '測定できませんでした|時間内に終わりませんでした|Interrupted|cancelled [1-9]|床が壊れています' "$TRI_LOG" \
      | sed -E 's/^[[:space:]]+//' | sort -u | head -10
    echo "       マシンが混んでいると 3 ランナー（本物のガードを 64 回ずつ起動）が時間内に終わりません。"
    echo "       負荷が落ち着いてから再実行してください: node --test $TRI_TEST"
    TRI_FAIL=$((TRI_FAIL + 1))
  fi
  rm -f "$TRI_LOG"
fi

echo "3 エンジン横断テスト: FAIL=$TRI_FAIL"
FAIL_COUNT=$((FAIL_COUNT + TRI_FAIL))

# ------------------------------------------------------------------
# 10. サマリ
# ------------------------------------------------------------------
echo "---"
echo "Summary: OK=$OK_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT (うち実バイト検査の FAIL=$ENC_FAIL / ポリシー改ざん検査の FAIL=$POLICY_FAIL / カナリア照合の FAIL=$CANARY_FAIL / 節順検査の FAIL=$ORDER_FAIL / 3 エンジン横断の FAIL=$TRI_FAIL)"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "RESULT: FAIL (release blocker: $FAIL_COUNT mismatch(es) found)"
  exit 1
else
  echo "RESULT: PASS"
  exit 0
fi
