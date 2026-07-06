@echo off
chcp 932 >nul 2>&1
setlocal
set "SCRIPT_DIR=%~dp0"
echo.
echo d-claude 診断ツールを実行します（何も変更しません）。
echo.
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%診断.ps1"
echo.
pause
