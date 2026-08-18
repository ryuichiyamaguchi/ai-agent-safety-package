@echo off
chcp 932 >nul
setlocal
REM （上級）9_プラグインの置き場を開く.bat
REM プラグインの置き場（<ワークスペース>\.ai-safety\plugins）をエクスプローラーで開く。
REM .ai-safety は隠しフォルダなので、自力でたどるのが難しい。その入口。
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\plugins"
if not exist "%TARGET%" mkdir "%TARGET%"
if not exist "%TARGET%" (
  echo 置き場を作れませんでした: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
echo プラグインの置き場を開きます。
echo   %TARGET%
echo.
echo ここに .js または .ts のファイルを置くと、次に OpenCode を起動したときに
echo 名前を表示して確認を求めたうえで読み込みます（フォルダの直下だけを見ます）。
echo.
echo ※ ここに置いたコードは承認モニターの確認を通りません。
echo    見守りの仕組みそのものを止めることもできます。
echo    中身を自分で確かめたものだけを置いてください。
explorer "%TARGET%"
exit /b 0
