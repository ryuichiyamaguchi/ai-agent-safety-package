@echo off
chcp 932 >nul
setlocal
REM インストール済みの Codex デスクトップアプリを起動する。
REM スタートメニューのショートカット、無ければ既定のインストール先を探す。
REM 入っていないときは公式サイトを案内するだけで、このボタンは何もインストールしない。
set "EXE=%LOCALAPPDATA%\Programs\Codex\Codex.exe"
if exist "%EXE%" (
  start "" "%EXE%"
  exit /b 0
)
set "LNK="
for /r "%APPDATA%\Microsoft\Windows\Start Menu\Programs" %%F in (Codex*.lnk) do if not defined LNK set "LNK=%%~fF"
if not defined LNK (
  for /r "%ProgramData%\Microsoft\Windows\Start Menu\Programs" %%F in (Codex*.lnk) do if not defined LNK set "LNK=%%~fF"
)
if defined LNK (
  start "" "%LNK%"
  exit /b 0
)
echo Codex アプリが見つかりません。公式サイトからインストールしてください。
echo   https://openai.com/codex/
echo.
echo 何かキーを押すと公式サイトを開きます...
pause >nul
start "" "https://openai.com/codex/"
