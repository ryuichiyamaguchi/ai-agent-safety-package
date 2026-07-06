@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\診断.ps1"
echo.
echo == 診断（読み取り専用・何も変更しません）==
echo うまく動かないとき、この結果を講師に送ってください。
echo.
if not exist "%TARGET%" (
  echo 見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%"
echo.
pause
