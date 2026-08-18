@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\fetch-update.ps1"
echo.
echo == 安全パッケージを最新版に更新します ==
echo ※ AI ツール本体の更新は「8_AIツールを最新版に更新」です。
echo 最新版を GitHub から取得して更新します（ネット接続が必要）。
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
