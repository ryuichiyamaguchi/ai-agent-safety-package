@echo off
chcp 932 >nul
setlocal
REM 見守りモニター（コンソール版）。ブラウザを使わずターミナル内で見る上級向け。
REM 通常は「5_見守りモニターを起動」を使ってください（ブラウザで見やすく表示）。
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\monitor.ps1"
if not exist "%TARGET%" (
  echo 起動スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%"
if errorlevel 1 ( echo 問題が起きました。 & pause )
