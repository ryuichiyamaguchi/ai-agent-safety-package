@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
REM 正しい PowerShell を新規ウィンドウで開く(PATH も読み直されるので d-claude 等が使える)。
REM $ など別のシェルが開いてしまう環境向け。ダブルクリックするだけ。
start "" powershell -NoExit -ExecutionPolicy Bypass -Command "Set-Location -LiteralPath '%WORKSPACE%'; Write-Host 'このウィンドウで d-claude / codex-safe / claude-safe などが使えます。' -ForegroundColor Green"
