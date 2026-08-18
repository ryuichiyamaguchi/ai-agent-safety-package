@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\apply-global-guard.ps1"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
echo この PC で Claude と Codex をどのフォルダから起動しても、危険コマンド（再帰削除・.env の読み取り・外部への送信など）を止めます。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%"
echo.
echo 完了しました。元に戻すときは「（上級）6_グローバル禁止を解除」を実行してください。
pause
