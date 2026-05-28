# agent-monitor: 別タブ/別ペインで起動する簡易ビューア
#
# 上に「いま AI がやろうとしていること」（now.md）
# 下に「直近の出来事」（events-YYYY-MM-DD.jsonl の整形）
# Ctrl+C で終了。
#
# 環境変数:
#   AI_SAFE_LOG_DIR        ログディレクトリ（既定: $HOME\.ai-safety\logs）
#   AI_SAFE_MONITOR_TAIL   表示するイベント件数（既定: 12）
#   AI_SAFE_MONITOR_INTERVAL  再描画間隔秒（既定: 1）

param(
    [int]$TailN = 0,
    [int]$IntervalSec = 0
)

if ($TailN -le 0) {
    if ($env:AI_SAFE_MONITOR_TAIL) { $TailN = [int]$env:AI_SAFE_MONITOR_TAIL } else { $TailN = 12 }
}
if ($IntervalSec -le 0) {
    if ($env:AI_SAFE_MONITOR_INTERVAL) { $IntervalSec = [int]$env:AI_SAFE_MONITOR_INTERVAL } else { $IntervalSec = 1 }
}

$logDir = $env:AI_SAFE_LOG_DIR
if (-not $logDir) { $logDir = Join-Path $HOME ".ai-safety\logs" }
$nowPath = Join-Path $logDir "now.md"

function Format-Event {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    try {
        $obj = $Line | ConvertFrom-Json
        $ts = [string]$obj.ts
        $short = $ts -replace ".*T", "" -replace "\..*", "" -replace "Z$", "" -replace "([+-]\d{2}:?\d{2})$", ""
        $decision = [string]$obj.decision
        $mode = [string]$obj.mode
        $reason = [string]$obj.reason
        $icon = switch ($decision) {
            "block" { "[BLOCK]" }
            "allow" { "[OK]   " }
            "explain" { "[INFO] " }
            default { "       " }
        }
        return ("  {0,-9}  {1}  {2,-7}  {3,-12}  {4}" -f $short, $icon, $decision, $mode, $reason)
    } catch {
        return $null
    }
}

try {
    [Console]::CursorVisible = $false
    while ($true) {
        $today = Get-Date -Format "yyyy-MM-dd"
        $eventsPath = Join-Path $logDir ("events-" + $today + ".jsonl")
        try { Clear-Host } catch { }
        Write-Host "+================================================================+"
        Write-Host "|  agent-monitor — AI の動きを横で見る   (Ctrl+C で終了)         |"
        Write-Host "+================================================================+"
        if (Test-Path -LiteralPath $nowPath) {
            Get-Content -LiteralPath $nowPath -Encoding UTF8 | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host ""
            Write-Host "  (まだ承認待ちのアクションはありません。AI が tool を呼ぶとここに出ます)"
        }
        Write-Host ""
        Write-Host ("--------------  直近の出来事 (events-" + $today + ".jsonl)  --------------")
        if (Test-Path -LiteralPath $eventsPath) {
            Get-Content -LiteralPath $eventsPath -Encoding UTF8 -Tail $TailN | ForEach-Object {
                $line = Format-Event $_
                if ($line) { Write-Host $line }
            }
        } else {
            Write-Host "  (本日の監査ログはまだ作成されていません)"
        }
        Start-Sleep -Seconds $IntervalSec
    }
} finally {
    [Console]::CursorVisible = $true
}
