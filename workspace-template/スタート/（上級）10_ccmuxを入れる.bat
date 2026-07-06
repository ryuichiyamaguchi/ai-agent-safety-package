@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\install-ccmux.ps1"
echo ccmux（複数の Claude 画面を1つのターミナルにまとめる改造版ツール）を入れます。
echo （Shin-sibainu/ccmux の改造版・MIT。Release から取得し SHA-256 照合します）
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

