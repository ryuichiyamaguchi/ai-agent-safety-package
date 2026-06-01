@echo off
setlocal
set "HERE=%~dp0"
set "TARGET=%HERE%scripts\windows\install-one-click.bat"
if not exist "%TARGET%" (
  echo [ERROR] Installer not found: %TARGET%
  echo Make sure this file is in the package root folder.
  pause
  exit /b 1
)
start "AI Safety Installer" cmd /k call "%TARGET%"
exit /b 0
