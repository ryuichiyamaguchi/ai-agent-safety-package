@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
REM 安全パッケージの使い方ガイドをブラウザで開く（読むだけ・何も変更しません）。
set "TARGET=%WORKSPACE%\docs\ai-agent-safety-package-explained.html"
if not exist "%TARGET%" (
  echo 使い方ガイドが見つかりません: %TARGET%
  echo 「1_安全パッケージを最新版にする」を実行すると配置されます。
  pause
  exit /b 1
)
start "" "%TARGET%"
