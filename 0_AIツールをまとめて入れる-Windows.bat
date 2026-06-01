@echo off
chcp 65001 >nul
setlocal
REM 0_AIツールをまとめて入れる（Windows・薄い補助）。
REM Node/npm を確認し、npm で入る AI CLI（Codex / Claude Code）をまとめて導入する。
REM ※ AntiGravity(agy) は公式インストーラ方式のため、ここでは入れない。
REM   スタート.html の Step 0-2 の案内に従って別途インストールすること。
REM ※ API キーのログイン（codex login 等）は本人入力が必要なため、ここでは行わない。

echo.
echo ============================================================
echo   AI ツールをまとめて入れる（Codex / Claude Code）
echo ============================================================
echo.

where npm >nul 2>&1
if errorlevel 1 (
  echo 【お願い】Node.js / npm がまだ入っていません。
  echo   さきに https://nodejs.org/ja から「LTS」版を入れてください。
  echo   入れ終わったら、もう一度このファイルをダブルクリックしてください。
  echo.
  pause
  exit /b 1
)

for %%P in (@openai/codex @anthropic-ai/claude-code) do (
  echo ------------------------------------------------------------
  echo 導入中: %%P
  call npm install -g %%P
  if errorlevel 1 (
    echo   （%%P の導入に失敗しました。あとでやり直せます）
  ) else (
    echo   OK: %%P を入れました。
  )
  echo.
)

echo ------------------------------------------------------------
echo AntiGravity（agy）は入れ方が違います。
echo   スタート.html の「0-2」の案内（公式ページ）に従ってください。
echo.
echo このあと、各AIにログインしてください（例: codex login）。
echo   APIキーの入力だけは自分でやる必要があります。
echo.
pause
