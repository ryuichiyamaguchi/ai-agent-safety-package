@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\deepseek\起動-Claude-DeepSeek.bat"
if not exist "%TARGET%" (
  echo DeepSeek 起動スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
:: 作業フォルダを明示して渡す。「（上級）14_新しい作業フォルダを安全にする」で作った
:: 別のフォルダから押したときも、そのフォルダのフック・設定で起動させるため。
call "%TARGET%" "%WORKSPACE%"
