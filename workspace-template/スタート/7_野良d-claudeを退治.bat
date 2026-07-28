@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\野良d-claudeを退治.ps1"
echo.
echo == 野良 d-claude を退治します ==
echo 正規ランチャーを乗っ取る「野良の d-claude」を、確認のうえ退避します。
echo （削除ではなくバックアップへ移動するので、まちがいのときは戻せます）
echo.
if not exist "%TARGET%" (
  echo 見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%"
echo.
pause
