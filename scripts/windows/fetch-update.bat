@echo off
chcp 932 >nul 2>&1
cd /d "%TEMP%"
setlocal
set "SCRIPT_DIR=%~dp0"

echo.
echo ============================================================
echo   AI エージェント安全パッケージ  更新（最新版へ）
echo ============================================================
echo.
echo 最新版を GitHub からダウンロードして更新します。
echo （インターネットに接続している必要があります）
echo.
echo 【Windows の警告が出た場合】
echo   「詳細情報」→「実行」をクリックしてください。
echo.
pause

if not exist "%SCRIPT_DIR%fetch-update.ps1" (
    echo 【エラー】fetch-update.ps1 が見つかりません。
    pause
    exit /b 1
)

PowerShell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%fetch-update.ps1"

echo.
pause
