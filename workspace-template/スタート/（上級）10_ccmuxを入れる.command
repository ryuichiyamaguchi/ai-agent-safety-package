#!/bin/bash
# ccmux（複数の Claude 画面を1つのターミナルにまとめるツール）を npm で入れる。
# カスタム版 ccmux.exe は Windows 専用なので、mac は npm 版の ccmux-cli を入れるだけ。
set -u
echo "ccmux（複数の Claude 画面をまとめるツール）を入れます。"
echo ""
if ! command -v npm >/dev/null 2>&1; then
  echo "npm が見つかりません。先に「0_AIツールをまとめて入れる」を実行してください。"
  read -r -p "Enter キーで閉じます..." _
  exit 1
fi
echo "ccmux-cli を導入中（少し時間がかかります）..."
npm install -g ccmux-cli
ec=$?
echo ""
if [ $ec -eq 0 ]; then
  echo "完了しました。ターミナルで  ccmux  と打つと起動します。"
  echo "（Windows 用のカスタム版 ccmux.exe は Windows のボタンから入れてください。）"
else
  echo "導入に失敗しました（上のメッセージを確認してください）。"
fi
read -r -p "Enter キーで閉じます..." _
