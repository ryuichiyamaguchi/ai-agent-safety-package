@echo off
chcp 65001 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\launch-integrated.ps1"
if not exist "%TARGET%" (
  echo Bouncer integrated launcher was not found.
  echo Run the Safety Package installer first.
  pause
  exit /b 1
)

echo.
echo Bouncer Integrated
echo ================================================
echo 1 Codex    Standard ^(recommended, no local LLM^)
echo 2 Claude   Standard ^(recommended, no local LLM^)
echo 3 Claude   Assisted
echo 4 Claude   Maximum ^(local Gemma required^)
echo 5 OpenCode + DeepSeek V4 Pro ^(web search off^)
echo 6 OpenCode + DeepSeek V4 Pro ^(web search opt-in^)
echo.
choice /c 123456 /n /m "Select [1-6]: "

if errorlevel 6 goto opencode_web
if errorlevel 5 goto opencode
if errorlevel 4 goto claude_max
if errorlevel 3 goto claude_assisted
if errorlevel 2 goto claude
goto codex

:opencode_web
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent opencode -Profile standard -WebSearch
goto done
:opencode
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent opencode -Profile standard
goto done
:claude_max
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent claude -Profile maximum
goto done
:claude_assisted
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent claude -Profile assisted
goto done
:claude
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent claude -Profile standard
goto done
:codex
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent codex -Profile standard

:done
if errorlevel 1 (
  echo.
  echo The launcher stopped safely. Check the message above.
  pause
)
