@echo off
chcp 932 >nul
setlocal
REM セーフ Codex オート起動（薄いラッパー）。launch-codex-safe.ps1 を --auto 付きで呼ぶだけ。
REM doctor の隔離チェック(金庫)が green のときだけ承認プロンプトが省かれる。
REM 確認できない場合は launcher が理由を表示して通常の都度承認モードで起動する(フェイルクローズ)。
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\launch-codex-safe.ps1"
if not exist "%TARGET%" (
  echo 起動スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
echo オートモード: 安全確認（金庫）が取れたときだけ、承認の手間を省いて起動します。
echo 確認できない場合は、自動で通常の都度承認モードになります。
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -AutoFlag "--auto"
if errorlevel 1 ( echo 問題が起きました。 & pause )
