param(
    [ValidateSet('mac','win','both')]
    [string]$Platform = 'win',
    [string]$Workspace = (Get-Location).Path,
    [switch]$InstallGlobalClaudeSettings
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$packageRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$homeSafety = Join-Path $HOME ".ai-safety"
$backupDir = Join-Path $homeSafety ("backups\" + (Get-Date -Format "yyyyMMdd-HHmmss"))

Write-Host ("Installing for platform: " + $Platform)

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

if ($Platform -in 'win','both') {
    Copy-Item -LiteralPath (Join-Path $packageRoot "scripts\windows") -Destination (Join-Path $Workspace ".ai-safety\hooks") -Recurse -Force
}

if ($Platform -in 'mac','both') {
    Copy-Item -LiteralPath (Join-Path $packageRoot "scripts\macos") -Destination (Join-Path $Workspace ".ai-safety\hooks") -Recurse -Force
    # Foreign-OS hooks become read-only to shrink attack surface (H3).
    $aclPath = Join-Path $Workspace ".ai-safety\hooks\macos"
    if (Test-Path -LiteralPath $aclPath) {
        Get-ChildItem -Path $aclPath -Recurse -File | ForEach-Object {
            $acl = Get-Acl $_.FullName
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'Read',
                'Allow'
            )
            $acl.SetAccessRule($rule)
            Set-Acl -Path $_.FullName -AclObject $acl
        }
    }
}

# Defensive cleanup: remove stale foreign-OS hook dirs on single-platform install.
if ($Platform -eq 'win') {
    $staleMac = Join-Path $Workspace ".ai-safety\hooks\macos"
    if (Test-Path -LiteralPath $staleMac) { Remove-Item -LiteralPath $staleMac -Recurse -Force }
}
if ($Platform -eq 'mac') {
    $staleWin = Join-Path $Workspace ".ai-safety\hooks\windows"
    if (Test-Path -LiteralPath $staleWin) { Remove-Item -LiteralPath $staleWin -Recurse -Force }
}

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
