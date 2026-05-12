param(
    [ValidateSet("codex", "claude", "gemini")]
    [string]$Engine = "codex",
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = ""
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$root = Join-Path $Workspace ".ai-safety"
$env:AI_SAFE_ROOT = $root
$env:AI_SAFE_POLICY = Join-Path $root "policy\safety-policy.json"
$env:AI_SAFE_LOG_DIR = Join-Path $HOME ".ai-safety\logs"

if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    $guard = Join-Path $root "hooks\windows\guard-prompt.ps1"
    if (-not (Test-Path -LiteralPath $guard)) { throw "Prompt guard is missing: $guard" }
    $json = @{ hook_event_name = "GatewayPrompt"; cwd = $Workspace; prompt = $Prompt } | ConvertTo-Json -Depth 8
    $json | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guard
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

switch ($Engine) {
    "codex"  { & (Join-Path $PSScriptRoot "launch-codex-safe.ps1") -Workspace $Workspace -Prompt $Prompt; exit $LASTEXITCODE }
    "claude" { & (Join-Path $PSScriptRoot "launch-claude-safe.ps1") -Workspace $Workspace -Prompt $Prompt; exit $LASTEXITCODE }
    "gemini" { & (Join-Path $PSScriptRoot "launch-gemini-safe.ps1") -Workspace $Workspace -Prompt $Prompt; exit $LASTEXITCODE }
}
