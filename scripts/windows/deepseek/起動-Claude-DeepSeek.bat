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
::     コマンド実行など）の暴走」を止めます。さらに送信検査 Gateway が
::     DeepSeek へ送る前に既知パターンの機微情報（API キー・パスワード等）を
::     自動マスキングします。ただし検出できるパターンに限られ、完全な保証では
::     ないため、本当に流出して困る情報は入力しないこと。
::   ・このファイルは素の claude を呼びません。必ず
::     launch-claude-safe.ps1 を経由します（ガードバイパス防止）。
:: ============================================================

:: -- 1. workspace を特定 -----------------------------------------
:: 「呼び出し元が渡した値 → このファイル自身の位置から逆算 → 既定」の順で決める。
:: 「（上級）14_新しい作業フォルダを安全にする」で別のフォルダへ導入した場合、この
:: ファイルは <作業フォルダ>\.ai-safety\hooks\windows\deepseek\ に置かれる。固定パスだと
:: 別のワークスペースのフックを使ってしまうため、自分の位置から 4 階層上を作業フォルダとする。
set "WORKSPACE="
if not "%~1"=="" set "WORKSPACE=%~1"
if "%WORKSPACE%"=="" (
    for %%I in ("%~dp0..\..\..\..") do set "WORKSPACE=%%~fI"
)
if not exist "%WORKSPACE%\.ai-safety\hooks\windows" set "WORKSPACE=%USERPROFILE%\Documents\my-ai-workspace"
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
    set /p AGREE=この点を理解した上で続行しますか？ （yes/no）:
    if /i not "!AGREE!"=="yes" (
        echo 起動をキャンセルしました。
        pause
        exit /b 1
    )
)

:: -- 3. DeepSeek バックエンドへ向ける環境変数を前差し --------------
:: 実キーはここでは読まない。Gateway 子プロセスだけが読む（Claude Code には渡さない）。
:: 鍵の有無だけを「環境変数 → OS の金庫(DPAPI) → 旧平文」の解決結果で確かめる。
:: 金庫化（secret-migrate.js）で旧平文 .deepseek-claude\auth は削除されるため、平文ファイルの
:: 実在で判定すると「登録したのに未登録」で起動できなくなる。
:: BASE_URL is set by the gateway launcher (launch-deepseek-gateway.ps1)
set "ANTHROPIC_AUTH_TOKEN="
set "SECRET_STORE=%WORKSPACE%\.ai-safety\hooks\common\secret-store.js"
set "DS_KEY_PRESENT=unknown"
where node >nul 2>&1
if not errorlevel 1 (
    if exist "%SECRET_STORE%" (
        set "DS_KEY_PRESENT=no"
        for /f "usebackq delims=" %%K in (`node "%SECRET_STORE%" --has deepseek 2^>nul`) do set "DS_KEY_PRESENT=%%K"
    )
)
set "ANTHROPIC_MODEL=deepseek-v4-flash"
set "ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-flash"
set "ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-flash"
REM 1M コンテキストはモデル名でなく、この変数で伝える (Claude Code 2.1.226 以降)。
set "CLAUDE_CODE_MAX_CONTEXT_TOKENS=1048576"
set "ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash"
set "CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash"
set "CLAUDE_CODE_EFFORT_LEVEL=max"
set "GATEWAY_LAUNCH=%HOOKS%\deepseek\launch-deepseek-gateway.ps1"

:: ↑ もし起動時に「モデル名が無効」エラーが出る環境では（GitHub Issue #56990）、
::   上の ANTHROPIC_MODEL 行を次のどちらかに差し替えてください:
::   A案（表示も deepseek にしたい・検証スキップ）:
::     set "ANTHROPIC_CUSTOM_MODEL_OPTION=deepseek-v4-flash"
::   B案（動けばよい・表示は Opus）: ANTHROPIC_MODEL 行を消し、
::     起動後に /model で opus を選ぶ（サーバ側で v4 に振り分け）。

if "!DS_KEY_PRESENT!"=="no" (
    echo.
    echo 【注意】DeepSeek の API キーが未登録です。
    echo   先に「登録-初回だけ.bat」（またはスタートの（上級）1）で
    echo   キーを登録してから、もう一度これを開いてください。
    echo   （登録後すぐ反映されます。再起動は不要です）
    echo.
    pause
    exit /b 1
)

:: -- 4. ガード付き Claude Code を起動（素の claude は呼ばない） -----
:: workspace に移動してから launch-claude-safe.ps1 を呼ぶ。これにより
:: .claude\settings.json の PreToolUse hook（ガード）が効いたまま、
:: バックエンドだけ DeepSeek に向いた Claude Code が起動する。
echo.
echo DeepSeek バックエンドで Claude Code を起動します...
echo （画面のモデル表示が deepseek-v4-flash になっていればOK）
echo.
pushd "%WORKSPACE%"
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%GATEWAY_LAUNCH%" -Workspace "%WORKSPACE%"
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
