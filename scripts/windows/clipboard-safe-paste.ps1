param(
    [switch]$Check = $false,
    [switch]$Quiet = $false
)

# clipboard-safe-paste.ps1
#
# クリップボードのテキストを secret-scan でマスキングし、結果を再度
# クリップボードに書き戻す便利ツール（v1.4.0 で新規追加）。

$ErrorActionPreference = "Stop"
$PkgRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$SecretScan = Join-Path $PkgRoot "scripts\windows\secret-scan.ps1"

if (-not (Test-Path -LiteralPath $SecretScan)) {
    Write-Error "safe-paste: secret-scan not found at $SecretScan"
    exit 2
}

$raw = Get-Clipboard -Raw -ErrorAction Stop
if (-not $raw -or $raw.Length -eq 0) {
    Write-Host "safe-paste: クリップボードが空です" -ForegroundColor Red
    exit 1
}

# 引数を secret-scan に渡す
$scanArgs = @()
if ($Check) { $scanArgs += "-Check" }
if ($Quiet) { $scanArgs += "-Quiet" }

if ($Check) {
    # check モード: クリップボードは触らない
    $raw | & powershell -ExecutionPolicy Bypass -File $SecretScan @scanArgs
    exit $LASTEXITCODE
}

$masked = $raw | & powershell -ExecutionPolicy Bypass -File $SecretScan @scanArgs

if ($LASTEXITCODE -ne 0) {
    Write-Host "safe-paste: secret-scan が exit $LASTEXITCODE で失敗しました" -ForegroundColor Red
    exit $LASTEXITCODE
}

Set-Clipboard -Value $masked
Write-Host "✓ クリップボードを更新しました（マスキング適用済）" -ForegroundColor Green
Write-Host "  → 外部 LLM に Ctrl+V で貼り付けて使ってください" -ForegroundColor Green
exit 0
