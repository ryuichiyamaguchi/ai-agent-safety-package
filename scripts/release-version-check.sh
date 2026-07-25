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
# 6. サマリ
# ------------------------------------------------------------------
echo "---"
echo "Summary: OK=$OK_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "RESULT: FAIL (release blocker: $FAIL_COUNT mismatch(es) found)"
  exit 1
else
  echo "RESULT: PASS"
  exit 0
fi
