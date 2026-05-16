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

# H6: verify distribution integrity against docs\tested_versions.md hash table.
# Mismatch warns and asks for confirmation. Set AI_SAFETY_STRICT=1 to hard-fail in non-interactive runs.
function Test-DistributionHash([string]$RelPath) {
    $absPath = Join-Path $packageRoot ($RelPath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $absPath)) { return }
    $versionsFile = Join-Path $packageRoot "docs\tested_versions.md"
    if (-not (Test-Path -LiteralPath $versionsFile)) { return }
    $expected = $null
    foreach ($line in Get-Content -LiteralPath $versionsFile) {
        if ($line -match ("^\|\s*" + [regex]::Escape($RelPath) + "\s*\|\s*([0-9a-fA-F]{64})\s*\|")) {
            $expected = $Matches[1].ToLower()
            break
        }
    }
    if (-not $expected) { return }
    $actual = (Get-FileHash -LiteralPath $absPath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        Write-Warning ("SHA-256 mismatch for " + $RelPath)
        Write-Warning ("  expected: " + $expected)
        Write-Warning ("  actual:   " + $actual)
        if ([Environment]::UserInteractive -and $Host.UI.RawUI) {
            $yn = Read-Host "Continue anyway? [y/N]"
            if ($yn -notmatch '^[yY]') { throw "Aborted by user due to hash mismatch." }
        } else {
            Write-Warning "Non-interactive shell: continuing with mismatch (set AI_SAFETY_STRICT=1 to abort)."
            if ($env:AI_SAFETY_STRICT -eq '1') { throw "Hash mismatch with AI_SAFETY_STRICT=1." }
        }
    }
}

Test-DistributionHash "policy/safety-policy.json"
switch ($Platform) {
    'mac' {
        Test-DistributionHash "configs/codex/hooks.mac.json"
        Test-DistributionHash "configs/claude/settings.mac.json"
        Test-DistributionHash "configs/gemini/settings.mac.json"
        Test-DistributionHash "configs/codex/config.mac.toml"
    }
    'win' {
        Test-DistributionHash "configs/codex/hooks.windows.json"
        Test-DistributionHash "configs/claude/settings.windows.json"
        Test-DistributionHash "configs/gemini/settings.windows.json"
        Test-DistributionHash "configs/codex/config.windows.toml"
    }
    'both' {
        Test-DistributionHash "configs/codex/hooks.mac.json"
        Test-DistributionHash "configs/codex/hooks.windows.json"
        Test-DistributionHash "configs/claude/settings.mac.json"
        Test-DistributionHash "configs/claude/settings.windows.json"
        Test-DistributionHash "configs/gemini/settings.mac.json"
        Test-DistributionHash "configs/gemini/settings.windows.json"
        Test-DistributionHash "configs/codex/config.mac.toml"
        Test-DistributionHash "configs/codex/config.windows.toml"
    }
}
Test-DistributionHash "configs/gemini/policies/safety.toml"
Test-DistributionHash "workspace-template/aiexclude.template"

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
    $globalSrc = Join-Path $packageRoot "configs\claude\settings.windows.json"
    $globalTarget = Join-Path $HOME ".claude\settings.json"
    # M16: 既存の global Claude 設定は他プロジェクトでも使われている可能性が高い。
    # バックアップは取るが、上書き前に必ず diff を見せて y/n 確認する。
    if (Test-Path -LiteralPath $globalTarget) {
        $srcHash = (Get-FileHash -LiteralPath $globalSrc -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash -LiteralPath $globalTarget -Algorithm SHA256).Hash
        if ($srcHash -eq $dstHash) {
            Write-Host "Global Claude settings.json already matches package version; skipping."
        } else {
            Write-Host ("Existing global Claude settings found: " + $globalTarget)
            Write-Host "----- diff (current -> package) -----"
            $diff = Compare-Object `
                -ReferenceObject (Get-Content -LiteralPath $globalTarget) `
                -DifferenceObject (Get-Content -LiteralPath $globalSrc)
            if ($diff) { $diff | Format-Table -AutoSize | Out-Host }
            Write-Host "-------------------------------------"
            $canPrompt = [Environment]::UserInteractive -and $Host.UI -and $Host.UI.RawUI
            if ($canPrompt) {
                $yn = Read-Host "Overwrite global ~/.claude/settings.json? [y/N]"
                if ($yn -match '^[yY]$') {
                    Copy-WithBackup $globalSrc $globalTarget
                } else {
                    Write-Host "Skipped global Claude settings install."
                }
            } else {
                Write-Warning "Non-interactive shell: skipped global Claude settings install (set AI_SAFETY_STRICT=1 to force overwrite)."
                if ($env:AI_SAFETY_STRICT -eq '1') {
                    Copy-WithBackup $globalSrc $globalTarget
                }
            }
        }
    } else {
        Copy-WithBackup $globalSrc $globalTarget
    }
}

Write-Host "AI Safety package installed."
Write-Host ("Workspace: " + $Workspace)
Write-Host ("Backups: " + $backupDir)
Write-Host "Next: powershell -ExecutionPolicy Bypass -File .ai-safety\hooks\windows\doctor.ps1"
