param(
    [string]$Workspace = (Get-Location).Path,
    [string]$OutDir = (Join-Path $HOME ".ai-safety\status")
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out = Join-Path $OutDir ("status-" + $env:USERNAME + "-" + $stamp + ".txt")
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("timestamp=$(Get-Date -Format o)")
[void]$lines.Add("user=$env:USERNAME")
[void]$lines.Add("computer=$env:COMPUTERNAME")
[void]$lines.Add("workspace=$Workspace")
foreach ($cmd in @("codex", "claude", "gemini")) {
    $found = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($found) {
        try { [void]$lines.Add("$cmd=$(& $cmd --version 2>$null)") } catch { [void]$lines.Add("$cmd=error") }
    } else {
        [void]$lines.Add("$cmd=missing")
    }
}
foreach ($p in @(".ai-safety\policy\safety-policy.json", ".claude\settings.json", ".codex\config.toml", ".codex\hooks.json", ".gemini\settings.json")) {
    [void]$lines.Add("$p=" + (Test-Path -LiteralPath (Join-Path $Workspace $p)))
}
$logDir = Join-Path $HOME ".ai-safety\logs"
[void]$lines.Add("logDir=$logDir")
if (Test-Path -LiteralPath $logDir) {
    [void]$lines.Add("recentLogs=" + ((Get-ChildItem -LiteralPath $logDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object { $_.FullName }) -join ";"))
}
$lines | Set-Content -LiteralPath $out -Encoding UTF8
Write-Host $out
