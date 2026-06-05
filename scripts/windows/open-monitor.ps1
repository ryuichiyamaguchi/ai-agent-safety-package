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
        Write-Host "ブラウザを開けませんでした。次のファイルを手動で開いてください:"
        Write-Host "  $nowHtml"
        Write-Host ""
        Write-Host "（ブラウザが使えない場合は、コンソール版モニターも使えます: $PSScriptRoot\monitor.ps1）"
        exit 1
    }
}

# placeholder すら生成できなかった場合のフォールバック（コンソール版）。
Write-Host "HTML モニターを準備できませんでした。"
Write-Host "ログ保存先: $logDir"
Write-Host "代わりにコンソール版モニターを開きます…"
Write-Host ""
& (Join-Path $PSScriptRoot "monitor.ps1")
