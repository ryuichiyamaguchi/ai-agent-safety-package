@echo off
chcp 932 >nul
:: ============================================================
:: 4_AIを起動する.bat
::   AIをまとめて起動（安全装置つき）のランチャー。
::   メニューの正本はランチャー本体 (launch-integrated.ps1 の menu モード) に
::   1 か所だけ置く。以前はこのボタンに選択肢の写しを持っていたが、ランチャー側の
::   変更に追従できず古いメニュー（AntiGravity 無し等）が残ったため、委譲だけにした。
::   並びは課金プラン順。作業フォルダの選択 (OpenCode 用) もランチャー側で聞かれる。
:: ============================================================
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\launch-integrated.ps1"
if not exist "%TARGET%" (
  echo 安全装置（Bouncer）がまだ準備されていません。
  echo 先に「インストーラー（install-one-click）」を実行してください。
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -Agent menu -Profile standard
if errorlevel 1 (
  echo.
  echo 安全のため起動を中止しました。上のメッセージを確認してください。
  pause
)
