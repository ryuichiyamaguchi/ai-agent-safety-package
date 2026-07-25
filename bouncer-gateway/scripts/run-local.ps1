param()

$ErrorActionPreference = 'Stop'
$taskRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$startedServer = $false
$startedModel = $false

$lms = Get-Command lms -ErrorAction SilentlyContinue
if (-not $lms) {
    $candidate = Join-Path $env:USERPROFILE '.lmstudio\bin\lms.exe'
    if (Test-Path -LiteralPath $candidate) { $lms = Get-Item -LiteralPath $candidate }
}
if (-not $lms) { throw 'LM Studio CLI が見つかりません。LM Studio と lms CLI を先に準備してください。' }

$python = Get-Command python -ErrorAction SilentlyContinue
$pythonPrefix = @()
if (-not $python) {
    $python = Get-Command py -ErrorAction SilentlyContinue
    $pythonPrefix = @('-3')
}
if (-not $python) { throw 'Python 3.11 以上が見つかりません。' }

try {
    $serverStatus = (& $lms.Source server status 2>&1 | Out-String)
    if ($serverStatus -notmatch 'server is running|running') {
        & $lms.Source server start --port 1234 --bind 127.0.0.1
        if ($LASTEXITCODE -ne 0) { throw 'LM Studio server を起動できませんでした。' }
        $startedServer = $true
    }

    $modelStatus = (& $lms.Source ps 2>&1 | Out-String)
    if ($modelStatus -notmatch 'bouncer-gemma') {
        & $lms.Source load google/gemma-4-12b --context-length 4096 --parallel 1 --identifier bouncer-gemma --yes
        if ($LASTEXITCODE -ne 0) { throw 'Bouncer用 Gemma モデルを読み込めませんでした。' }
        $startedModel = $true
    }

    $env:BOUNCER_HOST = if ($env:BOUNCER_HOST) { $env:BOUNCER_HOST } else { '127.0.0.1' }
    $env:BOUNCER_PORT = if ($env:BOUNCER_PORT) { $env:BOUNCER_PORT } else { '8787' }
    $env:BOUNCER_LM_STUDIO_URL = if ($env:BOUNCER_LM_STUDIO_URL) { $env:BOUNCER_LM_STUDIO_URL } else { 'http://127.0.0.1:1234/v1' }
    $env:BOUNCER_LOCAL_MODEL = if ($env:BOUNCER_LOCAL_MODEL) { $env:BOUNCER_LOCAL_MODEL } else { 'bouncer-gemma' }
    $env:BOUNCER_AI_MODE = if ($env:BOUNCER_AI_MODE) { $env:BOUNCER_AI_MODE } else { 'balanced' }
    $env:BOUNCER_AI_FAILURE_MODE = if ($env:BOUNCER_AI_FAILURE_MODE) { $env:BOUNCER_AI_FAILURE_MODE } else { 'block' }
    $env:BOUNCER_REVIEW_MODE = if ($env:BOUNCER_REVIEW_MODE) { $env:BOUNCER_REVIEW_MODE } else { 'block' }
    $env:PYTHONPATH = Join-Path $taskRoot 'src'

    & $python.Source @pythonPrefix -m bouncer serve
    exit $LASTEXITCODE
} finally {
    if ($startedModel) { & $lms.Source unload bouncer-gemma 2>$null }
    if ($startedServer) { & $lms.Source server stop 2>$null }
}
