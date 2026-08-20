@echo off
chcp 932 >nul
setlocal
:: 長時間おまかせモードは「OS の壁（サンドボックス）があるから承認を省ける」という設計。
:: Claude Code の壁は Windows では使えないため、このボタンは理由を出して起動しない。
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\launch-claude-longrun.ps1"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%"
echo.
pause
