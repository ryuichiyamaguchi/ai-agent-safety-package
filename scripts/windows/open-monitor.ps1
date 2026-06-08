# open-monitor.ps1 — HTML 見守りモニター(now.html)を既定ブラウザで開く。
#
# 「見守りモニターを起動」ボタンの実体。
#   1. ログディレクトリを解決（guards / monitor.ps1 と同一ロジック）
#   2. now.html がまだ無ければ待機カードの placeholder を生成
#   3. start（既定ブラウザ）で表示（meta refresh + JS reload で自動更新）
#
# ガード発火後は guard 側 (Explainer.ps1 Write-NowHtml) が同じ now.html を
# 上書きするので、本物の承認カードに自動で切り替わる。
#
# 環境変数:
#   AI_SAFE_LOG_DIR          ログディレクトリ（既定: $HOME\.ai-safety\logs）
#   AI_SAFE_MONITOR_INTERVAL 自動更新間隔秒（既定: 1）

$ErrorActionPreference = "Stop"

# ログディレクトリ解決: monitor.ps1 / SafetyPolicy.ps1 と完全に揃える。
$logDir = $env:AI_SAFE_LOG_DIR
if (-not $logDir) { $logDir = Join-Path $HOME ".ai-safety\logs" }
$nowHtml = Join-Path $logDir "now.html"

# --- AI コーチ・モニター（Node サーバ）を優先起動。Node 不在/失敗時は file:// にフォールバック ---
# サーバはこのウィンドウが開いている間だけ動く（閉じる/Ctrl+C で停止）。常駐デーモンにはしない。
$serverJs = Join-Path $PSScriptRoot "..\common\monitor-server.js"
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd -and (Test-Path -LiteralPath $serverJs) -and $env:AI_SAFE_MONITOR_NO_SERVER -ne "1") {
    $proc = $null
    $started = $false
    try {
        $urlFile = Join-Path $logDir "monitor-url.txt"
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        Remove-Item -LiteralPath $urlFile -ErrorAction SilentlyContinue
        $env:AI_SAFE_LOG_DIR = $logDir
        # node の出力（URL+トークン）はターミナルに出さずログへ。
        $srvLog = Join-Path $logDir "monitor-server.log"
        $srvErr = Join-Path $logDir "monitor-server.err.log"
        $proc = Start-Process -FilePath $nodeCmd.Source -ArgumentList @($serverJs) -NoNewWindow -PassThru -RedirectStandardOutput $srvLog -RedirectStandardError $srvErr
        for ($i = 0; $i -lt 25; $i++) { if (Test-Path -LiteralPath $urlFile) { break }; Start-Sleep -Milliseconds 200 }
        if (Test-Path -LiteralPath $urlFile) {
            $url = (Get-Content -LiteralPath $urlFile -Raw).Trim()
            Start-Process $url
            Write-Host "AI コーチ・モニターを起動しました。"
            Write-Host "（このウィンドウを閉じる、または Ctrl+C で停止します）"
            $started = $true
            Wait-Process -Id $proc.Id
        } else {
            Write-Host "サーバ起動を確認できませんでした。従来の file:// モニターに切り替えます。"
        }
    } catch {
        Write-Host "AI コーチ・モニターの起動に失敗しました。従来のモニターに切り替えます。"
    } finally {
        # 中断・終了時に node サーバを確実に止める（プロセスリーク防止）。
        if ($proc -and -not $proc.HasExited) { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
    }
    if ($started) { exit 0 }
}

# placeholder 生成は Explainer.ps1 の Write-NowHtmlPlaceholder を再利用する
# （重複ロジックを増やさない）。source / 生成に失敗しても open は試みる。
if (-not (Test-Path -LiteralPath $nowHtml)) {
    $explainer = Join-Path $PSScriptRoot "lib\Explainer.ps1"
    if (Test-Path -LiteralPath $explainer) {
        try {
            . $explainer
            if (Get-Command Write-NowHtmlPlaceholder -ErrorAction SilentlyContinue) {
                [void](Write-NowHtmlPlaceholder $logDir)
            }
        } catch {
            # フェイルセーフ: placeholder 失敗でも下で open を試みる
        }
    }
}

if (Test-Path -LiteralPath $nowHtml) {
    try {
        Start-Process $nowHtml
        exit 0
    } catch {
        # F-G: ブラウザ起動失敗時はコンソール版へ自動フォールバック（非エンジニア配慮）。
        Write-Host "ブラウザを開けませんでした。コンソール版モニターを表示します。"
        Write-Host ""
    }
}

# placeholder 生成失敗 or ブラウザ起動失敗時のフォールバック（コンソール版）。
& (Join-Path $PSScriptRoot "monitor.ps1")
