@echo off
chcp 932 >nul
setlocal
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
echo ============================================================
echo.
choice /c 1234567 /n /m "番号を選んでください [1-7]: "

if errorlevel 7 goto d_claude
if errorlevel 6 goto opencode_web
if errorlevel 5 goto opencode
if errorlevel 4 goto claude_max
if errorlevel 3 goto claude_assisted
if errorlevel 2 goto claude
goto codex

:d_claude
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent d-claude -Profile standard
goto done
:opencode_web
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent opencode -Profile standard -WebSearch
goto done
:opencode
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent opencode -Profile standard
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

:done
if errorlevel 1 (
  echo.
  echo 安全のため起動を中止しました。上のメッセージを確認してください。
  pause
)
