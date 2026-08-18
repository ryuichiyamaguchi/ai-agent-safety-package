@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
REM Mac 版 (.command) と同じく作業フォルダを基点に動く（キー自体は %USERPROFILE%\.ai-safety に保存）。
cd /d "%WORKSPACE%" 2>nul
REM （上級）8_Bufferのキーを登録.bat
REM SNS の予約投稿サービス Buffer の API キーを登録します。
REM 登録すると OpenCode から Buffer を操作できます（投稿の作成・予約・下書き、
REM チャンネル一覧、実績の取得など）。
REM キーは %USERPROFILE%\.ai-safety\buffer-api-key.txt に保存します。

echo.
echo  Buffer（SNSの予約投稿サービス）の API キーを登録します。
echo.
echo  キーの取り方:
echo    1. ブラウザで  https://publish.buffer.com/settings/api  を開く
echo    2. Buffer にログインして API キーを作成
echo    3. 表示されたキーをコピー
echo.
echo  登録するとできること:
echo    ・投稿の下書き作成・予約・キューの管理
echo    ・つないでいるSNSアカウント（チャンネル）の一覧
echo    ・投稿の実績（数値）の取得
echo.
echo  ★注意: SNS への投稿は取り消せません。
echo    AI が投稿しようとすると必ず確認が出ます。中身をよく読んでから許可してください。
echo.

set "KEY="
set /p "KEY=APIキーを貼り付けて Enter（登録をやめるなら何も入れずに Enter）: "
if not defined KEY (
  echo 何も入力されませんでした。中止します。
  pause
  exit /b 1
)

set "DEST=%USERPROFILE%\.ai-safety"
if not exist "%DEST%" mkdir "%DEST%"
REM 末尾に改行を付けずに書き出す（読み取り側は trim するが、余計な文字を混ぜない）。
<nul set /p "=%KEY%" > "%DEST%\buffer-api-key.txt"

echo.
echo  登録できました。OpenCode を開き直すと Buffer が使えます。
echo  使うのをやめたいときは、このファイルを消してください:
echo    %DEST%\buffer-api-key.txt
echo.
pause
