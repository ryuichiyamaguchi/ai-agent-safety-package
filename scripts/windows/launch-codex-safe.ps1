param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = ""
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$env:AI_SAFE_ROOT = Join-Path $Workspace ".ai-safety"
$env:AI_SAFE_POLICY = Join-Path $env:AI_SAFE_ROOT "policy\safety-policy.json"
$env:AI_SAFE_LOG_DIR = Join-Path $HOME ".ai-safety\logs"
$env:CODEX_HOME = Join-Path $Workspace ".codex"

if (-not (Test-Path -LiteralPath $env:AI_SAFE_POLICY)) {
    throw "AI Safety package is not installed in workspace: $Workspace"
}
if (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_HOME "config.toml"))) {
    throw "Codex safety config was not found: $env:CODEX_HOME\config.toml"
}

# Bridge user's existing Codex auth into the safe CODEX_HOME via a directory Junction
# (NOT a physical copy). This avoids leaking auth.json into the workspace tree where
# `git add -f`, OneDrive sync, or zip-bundling could inadvertently exfiltrate it.
$srcAuth = Join-Path $HOME ".codex\auth.json"
$userCodexDir = Join-Path $HOME ".codex"
$workspaceCodexAuth = Join-Path $env:CODEX_HOME "auth.json"

if (-not (Test-Path -LiteralPath $srcAuth)) {
    throw "Codex auth not found at $srcAuth. Please run 'codex login' first."
}

# If a legacy physical auth.json copy exists (from earlier versions of this launcher),
# remove it before establishing the junction so we do not leave a real token on disk.
if (Test-Path -LiteralPath $workspaceCodexAuth) {
    $authItem = Get-Item -LiteralPath $workspaceCodexAuth -Force
    $isReparse = $false
    if ($authItem.PSObject.Properties.Name -contains 'LinkType') {
        $isReparse = [bool]$authItem.LinkType
    }
    if (-not $isReparse) {
        Write-Warning "Removing legacy physical auth.json copy at $workspaceCodexAuth"
        Remove-Item -LiteralPath $workspaceCodexAuth -Force
    }
}

# Create a per-file Junction is not supported; junctions are directory-only. We instead
# expose auth.json via a Junction on the parent .codex folder's auth subpath using a
# symbolic-link-equivalent: New-Item -ItemType SymbolicLink for the single file. This
# requires either Developer Mode or admin on older Windows builds; fall back to ACL-
# locked copy when symlink creation fails.
if (-not (Test-Path -LiteralPath $workspaceCodexAuth)) {
    $linkCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $workspaceCodexAuth -Target $srcAuth -ErrorAction Stop | Out-Null
        $linkCreated = $true
    } catch {
        Write-Warning "SymbolicLink creation failed ($($_.Exception.Message)). Falling back to ACL-locked copy."
    }
    if (-not $linkCreated) {
        Copy-Item -LiteralPath $srcAuth -Destination $workspaceCodexAuth -Force
        try {
            $acl = Get-Acl -LiteralPath $workspaceCodexAuth
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
                "Read,Write",
                "Allow"
            )
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $workspaceCodexAuth -AclObject $acl
            (Get-Item -LiteralPath $workspaceCodexAuth -Force).Attributes = 'Hidden'
        } catch {
            Write-Warning "Failed to harden ACL on fallback auth.json copy: $($_.Exception.Message)"
        }
    }
}

$argsList = @(
    "--cd", $Workspace,
    "--profile", "safe",
    "--sandbox", "workspace-write",
    "--ask-for-approval", "untrusted",
    "-c", "windows.sandbox=`"unelevated`""
)

if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & codex @argsList $Prompt
} else {
    & codex @argsList
}
exit $LASTEXITCODE
