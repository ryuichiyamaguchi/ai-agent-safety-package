@echo off
chcp 932 >nul 2>&1
echo =====================================================
echo   DeepSeek 起動デバッグ（この窓は最後まで閉じません）
echo =====================================================
echo.
echo 1) まず環境を表示します:
echo    USERPROFILE = %USERPROFILE%
echo    想定 workspace = %USERPROFILE%\Documents\my-ai-workspace
if exist "%USERPROFILE%\Documents\my-ai-workspace\.ai-safety\hooks\windows\launch-claude-safe.ps1" (
    echo    [OK] launch-claude-safe.ps1 が見つかりました
) else (
    echo    [NG] launch-claude-safe.ps1 が見つかりません ^(workspace のパス違いの可能性^)
)
echo.
echo 2) claude コマンドの場所:
where claude 2>nul || echo    [NG] claude が PATH に見つかりません
echo.
echo 3) 起動-Claude-DeepSeek.bat を呼び出します（出力は全てこの窓に残ります）:
echo -----------------------------------------------------
call "%~dp0起動-Claude-DeepSeek.bat"
echo -----------------------------------------------------
echo.
echo ===== 呼び出し後の終了コード: %ERRORLEVEL% =====
echo もし上に「予期しない」「unexpected」「認識されません」「is not recognized」
echo 等の赤い行や英語エラーが出ていたら、その行をそのまま教えてください。
echo.
pause
