param(
    [switch]$Check = $false,
    [switch]$Quiet = $false
)

# clipboard-safe-paste.ps1
#
# クリップボードのテキストを secret-scan でマスキングし、結果を再度
# クリップボードに書き戻す便利ツール（v1.4.0 で新規追加）。
# v1.4.1: PS 5.1 互換 Get-Clipboard/Set-Clipboard フォールバック追加 (C-1)
#         $PSScriptRoot によるパス解決に変更 (C-3)

$ErrorActionPreference = "Stop"

# C-3: $PSScriptRoot で secret-scan.ps1 を直接参照（二重階層を作らない）
$SecretScan = Join-Path $PSScriptRoot "secret-scan.ps1"

if (-not (Test-Path -LiteralPath $SecretScan)) {
    Write-Error "safe-paste: secret-scan not found at $SecretScan"
    exit 2
}

# C-1: PS 5.1 互換クリップボード読み取り
# PS 7+ および Windows 10 1809+ STA では Get-Clipboard が使える。
# STA でない PS 5.1 conhost 等では System.Windows.Forms でフォールバック。
function Get-ClipboardText {
    try {
        $text = Get-Clipboard -Raw -ErrorAction Stop
        return $text
    } catch {
        # フォールバック: System.Windows.Forms.Clipboard (STA スレッド必須)
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $clipText = [System.Windows.Forms.Clipboard]::GetText()
        return $clipText
    }
}

# C-1: PS 5.1 互換クリップボード書き込み
function Set-ClipboardText([string]$Value) {
    try {
        Set-Clipboard -Value $Value -ErrorAction Stop
    } catch {
        # フォールバック: System.Windows.Forms.Clipboard (STA スレッド必須)
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.Clipboard]::SetText($Value)
    }
}

$raw = Get-ClipboardText
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

Set-ClipboardText $masked
Write-Host "✓ クリップボードを更新しました（マスキング適用済）" -ForegroundColor Green
Write-Host "  → 外部 LLM に Ctrl+V で貼り付けて使ってください" -ForegroundColor Green
exit 0
