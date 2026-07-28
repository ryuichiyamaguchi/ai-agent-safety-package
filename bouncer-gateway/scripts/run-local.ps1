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

# lms の出力から状態を判定するヘルパー。
#
# 以前はサーバー稼働判定を `-notmatch 'server is running|running'` で行っていたが、
# サーバーが落ちているときの応答 "The server is not running" にも 'running' が
# 含まれるため、落ちていても「起動済み」とみなして起動をスキップしていた
# (fail-open)。行頭からの定型文で肯定と否定を別々に判定し、どちらとも読めない
# ときは憶測で進めずに中止する (安全側)。mac 版 run-local.zsh と同じ考え方。
function Get-LmsServerState {
    param([string]$StatusText)
    foreach ($line in ($StatusText -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^The server is not running') { return 'stopped' }
        if ($trimmed -match '^The server is running')     { return 'running' }
    }
    return 'unknown'
}

# lms を呼び、終了コードや stderr で例外になった場合でも本文を取り出す。
# 状態判定は終了コードではなく本文で行うため、ここでは失敗を握りつぶしてよい。
function Invoke-LmsText {
    param([string[]]$LmsArgs)
    try {
        return (& $lms.Source @LmsArgs 2>&1 | Out-String)
    } catch {
        return ($_ | Out-String)
    }
}

try {
    $serverStatus = Invoke-LmsText @('server', 'status')
    $serverState = Get-LmsServerState $serverStatus
    if ($serverState -eq 'unknown') {
        throw "LM Studio server の状態を判定できませんでした。安全のため起動を中止します。lms server status の出力: $($serverStatus.Trim())"
    }
    if ($serverState -eq 'stopped') {
        & $lms.Source server start --port 1234 --bind 127.0.0.1
        if ($LASTEXITCODE -ne 0) { throw 'LM Studio server を起動できませんでした。' }
        $startedServer = $true
    }

    # lms ps は読み込み済みモデルの一覧を出す。一覧を取れていないのに
    # 「bouncer-gemma が無い」と解釈すると、読込済みのモデルを二重に読もうとして
    # 失敗するため、出力が空なら判定不能として中止する (安全側)。
    $modelStatus = Invoke-LmsText @('ps')
    if ([string]::IsNullOrWhiteSpace($modelStatus)) {
        throw 'LM Studio の読み込み済みモデルを確認できませんでした。安全のため起動を中止します。'
    }
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
