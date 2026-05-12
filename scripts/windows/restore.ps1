param(
    [Parameter(Mandatory=$true)]
    [string]$BackupZip,
    [string]$Workspace = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
if (-not (Test-Path -LiteralPath $BackupZip)) { throw "Backup not found: $BackupZip" }
Expand-Archive -LiteralPath $BackupZip -DestinationPath $Workspace -Force
Write-Host ("Restored to " + $Workspace)
