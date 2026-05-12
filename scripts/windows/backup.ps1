param(
    [string]$Workspace = (Get-Location).Path,
    [string]$OutDir = (Join-Path $HOME ".ai-safety\backups")
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$zip = Join-Path $OutDir ("ai-safety-backup-" + $stamp + ".zip")
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$targets = @(".ai-safety", ".claude", ".codex", ".gemini", ".aiexclude") | ForEach-Object { Join-Path $Workspace $_ } | Where-Object { Test-Path -LiteralPath $_ }
Compress-Archive -LiteralPath $targets -DestinationPath $zip -Force
Write-Host $zip
