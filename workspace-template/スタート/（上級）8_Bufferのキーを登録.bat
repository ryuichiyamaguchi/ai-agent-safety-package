@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
REM Mac 版 (.command) と同じく作業フォルダを基点に動く（キー自体は金庫に保存）。
cd /d "%WORKSPACE%" 2>nul
REM （上級）8_Bufferのキーを登録.bat
REM SNS の予約投稿サービス Buffer の API キーを登録します。
REM 登録すると OpenCode から Buffer を操作できます（投稿の作成・予約・下書き、
REM チャンネル一覧、実績の取得など）。
REM v1.17.0 から、キーは Windows の金庫(DPAPI)で暗号化して保存します。
REM   保存先: %USERPROFILE%\.ai-safety\buffer.dpapi

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
set "AI_SAFE_NEW_KEY=%KEY%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$k=($env:AI_SAFE_NEW_KEY).Trim(); if($k.Length -eq 0){exit 1}; $d=Join-Path $env:USERPROFILE '.ai-safety'; [void](New-Item -ItemType Directory -Force $d); $p=Join-Path $d 'buffer.dpapi'; $legacy=Join-Path $d 'buffer-api-key.txt'; $w='v1:'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($k)); (ConvertTo-SecureString $w -AsPlainText -Force | ConvertFrom-SecureString) | Set-Content -LiteralPath $p -Encoding ascii -NoNewline; $ss=ConvertTo-SecureString ((Get-Content -LiteralPath $p -Raw).Trim()); $b=[Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)); $back=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b.Substring(3))); if($back -eq $k){ Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue; exit 0 } else { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; exit 1 }"
if errorlevel 1 (
  echo.
  echo  金庫に入れられなかったため、これまでどおりファイルに保存します。
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=Join-Path $env:USERPROFILE '.ai-safety'; [void](New-Item -ItemType Directory -Force $d); Set-Content -NoNewline -Encoding ascii -Path (Join-Path $d 'buffer-api-key.txt') -Value ($env:AI_SAFE_NEW_KEY).Trim()"
) else (
  echo.
  echo  金庫にしまいました(%USERPROFILE%\.ai-safety\buffer.dpapi)。
)
set "AI_SAFE_NEW_KEY="
echo.
echo  登録できました。OpenCode を開き直すと Buffer が使えます。
echo  使うのをやめたいときは「（上級）13_Bufferのキーを削除」をダブルクリックしてください。
echo.
pause
