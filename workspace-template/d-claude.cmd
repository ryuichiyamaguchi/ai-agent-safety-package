@echo off
chcp 932 >nul
setlocal
REM DeepSeek バックエンドの Claude Code を、ガード＋同意ゲート経由で起動します。
REM (素の claude は呼びません。launch-claude-safe 経由でガードが効いたまま起動)
set "HERE=%~dp0"
for %%I in ("%HERE%.") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\deepseek\起動-Claude-DeepSeek.bat"
if not exist "%TARGET%" (
  echo DeepSeek 起動スクリプトが見つかりません: %TARGET%
  echo 先に install-one-click.bat を実行してください。
  pause
  exit /b 1
)
call "%TARGET%"
