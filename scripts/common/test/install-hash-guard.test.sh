#!/bin/bash
# install-hash-guard.test.sh — 配布ハッシュ検証の抜け穴に対する回帰テスト（mac installer 実走）。
#
# 「install.ps1/install.sh にこう書いてある」ではなく、パッケージの複製に対して
# scripts/macos/install.sh を**実際に走らせて終了コードと配置結果**を見る。
#
# 守りたい退行:
#   (a) YELLOW-1: AI に読ませる指示書 (opencode-harness 配下) にハッシュ行の無い .md が
#       混入したら install を中止する。警告だけで配置してはいけない。
#   (b) Y-6: 検証表 docs/tested_versions.md 自体が無いときに、ハッシュ検証を丸ごと
#       スキップして続行してはいけない。
#   (c) 既存の「ハッシュ不一致は中止」が壊れていないこと。
#   (d) 受講者の導入を不必要に止めないこと（無改変なら成功する / 講師向け override は効く）。
#
# Windows 側 (install.ps1) の同等検証は scripts/windows/test/install-hash.test.ps1。
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
pass=0
fail=0
note(){ echo "[install-hash-guard] $1"; }
ok(){ note "PASS $1"; pass=$((pass + 1)); }
ng(){ note "FAIL $1"; fail=$((fail + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/install-hash-guard.XXXXXX")"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

PKG="$TMP/pkg"
mkdir -p "$PKG"
# パッケージ本体を複製する（.git と node_modules は検証に不要なので外す）。
if ! rsync -a --exclude '.git' --exclude 'node_modules' "$ROOT/" "$PKG/" 2>/dev/null; then
  note "SKIP: パッケージを複製できませんでした（rsync なし）"
  exit 0
fi

HARNESS_DIR=""
for cand in opencode-harness dist-opencode; do
  [ -d "$PKG/workspace-template/$cand" ] && { HARNESS_DIR="$PKG/workspace-template/$cand"; break; }
done
if [ -z "$HARNESS_DIR" ]; then
  ng "workspace-template に OpenCode ハーネスが無い（検査が空振りする）"
  exit 1
fi

ws_seq=0
# run_install <期待する結果 ok|abort> <説明> [環境変数...]
run_install() {
  local expect="$1"; shift
  local label="$1"; shift
  ws_seq=$((ws_seq + 1))
  local ws="$TMP/ws$ws_seq"
  local log="$TMP/log$ws_seq.txt"
  mkdir -p "$ws"
  ( export AI_SAFE_BACKUP_ROOT="$TMP/backups$ws_seq"
    for kv in "$@"; do export "${kv?}"; done
    bash "$PKG/scripts/macos/install.sh" --platform mac "$ws" ) >"$log" 2>&1
  local rc=$?
  if [ "$expect" = "ok" ]; then
    if [ "$rc" -eq 0 ]; then ok "$label (exit 0)"; else ng "$label — 中止された (exit $rc)"; sed -n '1,12p' "$log"; fi
  else
    if [ "$rc" -ne 0 ]; then
      # 中止したときはワークスペースに何も配置していないこと。
      if [ -f "$ws/.ai-safety/policy/safety-policy.json" ]; then
        ng "$label — 中止したのにファイルを配置した"
      else
        ok "${label} (exit ${rc}・配置なし)"
      fi
    else
      ng "$label — 素通りした (exit 0)"
    fi
  fi
}

# (d) 無改変なら成功する（受講者の導入を止めない）
run_install ok "無改変のパッケージは導入できる"

# Finder / Archive Utility が ZIP 内の「あんぜん.md」を「せ + 結合濁点」の
# UTF-8-MAC (NFD) で展開しても、NFC で記録したハッシュ行と照合できること。
if command -v iconv >/dev/null 2>&1 \
   && printf 'test' | iconv -f UTF-8 -t UTF-8-MAC >/dev/null 2>&1; then
  NFC_NAME='あんぜん.md'
  NFD_NAME="$(printf '%s' "$NFC_NAME" | iconv -f UTF-8 -t UTF-8-MAC)"
  if [ "$NFC_NAME" != "$NFD_NAME" ]; then
    mv "$HARNESS_DIR/commands/$NFC_NAME" "$HARNESS_DIR/commands/$NFD_NAME"
    run_install ok "macOS展開で濁点がNFDになった日本語指示書も導入できる"
    cp "$HARNESS_DIR/commands/$NFD_NAME" "$TMP/nfd-orig.md"
    printf '\n改ざんされた 1 行\n' >> "$HARNESS_DIR/commands/$NFD_NAME"
    run_install abort "NFD名でも指示書の改ざんを検知して中止する"
    cp "$TMP/nfd-orig.md" "$HARNESS_DIR/commands/$NFD_NAME"
    mv "$HARNESS_DIR/commands/$NFD_NAME" "$HARNESS_DIR/commands/$NFC_NAME"
  fi
fi

# (a) 指示書にハッシュ行の無い .md が混入
EXTRA="$HARNESS_DIR/commands/よぶんな指示.md"
printf 'これは配布物に混入した未登録の指示書です。\n' > "$EXTRA"
run_install abort "ハッシュ行の無い指示書が混入したら中止する (YELLOW-1)"
run_install ok "混入時も講師向け override で導入できる (AI_SAFE_ALLOW_UNLISTED_HARNESS=1)" \
  AI_SAFE_ALLOW_UNLISTED_HARNESS=1
rm -f "$EXTRA"

# (c) 既存の「ハッシュ不一致は中止」
JP_MD="$(find "$HARNESS_DIR" -type f -name '*.md' | sort | tail -n1)"
cp "$JP_MD" "$TMP/orig.md"
printf '\n改ざんされた 1 行\n' >> "$JP_MD"
run_install abort "指示書の中身が改ざんされたら中止する"
cp "$TMP/orig.md" "$JP_MD"

# (b) 検証表そのものの欠落
mv "$PKG/docs/tested_versions.md" "$TMP/tested_versions.md"
run_install abort "検証表 docs/tested_versions.md が無ければ中止する (Y-6)"
run_install ok "検証表が無くても講師向け override なら導入できる (AI_SAFE_ALLOW_HASH_MISMATCH=1)" \
  AI_SAFE_ALLOW_HASH_MISMATCH=1
mv "$TMP/tested_versions.md" "$PKG/docs/tested_versions.md"

# 念のため後始末後も成功すること（テストがパッケージ複製を壊していない確認）
run_install ok "後始末後のパッケージで再度導入できる"

note "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
