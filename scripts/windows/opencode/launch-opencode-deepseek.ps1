param(
    [string]$Workspace = "$env:USERPROFILE\Documents\my-ai-workspace",
    [switch]$WebSearch
)

$ErrorActionPreference = 'Stop'
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$hooks = Join-Path $Workspace '.ai-safety\hooks'
$gatewayJs = Join-Path $hooks 'common\ds-gateway.js'
$configJs = Join-Path $hooks 'common\opencode-config.js'
$monitorPlugin = Join-Path $hooks 'common\opencode-bouncer-monitor.mjs'
$port = if ($env:DS_GATEWAY_PORT) { $env:DS_GATEWAY_PORT } else { '8788' }
$keyDir = Join-Path $env:USERPROFILE '.deepseek-claude'
$keyFile = Join-Path $keyDir 'auth'
$logDir = if ($env:AI_SAFE_LOG_DIR) { $env:AI_SAFE_LOG_DIR } else { Join-Path $env:USERPROFILE '.ai-safety\logs' }
$coachMarker = Join-Path $logDir 'coach-engine'

if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw "作業フォルダが見つかりません: $Workspace" }
if (-not (Test-Path -LiteralPath $gatewayJs -PathType Leaf)) { throw "送信検査 Gateway が見つかりません: $gatewayJs" }
if (-not (Test-Path -LiteralPath $configJs -PathType Leaf)) { throw "OpenCode 安全設定が見つかりません: $configJs" }
if (-not (Test-Path -LiteralPath $monitorPlugin -PathType Leaf)) { throw "OpenCode承認モニターが見つかりません: $monitorPlugin" }

if ($env:AI_SAFE_DRY_RUN -eq '1') {
    Write-Output 'OpenCode + DeepSeek dry-run'
    Write-Output "  workspace: $Workspace"
    Write-Output "  gateway:   http://127.0.0.1:$port/v1 (mandatory)"
    Write-Output '  config:    OPENCODE_CONFIG_CONTENT'
    Write-Output '  model:     DeepSeek V4 Pro / small: V4 Flash'
    Write-Output ('  websearch: ' + $(if ($WebSearch) { 'opt-in (approval required)' } else { 'off' }))
    exit 0
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw 'Node.js が見つかりません。' }
$openCode = if ($env:OPENCODE_BIN) { $env:OPENCODE_BIN } else {
    $found = Get-Command opencode -ErrorAction SilentlyContinue
    if ($found) { $found.Source } else { $null }
}
if (-not $openCode) { throw 'OpenCode が見つかりません。先に OpenCode をインストールしてください。' }
if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf) -or (Get-Item -LiteralPath $keyFile).Length -eq 0) {
    throw 'DeepSeek APIキーが未登録です。先に「DeepSeekキーを登録」を実行してください。'
}

$version = (& $openCode --version 2>$null | Select-Object -First 1).Trim()
& $node.Source -e 'const m=require(process.argv[1]);process.exit(m.isSupportedVersion(process.argv[2])?0:1)' $configJs $version
if ($LASTEXITCODE -ne 0) { throw "OpenCode 1.14.24 以上が必要です（検出: $version）。" }

function Stop-StaleGateway {
    param([string]$Port, [string]$GatewayJs)
    $gatewayPath = (Resolve-Path -LiteralPath $GatewayJs).Path.Replace('/', '\').ToLowerInvariant()
    try {
        $listeners = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort ([int]$Port) -State Listen -ErrorAction SilentlyContinue
    } catch { $listeners = @() }
    foreach ($listener in @($listeners)) {
        try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" -ErrorAction Stop } catch { continue }
        $cmd = ([string]$proc.CommandLine).Replace('/', '\').ToLowerInvariant()
        if ($cmd.Contains($gatewayPath)) {
            Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 250
        }
    }
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Stop-StaleGateway -Port $port -GatewayJs $gatewayJs
$env:DS_GATEWAY_PORT = $port
$env:DS_GATEWAY_UPSTREAM = 'https://api.deepseek.com'
$env:DS_GATEWAY_AUTH_FILE = $keyFile
$gatewayOut = Join-Path $logDir 'opencode-deepseek-gateway.log'
$gatewayErr = Join-Path $logDir 'opencode-deepseek-gateway.err.log'
$gw = Start-Process -FilePath $node.Source -ArgumentList @($gatewayJs) -PassThru -WindowStyle Hidden -RedirectStandardOutput $gatewayOut -RedirectStandardError $gatewayErr
Remove-Item Env:\DS_GATEWAY_AUTH_FILE, Env:\DS_GATEWAY_UPSTREAM -ErrorAction SilentlyContinue

try {
    $ready = $false
    for ($i = 0; $i -lt 50; $i++) {
        try {
            $health = Invoke-WebRequest -Uri "http://127.0.0.1:$port/healthz" -UseBasicParsing -TimeoutSec 1
            if ($health.Content -match '"status":"ok"') { $ready = $true; break }
        } catch { Start-Sleep -Milliseconds 100 }
        if ($gw.HasExited) { break }
    }
    if (-not $ready -or $gw.HasExited) {
        throw "送信検査 Gateway を確認できないため、OpenCode は起動しません（fail-closed）。確認先: $gatewayErr"
    }

    # プロジェクト固有の設定は無効化し、隔離した設定ディレクトリからBouncerプラグインだけを読む。
    $env:OPENCODE_DISABLE_PROJECT_CONFIG = '1'
    Remove-Item Env:\OPENCODE_PURE -ErrorAction SilentlyContinue
    $env:XDG_CONFIG_HOME = Join-Path $Workspace '.ai-safety\opencode-runtime\xdg-config'
    $env:AI_SAFE_LOG_DIR = $logDir
    New-Item -ItemType Directory -Force -Path $env:XDG_CONFIG_HOME | Out-Null
    $configArgs = @($configJs, '--port', $port, '--monitor-plugin', $monitorPlugin)
    if ($WebSearch) {
        $env:OPENCODE_ENABLE_EXA = '1'
        $configArgs += '--websearch'
        Write-Host 'Web検索を有効にしました。検索語は外部サービスへ送信され、実行前に確認が出ます。'
    } else {
        Remove-Item Env:\OPENCODE_ENABLE_EXA -ErrorAction SilentlyContinue
    }
    $env:OPENCODE_CONFIG_CONTENT = (& $node.Source @configArgs)
    if ($LASTEXITCODE -ne 0 -or -not $env:OPENCODE_CONFIG_CONTENT) { throw 'OpenCode 安全設定を生成できませんでした。' }

    Remove-Item Env:\DEEPSEEK_API_KEY, Env:\DEEPSEEK_API_TOKEN, Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
    Set-Content -NoNewline -Encoding ascii -LiteralPath $coachMarker -Value 'opencode-deepseek'
    Write-Host 'Bouncer送信検査: 有効 / モデル: DeepSeek V4 Pro / 補助: V4 Flash'
    Write-Host ('変更操作は確認、外部フォルダは禁止、Web検索は' + $(if ($WebSearch) { '許可時のみ' } else { '無効' }) + 'です。')

    Push-Location $Workspace
    try { & $openCode } finally { Pop-Location }
    exit $LASTEXITCODE
} finally {
    if ($gw -and -not $gw.HasExited) { Stop-Process -Id $gw.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $coachMarker -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\OPENCODE_CONFIG_CONTENT, Env:\OPENCODE_ENABLE_EXA, Env:\OPENCODE_DISABLE_PROJECT_CONFIG, Env:\OPENCODE_PURE, Env:\XDG_CONFIG_HOME -ErrorAction SilentlyContinue
}
