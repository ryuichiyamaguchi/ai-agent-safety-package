@echo off
chcp 65001 >nul
setlocal
set "HERE=%~dp0"
set "TARGET=%HERE%scripts\windows\install-one-click.bat"
if not exist "%TARGET%" (
  echo インストーラが見つかりません: %TARGET%
  pause
  exit /b 1
)
call "%TARGET%"
