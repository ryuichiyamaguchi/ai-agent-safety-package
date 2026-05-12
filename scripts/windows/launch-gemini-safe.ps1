param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = ""
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$policy = Join-Path $Workspace ".gemini\policies\safety.toml"
$env:AI_SAFE_ROOT = Join-Path $Workspace ".ai-safety"
$env:AI_SAFE_POLICY = Join-Path $env:AI_SAFE_ROOT "policy\safety-policy.json"
$env:AI_SAFE_LOG_DIR = Join-Path $HOME ".ai-safety\logs"

if (-not (Test-Path -LiteralPath $policy)) {
    throw "Gemini safety policy was not found: $policy"
}

$argsList = @("--approval-mode", "default", "--policy", $policy, "--include-directories", $Workspace)
if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & gemini @argsList --prompt $Prompt
} else {
    & gemini @argsList
}
exit $LASTEXITCODE
