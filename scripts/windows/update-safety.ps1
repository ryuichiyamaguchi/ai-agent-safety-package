param(
    [string]$Workspace = (Get-Location).Path,
    [string]$PackageRoot = ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..")))
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)

$before = Join-Path $Workspace ".ai-safety\policy\safety-policy.json"
if (Test-Path -LiteralPath $before) {
    $old = (Get-Content -LiteralPath $before -Raw -Encoding UTF8 | ConvertFrom-Json).packageVersion
} else {
    $old = "none"
}

& (Join-Path $PSScriptRoot "backup.ps1") -Workspace $Workspace | Out-Null
& (Join-Path $PSScriptRoot "install.ps1") -Workspace $Workspace | Out-Null

$after = (Get-Content -LiteralPath $before -Raw -Encoding UTF8 | ConvertFrom-Json).packageVersion
Write-Host ("Updated AI Safety package: " + $old + " -> " + $after)
& (Join-Path $PSScriptRoot "doctor.ps1") -Workspace $Workspace
