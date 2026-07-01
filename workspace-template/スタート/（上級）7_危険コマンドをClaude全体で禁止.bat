@echo off
chcp 932 >nul
setlocal
REM この PC の Claude 全体設定に、危険コマンドの deny を反映する（ワンクリック）。
REM 既存の設定は壊さず、permissions.deny だけを追加する。反映前に自動でバックアップを取る。
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\apply-global-deny.ps1"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
echo この PC で Claude をどのフォルダから起動しても、危険コマンドを禁止します。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%"
echo.
pause
