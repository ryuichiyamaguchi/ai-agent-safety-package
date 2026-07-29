@echo off
chcp 932 >nul 2>&1
setlocal EnableDelayedExpansion

:: ============================================================
:: AI エージェント安全パッケージ  ワンクリックインストーラー
:: ============================================================
:: このファイルをダブルクリックするだけでインストールが完了します

echo.
echo ============================================================
echo   AI エージェント安全パッケージ  インストーラー v1.14.3
echo ============================================================
echo.
echo 【Windows の警告が出た場合】
echo   「詳細情報」をクリック → 「実行」をクリックしてください。
echo   このファイルは本パッケージに付属の正規ファイルです。
echo.
pause

:: -- 1. 自分自身が存在するフォルダを取得 -------------------------
set "SCRIPT_DIR=%~dp0"
:: 末尾の \ を除去
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

:: install-one-click.bat は scripts\windows\ にある。
:: パッケージルートは 2 階層上。
for %%I in ("%SCRIPT_DIR%\..\.." ) do set "PKG_ROOT=%%~fI"

:: install.ps1 の存在確認
if not exist "%SCRIPT_DIR%\install.ps1" (
    echo.
    echo 【エラー】install.ps1 が見つかりません。
    echo   ZIP を正しく展開してから、このファイルをダブルクリックしてください。
    echo   詳しくは docs\01_学校PCで使う.md を参照してください。
    echo.
    pause
    exit /b 1
)

:: -- 2. ZIP ブロック解除 ------------------------------------------
echo.
echo [1/4] ダウンロードブロックを解除しています...
PowerShell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%PKG_ROOT%' -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"
echo   完了しました。

:: -- 3. workspace パスの決定 ---------------------------------------
set "WORKSPACE=%USERPROFILE%\Documents\my-ai-workspace"

:: -- 4. 既存 workspace の確認・バックアップ -----------------------
if exist "%WORKSPACE%" (
    echo.
    echo 【確認】すでに workspace が存在します。
    echo   場所: %WORKSPACE%
    echo   バックアップしてから再セットアップします。
    echo   よろしければ Enter キーを押してください。
    echo   キャンセルする場合は Ctrl+C を押してください。
    echo.
    pause
)

:: -- 5. install.ps1 を呼ぶ ----------------------------------------
echo.
echo [2/4] インストール中... （少し時間がかかります）
echo.
PowerShell -NoProfile -ExecutionPolicy Bypass ^
    -File "%SCRIPT_DIR%\install.ps1" ^
    -Workspace "%WORKSPACE%"

if errorlevel 1 (
    echo.
    echo 【エラー】インストールに失敗しました。
    echo   上のメッセージでエラーの内容を確認してください。
    echo   解決できない場合は docs\01_学校PCで使う.md を読んでください。
    echo   または、講師に画面を見せてください。
    echo.
    pause
    exit /b 1
)

:: -- 6. doctor.ps1 で動作確認 ------------------------------------
set "DOCTOR=%WORKSPACE%\.ai-safety\hooks\windows\doctor.ps1"
echo.
echo [3/4] 動作確認中...
echo.
if exist "%DOCTOR%" (
    PowerShell -NoProfile -ExecutionPolicy Bypass -File "%DOCTOR%"
) else (
    echo   doctor.ps1 が見つかりませんでした。インストール後に手動で確認してください。
)

:: -- 7. 完了画面 -------------------------------------------------
echo.
echo ============================================================
echo   [4/4] インストール完了！
echo ============================================================
echo.
echo   workspace の場所:
echo     %WORKSPACE%
echo.
echo   ============================================================
echo   【毎回この手順で起動してください】
echo   ============================================================
echo.
echo   1. ターミナルで workspace フォルダに移動:
echo      cd %USERPROFILE%\Documents\my-ai-workspace
echo.
echo   2. 安全起動コマンドを実行:
echo      powershell -File .ai-safety\hooks\windows\launch-integrated.ps1 -Agent codex -Profile standard
echo.
echo   ★ 重要: 素の "codex" コマンドを直接打たないでください。
echo      launch-codex-safe を使わない場合、このパッケージの
echo      launcher 経由の保護は効きません。
echo.
echo   3. AI の動きを確認したい場合は別ターミナルで:
echo      powershell -File .ai-safety\hooks\windows\monitor.ps1
echo.
echo   詳しい使い方は docs\00_クイックスタート.md を参照してください。
echo.

:: Open the next-step folder before the final pause.
:: The folder name may be non-ASCII, so find it by the ASCII wrapper pattern.
set "START_OPENED="
for /d %%D in ("%WORKSPACE%\*") do (
    if not defined START_OPENED (
        if exist "%%~fD\2_*.bat" (
            echo.
            echo   Next-step folder:
            echo     %%~fD
            start "" explorer "%%~fD"
            set "START_OPENED=1"
        )
    )
)
if not defined START_OPENED (
    echo.
    echo   Next-step folder was not found. Please open the workspace folder manually.
)
echo.
pause
endlocal
