@echo off
chcp 932 >nul
setlocal
REM 見守りモニター起動（薄いラッパー）。HTML モニター(now.html)を既定ブラウザで開く。
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\open-monitor.ps1"
if not exist "%TARGET%" (
  echo 起動スクリプトが見つかりません: %TARGET%
  echo 先に「インストーラー（install-one-click）」を実行してください。
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%"
if errorlevel 1 ( echo 問題が起きました。 & pause )
