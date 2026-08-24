@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..\..") do set "WORKSPACE=%%~fI"
REM 10_コピーした文章から秘密を伏せる.bat
REM いま「コピー」した文章の中から、API キー・メールアドレス・電話番号・
REM クレジットカード番号らしき列などを見つけて伏せ字にし、そのまま
REM クリップボードに書き戻します。外部の AI に貼り付ける直前に1回押してください。
REM 元に戻せる伏せ字は __SECRET_1__ の形になります。AI の返答をコピーしてから
REM 「11_伏せた文章を元に戻す」を押すと、元の文字に戻ります。
REM 伏せ字と原文の対応表は Windows の金庫(DPAPI)に入れ、既定 60 分で捨てます。
set "TARGET=%WORKSPACE%\.ai-safety\hooks\common\clipboard-mask.js"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「インストーラー（install-one-click）」を実行してください。
  pause
  exit /b 1
)
node "%TARGET%" --mask
echo.
pause
