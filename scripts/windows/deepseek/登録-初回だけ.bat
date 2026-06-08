@echo off
chcp 932 >nul 2>&1
:: ============================================================
:: 登録-初回だけ.bat
:: DeepSeek の API キーを、この PC のあなたのフォルダ内のファイルに保存します(初回1回だけ)。
:: ------------------------------------------------------------
:: ・このファイルには API キーは書かれていません。実行時に入力した値を
:: 　 %USERPROFILE%\.deepseek-claude\auth に保存します(環境変数は汚しません)。
:: ・暗号化ではなく、本人のアカウントからは読める状態です。
:: 　 漏えい対策は「少額チャージ + 授業後にキー削除」で守ります。
:: ============================================================
echo.
echo DeepSeek の API キーを登録します。
echo (次の行で右クリック貼り付け → Enter)
echo.
set /p KEY=APIキー:
if "%KEY%"=="" (
    echo.
    echo 何も入力されませんでした。中止します。
    pause
    exit /b 1
)
set "DS_KEY=%KEY%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=Join-Path $env:USERPROFILE '.deepseek-claude'; [void](New-Item -ItemType Directory -Force $d); Set-Content -NoNewline -Encoding ascii -Path (Join-Path $d 'auth') -Value $env:DS_KEY"
if errorlevel 1 (
    echo.
    echo 保存に失敗しました。もう一度お試しください。
    pause
    exit /b 1
)
echo.
echo 登録できました。このウィンドウは閉じてOKです。
echo (次に d-claude(または「起動-Claude-DeepSeek.bat」)を開くとすぐ反映されます。再起動は不要です)
pause
