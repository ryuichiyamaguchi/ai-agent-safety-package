@echo off
chcp 932 >nul
setlocal
:: ============================================================
:: 6_AIコーチのキーを登録.bat
:: 見守りモニターの「AIコーチ」が使う、無料の Gemini API キーを登録します。
:: キーはこの PC のあなたのフォルダ内のファイルに保存します(環境変数は汚しません)。
:: ============================================================
echo.
echo  AIコーチ用の無料 Gemini API キーを登録します。
echo.
echo  キーの取り方:
echo    1. ブラウザで  https://aistudio.google.com/apikey  を開く
echo    2. Google でログインして「Create API key(APIキーを作成)」
echo    3. 表示されたキーをコピー
echo.
set /p KEY=APIキーを貼り付けて Enter: 
if "%KEY%"=="" (
  echo.
  echo 何も入力されませんでした。中止します。
  pause
  exit /b 1
)
set "GEMINI_KEY=%KEY%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=Join-Path $env:USERPROFILE '.ai-safety'; [void](New-Item -ItemType Directory -Force $d); Set-Content -NoNewline -Encoding ascii -Path (Join-Path $d 'gemini-api-key.txt') -Value $env:GEMINI_KEY"
if errorlevel 1 (
  echo.
  echo 保存に失敗しました。もう一度お試しください。
  pause
  exit /b 1
)
echo.
echo  登録できました。
echo  見守りモニターを開き直すと、AIコーチが使えます。
echo.
pause
