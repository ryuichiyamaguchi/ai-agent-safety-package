@echo off
chcp 932 >nul
setlocal enabledelayedexpansion
:: ============================================================
:: 0_Bouncer統合版を起動.bat
::   Bouncer統合版のランチャー。番号を選ぶと、その組み合わせで
::   AIと見守りモニターをまとめて起動する。
::   メニューの並びは Mac 版 0_Bouncer統合版を起動.command と同じ。
:: ============================================================
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\launch-integrated.ps1"
if not exist "%TARGET%" (
  echo Bouncer統合版がまだ準備されていません。
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)

echo.
echo  Bouncer 統合版
echo ============================================================
echo  1 Codex   標準モード（推奨・軽快）
echo  2 Claude  標準モード（推奨・軽快）
echo  3 Claude  AI補助モード
echo  4 Claude  最大保護モード（ローカルGemmaが必要）
echo  5 OpenCode + DeepSeek V4 Pro（送信検査・Web検索OFF）
echo  6 OpenCode + DeepSeek V4 Pro（Web検索を確認制でON）
echo  7 d-claude + DeepSeek V4 Pro（Claudeの操作感・送信検査・監視ON）
echo  8 OpenCode + DeepSeek V4 Pro（前回の続きから開く）
echo ============================================================
echo.
choice /c 12345678 /n /m "番号を選んでください [1-8]: "

if errorlevel 8 goto opencode_resume
if errorlevel 7 goto d_claude
if errorlevel 6 goto opencode_web
if errorlevel 5 goto opencode
if errorlevel 4 goto claude_max
if errorlevel 3 goto claude_assisted
if errorlevel 2 goto claude
goto codex

:opencode_resume
call :choose_project
if defined PROJECT_DIR (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent opencode -Profile standard -Resume -Project "!PROJECT_DIR!"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent opencode -Profile standard -Resume
)
goto done
:d_claude
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent d-claude -Profile standard
goto done
:opencode_web
call :choose_project
if defined PROJECT_DIR (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent opencode -Profile standard -WebSearch -Project "!PROJECT_DIR!"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent opencode -Profile standard -WebSearch
)
goto done
:opencode
call :choose_project
if defined PROJECT_DIR (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent opencode -Profile standard -Project "!PROJECT_DIR!"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent opencode -Profile standard
)
goto done
:claude_max
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent claude -Profile maximum
goto done
:claude_assisted
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent claude -Profile assisted
goto done
:claude
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent claude -Profile standard
goto done
:codex
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent codex -Profile standard

REM ------------------------------------------------------------
REM OpenCode は「起動したフォルダ」が作業対象になり、動き出したあとで cd しても
REM 移らない（OpenCode 本体の仕様）。案件ごとにフォルダを分けて作業できるよう、
REM 起動前にどこで始めるかを選んでもらう。パスは打たせず、作業フォルダ直下の
REM 一覧から番号で選ぶ。0 または未入力なら従来どおり作業フォルダ直下で起動する。
REM ------------------------------------------------------------
:choose_project
set "PROJECT_DIR="
set /a PCOUNT=0
for /d %%D in ("%WORKSPACE%\*") do (
  set "PNAME=%%~nxD"
  set "PSKIP="
  if /i "!PNAME!"=="スタート" set "PSKIP=1"
  if /i "!PNAME!"=="safe-workspace" set "PSKIP=1"
  if "!PNAME:~0,1!"=="." set "PSKIP=1"
  if not defined PSKIP (
    set /a PCOUNT+=1
    set "PDIR_!PCOUNT!=!PNAME!"
  )
)
if !PCOUNT!==0 goto :eof
echo.
echo  どのフォルダで作業しますか？
echo ============================================================
echo  0 そのまま（作業フォルダ直下）
for /l %%I in (1,1,!PCOUNT!) do echo  %%I !PDIR_%%I!
echo ============================================================
set "PICK="
set /p "PICK=番号を入力してください [0]: "
if not defined PICK goto :eof
if "!PICK!"=="0" goto :eof
REM 数字以外・範囲外はそのまま（作業フォルダ直下）で起動する。
set "PVALID="
for /l %%I in (1,1,!PCOUNT!) do if "!PICK!"=="%%I" set "PVALID=1"
if not defined PVALID (
  echo  その番号はありません。作業フォルダ直下で起動します。
  goto :eof
)
REM 変数名の中で番号を展開するため call を挟む（!PDIR_!PICK!! は書けない）。
call set "PSEL=%%PDIR_!PICK!%%"
if not defined PSEL goto :eof
set "PROJECT_DIR=%WORKSPACE%\!PSEL!"
echo  「!PSEL!」で起動します。
goto :eof

:done
if errorlevel 1 (
  echo.
  echo 安全のため起動を中止しました。上のメッセージを確認してください。
  pause
)
