@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\update-ai-tools.ps1"
echo.
echo == AI ツールを最新版に更新します ==
echo AI ツール本体（Codex CLI / Claude Code / OpenCode）を npm でまとめて更新します。
echo Claude Code だけは最新版ではなく「動作確認済みの版」に合わせます。
echo 安全パッケージ本体の更新は「7_安全パッケージを最新版に更新」です。
echo.
if not exist "%TARGET%" (
  echo 見つかりません: %TARGET%
  echo 先に「7_安全パッケージを最新版に更新」（または 1_安全パッケージを準備）を実行してください。
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%"
echo.
pause
