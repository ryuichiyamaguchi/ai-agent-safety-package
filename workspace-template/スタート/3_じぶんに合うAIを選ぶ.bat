@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
REM 「どの AI を使えばいいの？」の説明ページをブラウザで開く（読むだけ・何も変更しません）。
set "TARGET=%WORKSPACE%\docs\じぶんに合うAIを選ぶ.html"
if not exist "%TARGET%" (
  echo 説明ページが見つかりません: %TARGET%
  echo 「1_安全パッケージを最新版にする」を実行すると配置されます。
  pause
  exit /b 1
)
start "" "%TARGET%"
