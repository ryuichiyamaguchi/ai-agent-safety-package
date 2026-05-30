@echo off
chcp 932 >nul 2>&1
:: ============================================================
:: キー削除.bat
:: 授業後のお片付け用。PC 側に登録した DeepSeek の API キーを消します。
:: ------------------------------------------------------------
:: ・ダブルクリック1回で、Windows ユーザー領域の
::   ANTHROPIC_AUTH_TOKEN を削除します。
:: ・PC 側を消すだけでは不十分です。DeepSeek の管理画面
::   （https://platform.deepseek.com/ の API keys）でも、
::   使ったキーを必ず Delete してください。
:: ============================================================
echo.
echo PC 側の DeepSeek キー（ANTHROPIC_AUTH_TOKEN）を削除します...
reg delete HKCU\Environment /v ANTHROPIC_AUTH_TOKEN /f >nul 2>&1
echo.
echo PC 側のキーを削除しました。
echo.
echo 【まだ終わりではありません】
echo   DeepSeek 管理画面（https://platform.deepseek.com/ の API keys）でも
echo   使ったキーを Delete してください。これで漏えい対策は完了です。
echo.
pause
