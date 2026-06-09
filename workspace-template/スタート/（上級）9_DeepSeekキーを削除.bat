@echo off
chcp 65001 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\deepseek\キー削除.bat"
if not exist "%TARGET%" (
  echo DeepSeek 起動スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
call "%TARGET%"
