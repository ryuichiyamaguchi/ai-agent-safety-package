@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
cd /d "%WORKSPACE%" 2>nul
REM （上級）18_金庫の秘密を消す.bat
REM 「（上級）16_金庫に秘密をしまう」でしまったものを、この PC から消します。
REM   %USERPROFILE%\.ai-safety\user.<名前>.dpapi と、名前の一覧
REM   %USERPROFILE%\.ai-safety\user-secrets.index の両方から消します。
REM ※ この金庫の中身しか消しません。AIコーチや Buffer のキーには触りません。
set "TARGET=%WORKSPACE%\.ai-safety\hooks\common\secret-store.js"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)

echo.
echo  ■ 金庫の秘密を消す
echo.
echo  消したものは元に戻せません。必要なら先に
echo  「（上級）17_金庫から秘密を取り出す」で控えを取ってください。
echo.

set "AI_SAFE_TARGET=%TARGET%"
set "AI_SAFE_MSG_LIST= しまってあるもの:"
set "AI_SAFE_MSG_PICK=消したいものの番号を入力して Enter"
set "AI_SAFE_MSG_CONFIRM=本当に消してよければ y を入力して Enter"
REM ※ 文字コードについて（v1.17.4 で直した文字化けの再発防止）:
REM   ・このファイルは CP932 で、cmd も chcp 932 の CP932 コンソール。
REM   ・[Console]::OutputEncoding は「画面へ出す文字コード」。ここを UTF-8 に
REM     すると CP932 のコンソールに UTF-8 が流れて日本語が化ける。既定のままにする。
REM   ・$OutputEncoding は「ネイティブコマンド（node）へ渡す文字コード」。
REM     node は UTF-8 前提なので、こちらは UTF-8 のままにしておく必要がある。
REM   ・node の標準出力を受け取る箇所だけは [Console]::OutputEncoding を一時的に
REM     UTF-8 にして読み、直後に元へ戻す（日本語の名前を正しく受け取るため）。
powershell -NoProfile -ExecutionPolicy Bypass -Command "$OutputEncoding=[Text.Encoding]::UTF8; $enc0=[Console]::OutputEncoding; $t=$env:AI_SAFE_TARGET; [Console]::OutputEncoding=[Text.Encoding]::UTF8; $names=@(@(& node $t --user-list) | Where-Object { $_ -ne '' }); [Console]::OutputEncoding=$enc0; if($names.Count -eq 0){ exit 3 }; Write-Host $env:AI_SAFE_MSG_LIST; for($i=0; $i -lt $names.Count; $i++){ Write-Host ('   ' + ($i+1) + ') ' + $names[$i]) }; Write-Host ''; $c=Read-Host $env:AI_SAFE_MSG_PICK; if($c -notmatch '^[0-9]+$'){ exit 4 }; $k=[int]$c; if($k -lt 1 -or $k -gt $names.Count){ exit 4 }; $nm=$names[$k-1]; Write-Host $nm; $y=Read-Host $env:AI_SAFE_MSG_CONFIRM; if($y -ne 'y' -and $y -ne 'Y'){ exit 6 }; & node $t --user-remove $nm | Out-Null; exit $LASTEXITCODE"
set "AI_SAFE_RC=%errorlevel%"
set "AI_SAFE_MSG_LIST="
set "AI_SAFE_MSG_PICK="
set "AI_SAFE_MSG_CONFIRM="
set "AI_SAFE_TARGET="

echo.
if "%AI_SAFE_RC%"=="0" (
  echo  消しました。金庫からも、名前の一覧からも消えています。
) else if "%AI_SAFE_RC%"=="3" (
  echo  金庫にはまだ何も入っていません。消すものはありません。
) else if "%AI_SAFE_RC%"=="4" (
  echo  番号が正しくありません。中止しました。何も消していません。
) else if "%AI_SAFE_RC%"=="6" (
  echo  中止しました。何も消していません。
) else (
  echo  金庫には見つかりませんでした（すでに消えていたようです）。
  echo  名前の一覧からは片付けました。
)
echo.
pause
