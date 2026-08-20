@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
REM （上級）12_AIコーチのキーを削除.bat
REM 登録した AIコーチ（Gemini）の API キー を、この PC から消します。
REM ・Windows の金庫(DPAPI)のファイルと、移行前の平文ファイルの両方を消します。
REM ・PC 側を消しても、発行元のサイトではキーが生きています。

echo.
echo  AIコーチ（Gemini）の API キー をこの PC から削除します...
del /f /q "%USERPROFILE%\.ai-safety\gemini.dpapi" >nul 2>&1
del /f /q "%USERPROFILE%\.ai-safety\gemini-api-key.txt" >nul 2>&1
echo  削除しました（登録されていなかった場合は何も起きません）。
echo.
echo  【まだ終わりではありません】
echo    Google AI Studio（https://aistudio.google.com/apikey）でも、そのキーを削除してください。
echo.
pause
