@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
REM 作業フォルダ（my-ai-workspace）をエクスプローラーで開く。
REM ターミナルで開きたいときは「11_PowerShellを開く」を使う。
start "" explorer "%WORKSPACE%"
