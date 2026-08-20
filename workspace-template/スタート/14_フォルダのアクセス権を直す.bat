@echo off
chcp 932 >nul
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "WORKSPACE=%%~fI"
set "TARGET=%WORKSPACE%\.ai-safety\hooks\windows\repair-permissions.ps1"
echo.
echo == フォルダのアクセス権を直します ==
echo APIキーの金庫 %USERPROFILE%\.ai-safety に
echo 「アクセスが拒否されました」と出るときに使います。
echo.
echo まず「親フォルダから継承される権限」へ戻し ^(icacls /reset^)、
echo 実際に読み書きできるか確かめます。うまくいかないときは元に戻します。
echo 他の人に開きすぎている設定だけを外します。中身は消しません。
echo 金庫の中身（APIキー）は消えません。キーの作り直しも不要です。
echo.
if not exist "%TARGET%" goto :nofile
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Workspace "%WORKSPACE%" -NoTakeown
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" goto :manual
goto :done

:nofile
echo 見つかりません: %TARGET%
echo 先に「1_安全パッケージを準備」を実行してください。
echo.
echo なお、このボタンが無くても、下の手順で同じことができます。

:manual
echo -----------------------------------------------------------
echo 手作業で直すときは、次のどちらかを行ってください。
echo.
echo ^(A^) コマンドプロンプト ^(cmd^) を開いて、次の 1 行をそのまま貼り付けて実行:
echo.
echo     icacls "%%USERPROFILE%%\.ai-safety" /reset /T /C /Q
echo.
echo     ※ 必ず「コマンドプロンプト ^(cmd^)」で実行してください。
echo        PowerShell では %%USERPROFILE%% が展開されないため動きません。
echo     ※ 管理者として実行する必要はありません。
echo.
echo ^(B^) エクスプローラーだけで直す（コマンドが苦手な方向け）:
echo     1. エクスプローラーのアドレス欄に %%USERPROFILE%% と入れて開く
echo     2. .ai-safety を右クリック → プロパティ
echo     3. セキュリティ タブ → 詳細設定
echo     4. 「継承の有効化」を押す
echo     5. 「子オブジェクトのアクセス許可エントリすべてを、このオブジェクトからの
echo        継承可能なアクセス許可エントリで置き換える」にチェック
echo     6. OK で閉じる
echo -----------------------------------------------------------
echo.

:done
echo 終わったら「10_困ったとき診断」でもう一度確認してください。
echo.
pause
