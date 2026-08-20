@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
:: ============================================================
:: 6_AIコーチのキーを登録.bat
:: 見守りモニターで安全イベントやAI回答を相談するときに使う、無料の Gemini API キーを登録します。
:: v1.17.0 から、キーは Windows の金庫(DPAPI)で暗号化して保存します。
::   保存先: %USERPROFILE%\.ai-safety\gemini.dpapi
::   ・暗号化した Windows ユーザー + 同じ PC でしか復号できません。
::   ・ファイルを開いても「読めない文字列」になっています(実際に開いて確かめてみてください)。
::   ・PC を買い替えたり Windows を入れ直すと復号できなくなります。そのときはキーを作り直します。
:: 金庫が使えない環境では、これまでどおり .ai-safety\gemini-api-key.txt に保存します。
:: ============================================================
echo.
echo  安全イベント・AI回答相談用の無料 Gemini API キーを登録します。
echo.
echo  キーの取り方:
echo    1. ブラウザで  https://aistudio.google.com/apikey  を開く
echo    2. Google でログインして「Create API key(APIキーを作成)」
echo    3. 表示されたキーをコピー
echo.
set "KEY="
set /p KEY=APIキーを貼り付けて Enter: 
if "%KEY%"=="" (
  echo.
  echo 何も入力されませんでした。中止します。
  pause
  exit /b 1
)
set "AI_SAFE_NEW_KEY=%KEY%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$k=($env:AI_SAFE_NEW_KEY).Trim(); if($k.Length -eq 0){exit 1}; $d=Join-Path $env:USERPROFILE '.ai-safety'; [void](New-Item -ItemType Directory -Force $d); $p=Join-Path $d 'gemini.dpapi'; $legacy=Join-Path $d 'gemini-api-key.txt'; $w='v1:'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($k)); (ConvertTo-SecureString $w -AsPlainText -Force | ConvertFrom-SecureString) | Set-Content -LiteralPath $p -Encoding ascii -NoNewline; $ss=ConvertTo-SecureString ((Get-Content -LiteralPath $p -Raw).Trim()); $b=[Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)); $back=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b.Substring(3))); if($back -eq $k){ Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue; exit 0 } else { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; exit 1 }"
if errorlevel 1 (
  echo.
  echo  金庫に入れられなかったため、これまでどおりファイルに保存します。
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=Join-Path $env:USERPROFILE '.ai-safety'; [void](New-Item -ItemType Directory -Force $d); Set-Content -NoNewline -Encoding ascii -Path (Join-Path $d 'gemini-api-key.txt') -Value ($env:AI_SAFE_NEW_KEY).Trim()"
  if errorlevel 1 (
    echo.
    echo 保存に失敗しました。もう一度お試しください。
    set "AI_SAFE_NEW_KEY="
    pause
    exit /b 1
  )
) else (
  echo.
  echo  金庫にしまいました(%USERPROFILE%\.ai-safety\gemini.dpapi)。
  echo  中身は暗号化されています。開いても読めない文字列であることを確かめてみてください。
)
set "AI_SAFE_NEW_KEY="
echo.
echo  登録できました。
echo  見守りモニターを開き直すと、安全イベントや取得済みAI回答をAIに相談できます。
echo.
pause
