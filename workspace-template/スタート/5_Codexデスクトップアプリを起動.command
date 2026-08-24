#!/bin/bash
# 5_Codexデスクトップアプリを起動.command
# インストール済みの Codex デスクトップアプリを起動する。
# 入っていないときは公式サイトを案内するだけで、このボタンは何もインストールしない。
set -u
if open -a "Codex" 2>/dev/null; then
  exit 0
fi
echo "Codex アプリが見つかりません。公式サイトからインストールしてください。"
echo "  https://openai.com/codex/"
echo ""
read -r -p "Enter キーで公式サイトを開きます..." _
open "https://openai.com/codex/"
