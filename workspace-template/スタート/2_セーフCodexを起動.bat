@echo off
chcp 932 >nul
setlocal
REM セーフ Codex 起動（薄いラッパー）。既存 launch-integrated.ps1 を呼ぶだけ。
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\launch-integrated.ps1"
if not exist "%TARGET%" (
  echo 起動スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent codex -Profile standard
if errorlevel 1 ( echo 問題が起きました。 & pause )
