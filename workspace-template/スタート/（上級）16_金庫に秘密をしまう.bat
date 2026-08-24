@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
cd /d "%WORKSPACE%" 2>nul
REM （上級）16_金庫に秘密をしまう.bat
REM 好きな名前を付けて、好きな文字列（合言葉・トークンなど）を
REM Windows の金庫(DPAPI)にしまいます。
REM   保存先: %USERPROFILE%\.ai-safety\user.<名前>.dpapi（暗号化されています）
REM   名前の一覧: %USERPROFILE%\.ai-safety\user-secrets.index（名前だけ。中身は書きません）
REM 値は画面にもコマンドラインにも出しません（標準入力で secret-store.js へ渡します）。
set "TARGET=%WORKSPACE%\.ai-safety\hooks\common\secret-store.js"
if not exist "%TARGET%" (
  echo スクリプトが見つかりません: %TARGET%
  echo 先に「1_安全パッケージを準備」を実行してください。
  pause
  exit /b 1
)

echo.
echo  ■ 金庫に秘密をしまう
echo.
echo  「金庫」とは、Windows が最初から持っている鍵付きの引き出しのことです
echo  （正式には DPAPI と言います）。
echo.
echo    ・この PC にこの Windows ユーザーでログインできる本人だけが開けられます。
echo    ・中身は暗号化されて保存され、そのままでは読めません。
echo    ・ファイルに書いたときと違い、他のアプリや AI が勝手に覗くことはできません。
echo.
echo  ふつうのファイル（メモ帳など）に書いた場合との違い:
echo    ファイル … 開けば誰でも読めます。AI に「このフォルダを見て」と言った時点で
echo                中身が読まれ、そのまま外へ送られてしまうことがあります。
echo    金庫   … 中身は暗号化され、取り出すには本人の操作が要ります。
echo                このパッケージの AI は金庫を読む権限を持っていません。
echo.
echo  ※ 短い文字列を入れてください（合言葉や API キーなど）。長い文章には向きません。
echo.

set "AI_SAFE_NAME="
set /p "AI_SAFE_NAME=この秘密に付ける名前を入力して Enter（やめるなら何も入れずに Enter）: "
if not defined AI_SAFE_NAME (
  echo 何も入力されませんでした。中止します。
  pause
  exit /b 1
)

echo.
echo  次に、しまいたい中身を入力します。
echo  入力した文字は画面に出ません（肩越しに覗かれても見えないようにするためです）。
set "AI_SAFE_TARGET=%TARGET%"
set "AI_SAFE_MSG_VALUE=中身を入力（または貼り付け）して Enter"
REM ※ 文字コードについて（v1.17.4 で直した文字化けの再発防止）:
REM   ・このファイルは CP932 で、cmd も chcp 932 の CP932 コンソール。
REM   ・[Console]::OutputEncoding は「画面へ出す文字コード」。ここを UTF-8 に
REM     すると CP932 のコンソールに UTF-8 が流れて日本語が化ける。既定のままにする。
REM   ・$OutputEncoding は「ネイティブコマンド（node）へ渡す文字コード」。
REM     node は UTF-8 前提なので、こちらは UTF-8 のままにしておく必要がある。
REM   ・node の標準出力を受け取る箇所だけは [Console]::OutputEncoding を一時的に
REM     UTF-8 にして読み、直後に元へ戻す（日本語の名前を正しく受け取るため）。
powershell -NoProfile -ExecutionPolicy Bypass -Command "$OutputEncoding=[Text.Encoding]::UTF8; $t=$env:AI_SAFE_TARGET; $n=$env:AI_SAFE_NAME; $s=Read-Host $env:AI_SAFE_MSG_VALUE -AsSecureString; $p=[Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)); if($p.Length -eq 0){ exit 3 }; $p | & node $t --user-set $n | Out-Null; exit $LASTEXITCODE"
set "AI_SAFE_RC=%errorlevel%"
set "AI_SAFE_MSG_VALUE="

echo.
if "%AI_SAFE_RC%"=="0" (
  echo  しまえました。名前は「%AI_SAFE_NAME%」です。
  echo.
  echo  取り出したいときは:
  echo    「（上級）17_金庫から秘密を取り出す」をダブルクリック
  echo    → 一覧から番号で選ぶと、中身がクリップボードに入ります。
  echo      （画面には出しません。貼り付けたい場所で Ctrl+V を押してください）
  echo.
  echo  いらなくなったら「（上級）18_金庫の秘密を消す」で消せます。
) else if "%AI_SAFE_RC%"=="3" (
  echo  何も入力されませんでした。中止します。
) else (
  echo  しまえませんでした。上のメッセージを確認してください。
  echo  名前に使えるのは 英数字・ひらがな・カタカナ・漢字・ー・-・_ の 1～40 文字です。
)
set "AI_SAFE_NAME="
set "AI_SAFE_TARGET="
echo.
pause
