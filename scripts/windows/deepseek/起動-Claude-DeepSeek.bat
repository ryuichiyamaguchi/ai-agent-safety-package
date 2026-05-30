@echo off
chcp 932 >nul 2>&1
setlocal EnableDelayedExpansion
:: ============================================================
:: 起動-Claude-DeepSeek.bat
:: 「DeepSeek を裏で使う Claude Code」を、本パッケージの保護フック
:: （ガード）が効いたまま起動します。毎日これをダブルクリック。
:: ------------------------------------------------------------
:: 重要（正直にお伝えする事実）:
::   ・会話内容は DeepSeek（中国管轄のサーバー）に送信されます。
::     本パッケージのガードは「AI のツール操作（ファイル削除・危険な
::     コマンド実行など）の暴走」を止めますが、DeepSeek への
::     「送信そのもの」は止めません。流出して困る情報は書かないこと。
::   ・このファイルは素の claude を呼びません。必ず
::     launch-claude-safe.ps1 を経由します（ガードバイパス防止）。
:: ============================================================

:: -- 1. workspace を特定（インストーラ既定の場所） ----------------
set "WORKSPACE=%USERPROFILE%\Documents\my-ai-workspace"
set "HOOKS=%WORKSPACE%\.ai-safety\hooks\windows"
set "LAUNCH_CLAUDE=%HOOKS%\launch-claude-safe.ps1"
set "DEEPSEEK_GATE=%HOOKS%\launch-deepseek-safe.ps1"

if not exist "%LAUNCH_CLAUDE%" (
    echo.
    echo 【エラー】安全ランチャーが見つかりません:
    echo   %LAUNCH_CLAUDE%
    echo.
    echo   先に install-one-click.bat で安全パッケージを
    echo   インストールしてください（workspace が未作成です）。
    echo.
    pause
    exit /b 1
)

:: -- 2. DeepSeek 念押しゲート（赤枠警告 + yes/no） -----------------
:: workspace 内の launch-deepseek-safe.ps1 を呼び、「中国管轄サーバーに
:: 送信される」事実への同意を取る。yes 以外なら exit 1 が返るので中断。
if exist "%DEEPSEEK_GATE%" (
    PowerShell -NoProfile -ExecutionPolicy Bypass -File "%DEEPSEEK_GATE%" -ConsentOnly
    if errorlevel 1 (
        echo.
        echo 起動をキャンセルしました。
        pause
        exit /b 1
    )
) else (
    echo.
    echo 【注意】DeepSeek 同意ゲート（launch-deepseek-safe.ps1）が
    echo   見つかりませんでした。会話内容は DeepSeek（中国管轄）に
    echo   送信されます。流出して困る情報は書かないでください。
    echo.
    set /p AGREE=この点を理解した上で続行しますか？ (yes/no):
    if /i not "!AGREE!"=="yes" (
        echo 起動をキャンセルしました。
        pause
        exit /b 1
    )
)

:: -- 3. DeepSeek バックエンドへ向ける環境変数を前差し --------------
:: ANTHROPIC_AUTH_TOKEN は「登録-初回だけ.bat」で setx 済み（ここには書かない）。
set "ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic"
set "ANTHROPIC_MODEL=deepseek-v4-pro"
set "ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash"

:: ↑ もし起動時に「モデル名が無効」エラーが出る環境では（GitHub Issue #56990）、
::   上の ANTHROPIC_MODEL 行を次のどちらかに差し替えてください:
::   A案（表示も deepseek にしたい・検証スキップ）:
::     set "ANTHROPIC_CUSTOM_MODEL_OPTION=deepseek-v4-pro"
::   B案（動けばよい・表示は Opus）: ANTHROPIC_MODEL 行を消し、
::     起動後に /model で opus を選ぶ（サーバ側で v4 に振り分け）。

if "%ANTHROPIC_AUTH_TOKEN%"=="" (
    echo.
    echo 【注意】ANTHROPIC_AUTH_TOKEN が未登録のようです。
    echo   先に「登録-初回だけ.bat」を実行してから、この
    echo   ウィンドウを一度閉じ、もう一度この .bat を開いてください。
    echo   （環境変数は新しいウィンドウから反映されます）
    echo.
)

:: -- 4. ガード付き Claude Code を起動（素の claude は呼ばない） -----
:: workspace に移動してから launch-claude-safe.ps1 を呼ぶ。これにより
:: .claude\settings.json の PreToolUse hook（ガード）が効いたまま、
:: バックエンドだけ DeepSeek に向いた Claude Code が起動する。
echo.
echo DeepSeek バックエンドで Claude Code を起動します...
echo （画面のモデル表示が deepseek-v4-pro になっていればOK）
echo.
pushd "%WORKSPACE%"
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%LAUNCH_CLAUDE%" -Workspace "%WORKSPACE%"
set "EXITCODE=%ERRORLEVEL%"
popd

echo.
echo Claude Code（DeepSeek）を終了しました。
echo 確認: https://platform.deepseek.com/ の Usage / Billing で
echo       残高が減っていれば、確実に DeepSeek が動いていました。
echo.
pause
endlocal
exit /b %EXITCODE%
