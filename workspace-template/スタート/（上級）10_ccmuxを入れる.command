#!/bin/bash
# （上級）10_ccmuxを入れる.command
# ccmux（複数の AI 画面を1つのターミナルにまとめるツール）を入れる。
#
# Apple Silicon の Mac では、山口さん改造版（ファイルツリーのドラッグ&ドロップでパス貼り付け、
# Shift+ホイールでの遡り、h/l での上位階層移動）を GitHub Release から取得して入れる。
# 実体は必ず SHA-256 で照合してから配置する（壊れたファイル・別物を弾く）。
# それ以外の Mac（Intel）は本家 npm 版を入れる（改造版のバイナリを用意していないため）。
set -u

EXPECT_SHA="67bdba1d2be18faa0d187f0d4ca71d710c311dab765716e3e162e1b400ace533"
REL_BASE="https://github.com/ryuichiyamaguchi/ai-agent-safety-package/releases/latest/download"
ASSET="ccmux-macos-arm64"
BIN_DIR="$HOME/.ai-safety/bin"
DEST="$BIN_DIR/ccmux"

say() { echo "$1"; }
fail() { echo ""; echo "【中止】$1"; read -r -p "Enter キーで閉じます..." _; exit 1; }

echo "ccmux（複数の AI 画面をまとめるツール）を入れます。"
echo ""

arch="$(uname -m 2>/dev/null || echo unknown)"
if [ "$arch" != "arm64" ]; then
  say "この Mac（$arch）向けの改造版は用意がないため、本家版を入れます。"
  command -v npm >/dev/null 2>&1 || fail "npm が見つかりません。先に「0_AIツールをまとめて入れる」を実行してください。"
  npm install -g ccmux-cli || fail "導入に失敗しました（上のメッセージを確認してください）。"
  echo ""
  echo "完了しました。ターミナルで  ccmux  と打つと起動します。"
  read -r -p "Enter キーで閉じます..." _
  exit 0
fi

command -v curl >/dev/null 2>&1 || fail "curl が見つかりません。"
command -v shasum >/dev/null 2>&1 || fail "shasum が見つかりません。"

say "[1/3] 改造版 ccmux を取得中..."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# HTTPS 固定（リダイレクトも HTTPS に限定＝http へのダウングレードを許さない）。
curl -fsSL --proto '=https' --proto-redir '=https' "$REL_BASE/$ASSET" -o "$tmp/ccmux" \
  || fail "取得できませんでした（ネットワーク、または配布物の有無を確認してください）。"

say "[2/3] SHA-256 を照合中..."
actual="$(shasum -a 256 "$tmp/ccmux" | awk '{print tolower($1)}')"
if [ "$actual" != "$EXPECT_SHA" ]; then
  echo "  期待値: $EXPECT_SHA"
  echo "  実際:   $actual"
  fail "取得したファイルが期待と違います。配布が壊れているか、別物の可能性があります。"
fi

say "[3/3] 配置中..."
mkdir -p "$BIN_DIR" || fail "配置先を作れませんでした: $BIN_DIR"
cp "$tmp/ccmux" "$DEST" || fail "配置に失敗しました: $DEST"
chmod 755 "$DEST"
# ダウンロードした実行ファイルには検疫属性が付き、そのままでは macOS が起動を止める。
# 上で SHA-256 照合を通した実体だけ、ここで外す。
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo ""
echo "完了しました: $DEST"
if ! command -v ccmux >/dev/null 2>&1 || [ "$(command -v ccmux)" != "$DEST" ]; then
  echo ""
  echo "※ 新しいターミナルを開いてから  ccmux  と打ってください（PATH の反映のため）。"
fi
echo ""
echo "使い方:"
echo "  ファイルツリーで  h（左）= 上のフォルダへ / l（右）= フォルダに入る"
echo "  ファイルをドラッグしてターミナル画面に落とすと、そのパスが貼り付きます"
echo "  Shift + マウスホイール で画面を遡れます"
read -r -p "Enter キーで閉じます..." _
