@echo off
chcp 932 >nul 2>&1
:: ============================================================
:: 登録-初回だけ.bat
:: DeepSeek の API キーを、この PC の金庫(DPAPI)に暗号化して保存します(初回1回だけ)。
:: ------------------------------------------------------------
:: ・このファイルには API キーは書かれていません。実行時に入力した値を
:: 　 %USERPROFILE%\.ai-safety\deepseek.dpapi に暗号化して保存します(環境変数は汚しません)。
:: ・暗号化した Windows ユーザー + 同じ PC でしか復号できません。
:: 　 他人の PC にコピーしても開けない代わりに、PC を替えると復号できなくなります。
:: ・金庫が使えない環境では、これまでどおり .deepseek-claude\auth に保存します。
:: 　 漏えい対策は「少額チャージ + 授業後にキー削除」も併せて守ります。
:: ============================================================
echo.
echo DeepSeek の API キーを登録します。
echo (次の行で右クリック貼り付け → Enter)
echo.
set "KEY="
set /p KEY=APIキー:
if "%KEY%"=="" (
    echo.
    echo 何も入力されませんでした。中止します。
    pause
    exit /b 1
)
set "AI_SAFE_NEW_KEY=%KEY%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$k=($env:AI_SAFE_NEW_KEY).Trim(); if($k.Length -eq 0){exit 1}; $d=Join-Path $env:USERPROFILE '.ai-safety'; [void](New-Item -ItemType Directory -Force $d); $p=Join-Path $d 'deepseek.dpapi'; $legacy=Join-Path (Join-Path $env:USERPROFILE '.deepseek-claude') 'auth'; $w='v1:'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($k)); (ConvertTo-SecureString $w -AsPlainText -Force | ConvertFrom-SecureString) | Set-Content -LiteralPath $p -Encoding ascii -NoNewline; $ss=ConvertTo-SecureString ((Get-Content -LiteralPath $p -Raw).Trim()); $b=[Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)); $back=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b.Substring(3))); if($back -eq $k){ Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue; exit 0 } else { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; exit 1 }"
if errorlevel 1 (
    echo.
    echo  金庫に入れられなかったため、これまでどおりファイルに保存します。
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$k=($env:AI_SAFE_NEW_KEY).Trim(); $d=Join-Path $env:USERPROFILE '.deepseek-claude'; [void](New-Item -ItemType Directory -Force $d); $p=Join-Path $d 'auth'; [System.IO.File]::WriteAllText($p, $k+[char]10, (New-Object System.Text.UTF8Encoding($false))); $rb=([System.IO.File]::ReadAllText($p)).Trim(); if($k.Length -gt 0 -and $rb -eq $k){exit 0}else{exit 1}"
    if errorlevel 1 (
        echo.
        echo 保存に失敗しました。もう一度お試しください。
        set "AI_SAFE_NEW_KEY="
        pause
        exit /b 1
    )
) else (
    echo.
    echo  金庫にしまいました(%USERPROFILE%\.ai-safety\deepseek.dpapi)。
    echo  ファイルを開いても「読めない文字列」であることを確かめてみてください。
)
set "AI_SAFE_NEW_KEY="
echo.
echo 登録できました。このウィンドウは閉じてOKです。
echo (次に d-claude(または「起動-Claude-DeepSeek.bat」)を開くとすぐ反映されます。再起動は不要です)
pause
