#!/bin/bash
# 0_AIツールをまとめて入れる（Mac・薄い補助）。
# Node/npm を確認し、npm で入る AI CLI（Codex / Claude Code / OpenCode）をまとめて導入する。
# ※ AntiGravity(agy) は公式インストーラ（curl）方式のため、ここでは入れない。
#   スタート.html の Step 0-2 の案内に従って別途インストールすること。
# ※ API キーのログイン（codex login 等）は本人入力が必要なため、ここでは行わない。
set -u

echo ""
echo "============================================================"
echo "  AI ツールをまとめて入れる（Codex / Claude Code / OpenCode）"
echo "============================================================"
echo ""

if ! command -v npm >/dev/null 2>&1; then
  echo "【お願い】Node.js / npm がまだ入っていません。"
  echo "  さきに https://nodejs.org/ja から「LTS」版を入れてください。"
  echo "  入れ終わったら、もう一度このファイルをダブルクリックしてください。"
  echo ""
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi

# 2026-08-20: Claude Code のバージョン固定 (@2.1.201) をやめ、最新版を入れる。
# 理由 = (a) Claude Code 純正サンドボックス（settings の sandbox 節）を使う方針に変えたため、
# 古い版に固定すると純正機能の恩恵を受けられない (b) 固定版は日々古びる一方で、受講者の
# 環境には npm の都合で最新が入りがちで、毎回「版ちがい」警告が出るドリフトになっていた。
# 版差でランチャーのフラグ検出が外れる懸念は残るが、launch-claude-safe.{sh,ps1} が --help を
# 見て「対応していないフラグは付けない」実装なので起動は壊れない（機能が減るだけ）。
for pkg in "@openai/codex" "@anthropic-ai/claude-code@latest" "opencode-ai"; do
  echo "------------------------------------------------------------"
  echo "導入中: $pkg"
  if npm install -g "$pkg"; then
    echo "  OK: $pkg を入れました。"
  else
    echo "  （$pkg の導入に失敗しました。あとでやり直せます）"
  fi
  echo ""
done

echo "------------------------------------------------------------"
echo "AntiGravity（agy）は入れ方が違います。"
echo "  スタート.html の「0-2」の案内（公式ページ）に従ってください。"
echo ""
echo "このあと、各AIにログインしてください（例: codex login）。"
echo "  APIキーの入力だけは自分でやる必要があります。"
echo ""
read -r -p "Enter キーで閉じます..." _
