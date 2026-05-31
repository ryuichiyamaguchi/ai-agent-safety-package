@echo off
chcp 65001 >nul
setlocal
set "HERE=%~dp0"
set "TARGET=%HERE%scripts\windows\install-one-click.bat"
if not exist "%TARGET%" (
  echo インストーラが見つかりません: %TARGET%
  pause
  exit /b 1
)
call "%TARGET%"

REM 準備が終わったら、次に使う「スタート」フォルダを自動で開く（迷わせない）。
set "START_DIR=%USERPROFILE%\Documents\my-ai-workspace\スタート"
if exist "%START_DIR%" (
  echo.
  echo 次に使うファイルはこのフォルダの中にあります:
  echo   %START_DIR%
  start "" explorer "%START_DIR%"
)
