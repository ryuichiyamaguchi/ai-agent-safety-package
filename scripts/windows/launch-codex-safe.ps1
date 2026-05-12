param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = ""
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$env:AI_SAFE_ROOT = Join-Path $Workspace ".ai-safety"
$env:AI_SAFE_POLICY = Join-Path $env:AI_SAFE_ROOT "policy\safety-policy.json"
$env:AI_SAFE_LOG_DIR = Join-Path $HOME ".ai-safety\logs"

if (-not (Test-Path -LiteralPath $env:AI_SAFE_POLICY)) {
    throw "AI Safety package is not installed in workspace: $Workspace"
}

$argsList = @(
    "--cd", $Workspace,
    "--profile", "safe",
    "--sandbox", "workspace-write",
    "--ask-for-approval", "never",
    "--enable", "hooks",
    "-c", "windows.sandbox=`"unelevated`""
)

if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & codex @argsList $Prompt
} else {
    & codex @argsList
}
exit $LASTEXITCODE
