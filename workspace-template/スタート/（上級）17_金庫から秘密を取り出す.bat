@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
cd /d "%WORKSPACE%" 2>nul
REM （上級）17_金庫から秘密を取り出す.bat
REM 「（上級）16_金庫に秘密をしまう」でしまった中身を、クリップボードに取り出します。
REM 画面には中身を出しません。取り出した中身は 60 秒後に自動で消します。
REM ただし、そのあいだに別のものをコピーしていたら消しません
REM （いま入れた中身がクリップボードに残っているときだけ消します）。
set "TARGET=%WORKSPACE%\.ai-safety\hooks\common\secret-store.js"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)

echo.
echo  ■ 金庫から秘密を取り出す
echo.
echo  金庫（Windows の DPAPI）にしまってある中身を、クリップボードに入れます。
echo.

set "AI_SAFE_TARGET=%TARGET%"
set "AI_SAFE_MSG_LIST= しまってあるもの:"
set "AI_SAFE_MSG_PICK=取り出したいものの番号を入力して Enter"
REM ※ 文字コードについて（v1.17.4 で直した文字化けの再発防止）:
REM   ・このファイルは CP932 で、cmd も chcp 932 の CP932 コンソール。
REM   ・[Console]::OutputEncoding は「画面へ出す文字コード」。ここを UTF-8 に
REM     すると CP932 のコンソールに UTF-8 が流れて日本語が化ける。既定のままにする。
REM   ・$OutputEncoding は「ネイティブコマンド（node）へ渡す文字コード」。
REM     node は UTF-8 前提なので、こちらは UTF-8 のままにしておく必要がある。
REM   ・node の標準出力を受け取る箇所だけは [Console]::OutputEncoding を一時的に
REM     UTF-8 にして読み、直後に元へ戻す（日本語の名前を正しく受け取るため）。
powershell -NoProfile -ExecutionPolicy Bypass -Command "$OutputEncoding=[Text.Encoding]::UTF8; $enc0=[Console]::OutputEncoding; $t=$env:AI_SAFE_TARGET; [Console]::OutputEncoding=[Text.Encoding]::UTF8; $names=@(@(& node $t --user-list) | Where-Object { $_ -ne '' }); [Console]::OutputEncoding=$enc0; if($names.Count -eq 0){ exit 3 }; Write-Host $env:AI_SAFE_MSG_LIST; for($i=0; $i -lt $names.Count; $i++){ Write-Host ('   ' + ($i+1) + ') ' + $names[$i]) }; Write-Host ''; $c=Read-Host $env:AI_SAFE_MSG_PICK; if($c -notmatch '^[0-9]+$'){ exit 4 }; $k=[int]$c; if($k -lt 1 -or $k -gt $names.Count){ exit 4 }; & node $t --user-copy $names[$k-1] | Out-Null; if($LASTEXITCODE -ne 0){ exit 5 }; $cl='$sha=[Security.Cryptography.SHA256]::Create(); $b=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string](Get-Clipboard -Raw)))); Start-Sleep -Seconds 60; $a=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string](Get-Clipboard -Raw)))); if($b -eq $a){ Set-Clipboard -Value '''' }'; Start-Process -WindowStyle Hidden powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA','-Command',$cl; exit 0"
set "AI_SAFE_RC=%errorlevel%"
set "AI_SAFE_MSG_LIST="
set "AI_SAFE_MSG_PICK="
set "AI_SAFE_TARGET="

echo.
if "%AI_SAFE_RC%"=="0" (
  echo  クリップボードに入れました。貼り付けたい所で Ctrl+V を押してください。
  echo  （中身は画面に出していません）
  echo.
  echo  ★ 60 秒後に、クリップボードから自動で消します。
  echo    そのあいだに別のものをコピーしていたら、そちらは消しません。
) else if "%AI_SAFE_RC%"=="3" (
  echo  金庫にはまだ何も入っていません。
  echo  「（上級）16_金庫に秘密をしまう」でしまってから、もう一度お試しください。
) else if "%AI_SAFE_RC%"=="4" (
  echo  番号が正しくありません。中止しました。
) else (
  echo  取り出せませんでした。金庫に見つからないか、金庫を開けませんでした。
  echo  「（上級）16_金庫に秘密をしまう」でしまい直してください。
)
echo.
pause
