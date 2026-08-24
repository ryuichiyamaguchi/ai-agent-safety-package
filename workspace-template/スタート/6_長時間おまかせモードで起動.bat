@echo off
chcp 932 >nul
setlocal
:: 長時間おまかせモード（目を離して AI に長く作業させる）で起動する。
:: Claude / Codex / OpenCode / AntiGravity から選べる。
:: Windows で壁（OS のサンドボックス）があるのは Codex だけ。壁が無いものを選んだ場合は
:: 「壁がありません」と一度だけ確認してから進む。deny 床と記録はどの環境でも外していない。
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\launch-longrun.ps1"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「インストーラー（install-one-click）」を実行してください。
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%"
echo.
pause
