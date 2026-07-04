@echo off
chcp 932 >nul
setlocal
REM ccmux（複数の Claude 画面を1つのターミナルにまとめるツール）を入れる。
REM npm で ccmux-cli を入れ、カスタム版 ccmux.exe（Windows専用）で実体を上書きする。
REM カスタム exe は同梱しない。同じフォルダ or ダウンロード or GitHub Release から取得する。
echo ccmux（複数の Claude 画面をまとめるツール）を入れます。
echo.
where npm >nul 2>&1
if errorlevel 1 (
  echo npm が見つかりません。先に「0_AIツールをまとめて入れる」を実行してください。
  pause
  exit /b 1
)
echo [1/3] ccmux-cli を導入中（少し時間がかかります）...
call npm install -g ccmux-cli

echo [2/3] カスタム版 ccmux.exe を用意します...
set "SRC=%~dp0ccmux.exe"
if not exist "%SRC%" set "SRC=%USERPROFILE%\Downloads\ccmux.exe"
if not exist "%SRC%" (
  echo   GitHub Release から取得します...
  set "SRC=%TEMP%\ccmux.exe"
  powershell -NoProfile -Command "try { Invoke-WebRequest -Uri 'https://github.com/ryuichiyamaguchi/ai-agent-safety-package/releases/latest/download/ccmux.exe' -OutFile ([System.Environment]::GetEnvironmentVariable('TEMP') + '\ccmux.exe') -UseBasicParsing } catch { exit 1 }"
  if errorlevel 1 (
    echo   取得できませんでした。ccmux.exe をこのファイルと同じフォルダに置いてから、もう一度実行してください。
    pause
    exit /b 1
  )
)

echo [3/3] 実体を上書きします...
set "TARGET=%APPDATA%\npm\node_modules\ccmux-cli\bin\ccmux.exe"
if not exist "%TARGET%" (
  echo   ccmux-cli の実体が見つかりません: %TARGET%
  echo   npm の導入が完了していない可能性があります。
  pause
  exit /b 1
)
copy /Y "%SRC%" "%TARGET%" >nul
if errorlevel 1 (
  echo 上書きに失敗しました。ccmux が起動中なら終了してから再実行してください。
) else (
  echo インストール成功！ ccmux と打つと起動します。
)
echo.
pause
