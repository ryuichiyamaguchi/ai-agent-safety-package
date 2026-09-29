@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
REM 10_作業フォルダを元に戻す.bat
REM AI が作業フォルダの中のファイルを書き換えたり消したりしてしまったときに、
REM AI を起動する直前に自動で取っておいた「控え」の時点へ戻します。
REM   ・控えのあとで書き換えられた／消されたファイル → 控えの中身に戻します
REM   ・控えのあとで新しくできたファイル → 消さずに .ai-safety\snapshots\set-aside\（日時）\ へ移します
REM   ・戻す直前の状態も自動で控えに取るので、「元に戻す」自体もあとから取り消せます
REM 一覧 → 番号 → 変わる内容の確認 → y で実行、の流れは
REM .ai-safety\hooks\common\workspace-snapshot.js（wizard）が正本。このボタンは呼ぶだけ。
REM node は画面へ直接書くので（WriteConsoleW）、chcp 932 のままでも日本語は化けない。
REM くわしくは docs\14_作業フォルダを元に戻す.md
set "TARGET=%WORKSPACE%\.ai-safety\hooks\common\workspace-snapshot.js"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを最新版にする」を実行してください。
  pause
  exit /b 1
)
where node >nul 2>nul
if errorlevel 1 (
  echo node コマンドが見つかりません。先に Node.js（LTS 版）を入れてください。
  pause
  exit /b 1
)
node "%TARGET%" wizard --workspace "%WORKSPACE%"
echo.
pause
