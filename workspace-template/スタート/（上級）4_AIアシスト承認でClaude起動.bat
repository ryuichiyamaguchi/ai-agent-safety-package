@echo off
chcp 932 >nul
setlocal
REM AIアシスト承認つきセーフ Claude 起動（薄いラッパー）。
REM 既存 launch-claude-safe.ps1 を AI_SAFE_ASSISTED_APPROVAL=1 で呼ぶだけ。
REM グレー（決定的に危険でない）コマンドは「2つのAI判定（提案＋Geminiの検証）」で、
REM 両方OKなら自動承認・迷うときだけ確認。危険コマンド（curl/.env/rm -rf 等）は常にブロック（不変）。
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\launch-claude-safe.ps1"
if not exist "%TARGET%" (
  echo 起動スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)
echo AIアシスト承認モードで起動します（定型は自走・危険はブロック・迷うものだけ確認）。
set "AI_SAFE_ASSISTED_APPROVAL=1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%"
if errorlevel 1 ( echo 問題が起きました。 & pause )
