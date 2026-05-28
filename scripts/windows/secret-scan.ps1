param(
    [Parameter(Position=0)]
    [string]$InputFile = "",

    [switch]$Mask = $false,
    [switch]$Check = $false,
    [switch]$Quiet = $false,
    [switch]$Help = $false
)

# secret-scan.ps1
#
# 機微情報スキャナ（v1.4.0 で新規追加）
# 外部 LLM（DeepSeek 等）に貼り付ける前のテキストを検査し、API キー・
# パスワード等を [MASKED:type] に置換する。
#
# 使い方:
#   Get-Content input.txt | .\secret-scan.ps1           # 標準入力
#   .\secret-scan.ps1 input.txt                         # ファイル
#   Get-Clipboard | .\secret-scan.ps1 -Mask | Set-Clipboard
#
# 終了コード:
#   0 = マスキングして出力（検出 0 件も含む）
#   1 = -Check モードで検出あり
#   2 = 入力読み込み失敗

$ErrorActionPreference = "Stop"

if ($Help) {
    Get-Content $MyInvocation.MyCommand.Path | Select-Object -Skip 10 -First 16 |
        ForEach-Object { $_ -replace '^# ?', '' }
    exit 0
}

# デフォルトは Mask モード（Check 未指定時）
if (-not $Check) { $Mask = $true }

# 入力を取得
if ($InputFile) {
    if (-not (Test-Path -LiteralPath $InputFile)) {
        Write-Error "secret-scan: cannot read: $InputFile"
        exit 2
    }
    $raw = Get-Content -LiteralPath $InputFile -Raw -ErrorAction Stop
} else {
    $raw = [Console]::In.ReadToEnd()
}

if ($null -eq $raw) { $raw = "" }

# 検出パターン
$patterns = @{
    openai      = 'sk-(proj-)?[A-Za-z0-9_-]{20,}'
    anthropic   = 'sk-ant-[A-Za-z0-9_-]{20,}'
    google      = 'AIza[0-9A-Za-z_-]{25,}'
    aws         = '(AKIA|ASIA)[0-9A-Z]{16}'
    github      = 'gh[pousr]_[A-Za-z0-9_]{36,255}'
    slack       = 'xox[baprs]-[A-Za-z0-9-]{10,}'
    jwt         = 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'
    private_key = '-----BEGIN (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----'
    generic     = '(api[_-]?key|secret|token|password|passwd|pwd)\s*[:=]\s*[''"]?[A-Za-z0-9_.+/=-]{12,}'
}

$counts = @{}
$total = 0
foreach ($key in $patterns.Keys) {
    $mList = [regex]::Matches($raw, $patterns[$key], 'IgnoreCase')
    $counts[$key] = $mList.Count
    $total += $mList.Count
}

# 警告出力（stderr）
if (-not $Quiet -and $total -gt 0) {
    Write-Host "⚠ secret-scan: $total 件の機微情報を検出しました" -ForegroundColor Red
    foreach ($key in @('openai','anthropic','google','aws','github','slack','jwt','private_key','generic')) {
        if ($counts[$key] -gt 0) {
            Write-Host ("  - {0,-13}: {1} 件" -f $key, $counts[$key]) -ForegroundColor Yellow
        }
    }
    if ($Mask) {
        Write-Host "→ マスキングして出力します（本物の値は外部 LLM に送られません）" -ForegroundColor Red
    }
}

# 監査ログ
$logDir = $env:AI_SAFE_LOG_DIR
if (-not $logDir) { $logDir = Join-Path $HOME ".ai-safety\logs" }
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logPath = Join-Path $logDir "secret-scan-events.jsonl"
$mode = if ($Check) { "check" } else { "mask" }
$logEntry = [PSCustomObject]@{
    ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    user = $env:USERNAME
    mode = $mode
    cwd = (Get-Location).Path
    total = $total
    counts = $counts
}
($logEntry | ConvertTo-Json -Compress) | Add-Content -LiteralPath $logPath -Encoding UTF8

# Check モードは exit code だけ返す
if ($Check) {
    if ($total -gt 0) { exit 1 } else { exit 0 }
}

# マスキング
$masked = $raw
$masked = [regex]::Replace($masked, $patterns.openai,      '[MASKED:openai]')
$masked = [regex]::Replace($masked, $patterns.anthropic,   '[MASKED:anthropic]')
$masked = [regex]::Replace($masked, $patterns.google,      '[MASKED:google]')
$masked = [regex]::Replace($masked, $patterns.aws,         '[MASKED:aws]')
$masked = [regex]::Replace($masked, $patterns.github,      '[MASKED:github]')
$masked = [regex]::Replace($masked, $patterns.slack,       '[MASKED:slack]')
$masked = [regex]::Replace($masked, $patterns.jwt,         '[MASKED:jwt]')
$masked = [regex]::Replace($masked, '-----BEGIN (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----', '[MASKED:private_key_begin]')
$masked = [regex]::Replace($masked, '-----END (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----',   '[MASKED:private_key_end]')
$masked = [regex]::Replace($masked, $patterns.generic, {
    param($m)
    # キー名と区切り文字を残し、値だけマスク
    $innerMatch = [regex]::Match($m.Value, '^(.+?)([:=]\s*[''"]?)([A-Za-z0-9_.+/=-]{12,})([''"]?)$')
    if ($innerMatch.Success) {
        return "$($innerMatch.Groups[1].Value)$($innerMatch.Groups[2].Value)[MASKED:generic]$($innerMatch.Groups[4].Value)"
    }
    return '[MASKED:generic]'
}, 'IgnoreCase')

# 出力（改行を保持）
[Console]::Out.Write($masked)
exit 0
