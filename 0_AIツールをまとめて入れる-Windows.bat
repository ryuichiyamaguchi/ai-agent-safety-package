@echo off
chcp 932 >nul
setlocal
rem 0_AIツールをまとめて入れる（Windows・薄い補助）。
rem Codex CLI / Claude Code / OpenCode / agy をまとめて入れる（入っているものは更新する）。
rem 実体は「2_AIツールをまとめて入れる」と同じ scripts\windows\update-ai-tools.ps1
rem （v1.19.5 で 1 本にまとめた。Claude Code は @latest、Playwright の事前導入 playwright-prefetch.js もその中で行う）。
set "TARGET=%~dp0scripts\windows\update-ai-tools.ps1"
if not exist "%TARGET%" (
  echo 必要なファイルが見つかりません: %TARGET%
  echo ZIP を最後まで展開してから、もう一度このファイルをダブルクリックしてください。
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%~dp0."
echo.
pause
