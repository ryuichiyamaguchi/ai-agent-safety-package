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

# Bridge user's existing Codex auth into the safe CODEX_HOME so learners do not need to re-login.
$srcAuth = Join-Path $HOME ".codex\auth.json"
$dstAuth = Join-Path $env:CODEX_HOME "auth.json"
if ((Test-Path -LiteralPath $srcAuth) -and (-not (Test-Path -LiteralPath $dstAuth))) {
    Copy-Item -Path $srcAuth -Destination $dstAuth -Force
}

$argsList = @(
    "--cd", $Workspace,
    "--profile", "safe",
    "--sandbox", "workspace-write",
    "--ask-for-approval", "untrusted",
    "--enable", "hooks",
    "-c", "windows.sandbox=`"unelevated`""
)

if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & codex @argsList $Prompt
} else {
    & codex @argsList
}
exit $LASTEXITCODE
