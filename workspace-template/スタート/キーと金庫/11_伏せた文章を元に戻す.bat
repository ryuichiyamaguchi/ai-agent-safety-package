@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..\..") do set "WORKSPACE=%%~fI"
REM 11_伏せた文章を元に戻す.bat
REM AI の返答をコピーしてからこれを押すと、__SECRET_1__ のような伏せ字を
REM 元の文字（自分のメールアドレス・会社名など）に戻してクリップボードに書き戻します。
REM 対応表は Windows の金庫(DPAPI)に入っていて、既定 60 分で自動的に捨てます。
REM 期限が切れていたら「期限切れです」と表示されるので、伏せるところからやり直してください。
set "TARGET=%WORKSPACE%\.ai-safety\hooks\common\clipboard-mask.js"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「インストーラー（install-one-click）」を実行してください。
  pause
  exit /b 1
)
node "%TARGET%" --restore
echo.
pause
