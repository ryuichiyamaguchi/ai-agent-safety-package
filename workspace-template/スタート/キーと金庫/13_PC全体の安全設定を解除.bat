@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..\..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\uninstall-global-guard.ps1"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「インストーラー（install-one-click）」を実行してください。
  pause
  exit /b 1
)
echo 「12_PC全体に安全設定を入れる」で入れた PC 全体の安全設定を取り消し、元の設定に戻します。
echo （Claude Code / Codex / agy(Gemini) / OpenCode の 4 つが対象です。）
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%"
echo.
echo 元に戻しました。次に起動する AI から反映されます。
pause
