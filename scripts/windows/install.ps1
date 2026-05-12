param(
    [string]$Workspace = (Get-Location).Path,
    [switch]$InstallGlobalClaudeSettings
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$packageRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$homeSafety = Join-Path $HOME ".ai-safety"
$backupDir = Join-Path $homeSafety ("backups\" + (Get-Date -Format "yyyyMMdd-HHmmss"))

function Copy-WithBackup([string]$Source, [string]$Dest) {
    $destDir = Split-Path -Parent $Dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    if (Test-Path -LiteralPath $Dest) {
        $relativeName = ($Dest -replace "[:\\\/]+", "_")
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        Copy-Item -LiteralPath $Dest -Destination (Join-Path $backupDir $relativeName) -Force
    }
    Copy-Item -LiteralPath $Source -Destination $Dest -Force
}

New-Item -ItemType Directory -Force -Path $homeSafety | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Workspace ".ai-safety\hooks") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Workspace ".ai-safety\policy") | Out-Null

Copy-Item -LiteralPath (Join-Path $packageRoot "policy\safety-policy.json") -Destination (Join-Path $Workspace ".ai-safety\policy\safety-policy.json") -Force
Copy-Item -LiteralPath (Join-Path $packageRoot "scripts\windows") -Destination (Join-Path $Workspace ".ai-safety\hooks") -Recurse -Force
Copy-Item -LiteralPath (Join-Path $packageRoot "scripts\macos") -Destination (Join-Path $Workspace ".ai-safety\hooks") -Recurse -Force

Copy-WithBackup (Join-Path $packageRoot "configs\claude\settings.windows.json") (Join-Path $Workspace ".claude\settings.json")
Copy-WithBackup (Join-Path $packageRoot "configs\codex\config.windows.toml") (Join-Path $Workspace ".codex\config.toml")
Copy-WithBackup (Join-Path $packageRoot "configs\codex\hooks.windows.json") (Join-Path $Workspace ".codex\hooks.json")
Copy-WithBackup (Join-Path $packageRoot "configs\gemini\settings.windows.json") (Join-Path $Workspace ".gemini\settings.json")
Copy-WithBackup (Join-Path $packageRoot "configs\gemini\policies\safety.toml") (Join-Path $Workspace ".gemini\policies\safety.toml")
Copy-WithBackup (Join-Path $packageRoot "workspace-template\aiexclude.template") (Join-Path $Workspace ".aiexclude")

if ($InstallGlobalClaudeSettings) {
    Copy-WithBackup (Join-Path $packageRoot "configs\claude\settings.windows.json") (Join-Path $HOME ".claude\settings.json")
}

Write-Host "AI Safety package installed."
Write-Host ("Workspace: " + $Workspace)
Write-Host ("Backups: " + $backupDir)
Write-Host "Next: powershell -ExecutionPolicy Bypass -File .ai-safety\hooks\windows\doctor.ps1"
