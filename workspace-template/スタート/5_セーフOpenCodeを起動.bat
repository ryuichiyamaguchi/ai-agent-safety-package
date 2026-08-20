@echo off
chcp 932 >nul
setlocal
REM セーフ OpenCode 起動（薄いラッパー）。既存の安全起動口 oc-safe.ps1 をそのまま呼ぶ。
REM OpenCode 本体を直接叩くと見守りモニターが上がらないので、必ずここを通す。
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\oc-safe.ps1"
if not exist "%TARGET%" (
  echo 起動スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%"
if errorlevel 1 ( echo 問題が起きました。 & pause )
