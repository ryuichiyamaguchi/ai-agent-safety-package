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
# H7: emit companion .sha256 so restore.ps1 can verify integrity before extracting.
if (Test-Path -LiteralPath $zip) {
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
    Set-Content -LiteralPath ($zip + ".sha256") -Value $hash -Encoding ASCII -NoNewline
}
Write-Host $zip
