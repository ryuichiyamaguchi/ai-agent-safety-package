@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
REM 作業ウィンドウを開く: workspace へ移動し UTF-8 に切替(ccmux の表示崩れ対策)してから ccmux 起動。
REM ccmux 未導入なら普通の PowerShell として使える(d-claude 等 OK)。
start "" powershell -NoExit -ExecutionPolicy Bypass -Command "Set-Location -LiteralPath '%WORKSPACE%'; chcp 65001 | Out-Null; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; if (Get-Command ccmux -ErrorAction SilentlyContinue) { ccmux } else { Write-Host 'ccmux が入っていません。先に「（上級）10_ccmuxを入れる」を実行してください。' -ForegroundColor Yellow; Write-Host 'このウィンドウでも d-claude / codex-safe などは使えます。' -ForegroundColor Green }"
