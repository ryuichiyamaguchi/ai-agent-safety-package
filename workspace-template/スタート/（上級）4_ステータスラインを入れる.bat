@echo off
chcp 932 >nul
setlocal
REM Claude の画面下に「cwd | model | コンテキスト使用量バー」を表示するステータスラインを入れる。
REM claude と d-claude の両方に効く。
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\install-statusline.ps1"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
echo Claude の画面下にステータスライン（cwd｜モデル｜コンテキスト使用量バー）を表示します。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" install
echo.
echo 完了したら、次に起動する Claude / d-claude から表示されます。
pause
