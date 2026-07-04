# install-statusline.ps1 -- register the lightweight status line (statusline.mjs) into the
# user's global Claude settings (%USERPROFILE%\.claude\settings.json). Works for both
# claude and d-claude. ASCII-only source on purpose so PS 5.1 (CP932) never mis-parses it;
# Japanese wording for the user is printed by the button (.bat) and by node.
# Location: <workspace>\.ai-safety\hooks\windows\install-statusline.ps1
param([string]$Mode = "install")
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$js = Join-Path $here "..\common\install-statusline.js"
$scriptPath = Join-Path $here "..\common\statusline.mjs"
$target = if ($env:AI_SAFE_GLOBAL_CLAUDE) { $env:AI_SAFE_GLOBAL_CLAUDE } else { Join-Path $HOME ".claude\settings.json" }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error "node not found. Please install Node.js first (run 0_ installer)."
    exit 2
}
if (-not (Test-Path -LiteralPath $js) -or -not (Test-Path -LiteralPath $scriptPath)) {
    Write-Error "script not found (run 1_ install first): $js"
    exit 2
}

if ($Mode -eq "uninstall") {
    node $js uninstall --target $target
} else {
    node $js install --target $target --script $scriptPath --os windows
}
exit $LASTEXITCODE
