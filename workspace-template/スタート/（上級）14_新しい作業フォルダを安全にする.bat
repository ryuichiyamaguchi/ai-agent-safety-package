@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\protect-folder.ps1"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
echo 新しく作業したいフォルダを選ぶと、そのフォルダを AI が安全に使える状態にします。
echo （案件ごとに 1 つフォルダを作って、そこを選ぶのがおすすめです。）
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%"
echo.
pause
