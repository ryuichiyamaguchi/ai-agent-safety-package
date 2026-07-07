#!/bin/bash
# 野良d-claudeを退治.command — 正規ランチャー以外の d-claude を検出し、確認のうえ退避する（mac）。
# 破壊的操作を含むため「表示 → y/N 確認 → 退避」の順。確認前は一切動かさない。
# 削除ではなく退避（バックアップフォルダへ move）を基本にし、誤爆時に戻せるようにする。
# PATH 順の変更や環境変数の書き換えはしない（footgun 回避）。退避のみ。
# 正規判定基準は 診断.ps1 と同思想（解決先が <workspace>/.ai-safety/ 配下なら正規）。
# macOS の /bin/bash は 3.2 のため、空配列 + set -u の展開に注意する。
set -u

WORKSPACE="${1:-$HOME/Documents/my-ai-workspace}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/.ai-safety/backups/rogue-d-claude/$STAMP"
LEGIT_PREFIX="$WORKSPACE/.ai-safety/"

echo "============================================================"
echo "  野良 d-claude 退治ツール（mac）"
echo "  正規ランチャー以外の d-claude を退避します"
echo "============================================================"
echo "日時: $(date)"
echo "ワークスペース: $WORKSPACE"
echo ""

echo "■ いまPCにある d-claude を全部さがします:"
TYPE_OUT="$(type -a d-claude 2>/dev/null || true)"
if [ -n "$TYPE_OUT" ]; then
  printf '%s\n' "$TYPE_OUT" | sed 's/^/    /'
else
  echo "    （このシェルからは d-claude コマンドは見つかりませんでした）"
fi
echo ""

ROGUE_FILES=()

add_rogue() {
  f="$1"
  case "$f" in
    "$LEGIT_PREFIX"*) return 0 ;;
  esac
  if [ "${#ROGUE_FILES[@]}" -gt 0 ]; then
    for e in "${ROGUE_FILES[@]}"; do
      [ "$e" = "$f" ] && return 0
    done
  fi
  ROGUE_FILES+=("$f")
}

# (a) PATH の各ディレクトリに実体 d-claude があるか（関数/エイリアスは別扱い）。
OLDIFS="$IFS"; IFS=":"
for dir in $PATH; do
  [ -n "$dir" ] || continue
  cand="$dir/d-claude"
  if [ -e "$cand" ] || [ -L "$cand" ]; then
    add_rogue "$cand"
  fi
done
IFS="$OLDIFS"

# (b) 既知の場所（npm グローバル・/usr/local/bin 等）も走査。
NPM_PREFIX="$(npm config get prefix 2>/dev/null || true)"
NPM_BIN="$(npm bin -g 2>/dev/null || true)"
for d in \
  ${NPM_PREFIX:+"$NPM_PREFIX/bin"} \
  ${NPM_BIN:+"$NPM_BIN"} \
  "$HOME/.npm-global/bin" \
  "/usr/local/bin" \
  "/opt/homebrew/bin" \
  "$HOME/bin" \
  "$HOME/.local/bin"
do
  [ -n "$d" ] || continue
  [ -d "$d" ] || continue
  for f in "$d"/d-claude "$d"/d-claude.*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    add_rogue "$f"
  done
done

# (c) シェル設定ファイルの d-claude 定義を静的に走査（alias/関数はファイル退避では消せない → 手案内）。
echo "■ シェル設定ファイルの d-claude 定義（自動では消しません）:"
RC_HITS=""
for rc in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
  [ -f "$rc" ] || continue
  hits="$(grep -nF 'd-claude' "$rc" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    RC_HITS="yes"
    echo "  [野良] $rc:"
    printf '%s\n' "$hits" | sed 's/^/       /'
  fi
done
if [ -z "$RC_HITS" ]; then
  echo "  [正規] シェル設定ファイルに d-claude の定義はありません"
else
  echo ""
  echo "  ↑ これは alias/関数の定義かもしれません。ファイル退避では消せません。"
  echo "     上のファイルを開き、その行を削除するか行頭に # を付け、新しいターミナルを開き直してください。"
fi
echo ""

# 退避対象の提示 → 確認 → 退避（確認前は何も動かさない）。
if [ "${#ROGUE_FILES[@]}" -eq 0 ]; then
  echo "------------------------------------------------------------"
  if [ -z "$RC_HITS" ]; then
    echo "  [正規] 野良は見つかりませんでした（正常です）。"
  else
    echo "  退避できるファイル形式の野良はありません（上の設定ファイルの定義だけ手で消してください）。"
  fi
  echo "------------------------------------------------------------"
  echo ""
  read -r -p "Enter キーで閉じます..." _
  exit 0
fi

echo "■ 退避（＝バックアップへ移動）する野良ファイル:"
for f in "${ROGUE_FILES[@]}"; do echo "  [野良] $f"; done
echo ""
echo "  ※ 削除ではなく、下記フォルダへ『移動』します。まちがいのときは戻せます。"
echo "  退避先: $BACKUP_DIR"
echo ""
printf "これらを退避しますか？（元に戻せます）  y = 実行 / それ以外 = 中止: "
read -r ans
case "$ans" in
  y|Y) ;;
  *)
    echo ""
    echo "中止しました。何も変更していません。"
    read -r -p "Enter キーで閉じます..." _
    exit 0
    ;;
esac

mkdir -p "$BACKUP_DIR"
MANIFEST="$BACKUP_DIR/戻し方.txt"
{
  echo "この中のファイルは『野良 d-claude 退治』で退避したものです。"
  echo "元に戻すには、下の各行の右側パスから左側パスへ、ファイルを移動し直してください。"
  echo ""
} > "$MANIFEST"
MOVED=0
for f in "${ROGUE_FILES[@]}"; do
  base="$(basename "$f")"
  dest="$BACKUP_DIR/$base"
  n=1
  while [ -e "$dest" ]; do dest="$BACKUP_DIR/$base.$n"; n=$((n+1)); done
  if mv "$f" "$dest" 2>/dev/null; then
    echo "  [正規] 退避しました: $f"
    printf '%s\t=>\t%s\n' "$f" "$dest" >> "$MANIFEST"
    MOVED=$((MOVED+1))
  else
    echo "  [注意] 退避できませんでした（権限が必要かもしれません）: $f"
  fi
done
echo ""
echo "------------------------------------------------------------"
echo "  $MOVED 件を退避しました。"
echo "  次にやること:"
echo "   1) いま開いているターミナルをすべて閉じる"
echo "   2) 新しいターミナルを開いて、もう一度 d-claude を試す"
echo "   3) 正規のランチャー（$WORKSPACE/.ai-safety/ 配下）が使われていれば成功です"
if [ -n "$RC_HITS" ]; then
  echo "   ※ 上で表示したシェル設定ファイルの d-claude 定義も、手で削除してください。"
fi
echo "------------------------------------------------------------"
echo ""
read -r -p "Enter キーで閉じます..." _
