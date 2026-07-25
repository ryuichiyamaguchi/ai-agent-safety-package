param(
    [string]$Workspace = "$env:USERPROFILE\Documents\my-ai-workspace",
    [ValidateSet('codex','claude','opencode')]
    [string]$Agent = 'codex',
    [ValidateSet('standard','assisted','maximum')]
    [string]$Profile = 'standard',
    [switch]$WebSearch
)

$ErrorActionPreference = 'Stop'
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$root = Join-Path $Workspace '.ai-safety'
$hooks = Join-Path $root 'hooks\windows'
$logDir = if ($env:AI_SAFE_LOG_DIR) { $env:AI_SAFE_LOG_DIR } else { Join-Path $env:USERPROFILE '.ai-safety\logs' }

if ($Agent -eq 'codex' -and $Profile -ne 'standard') { throw 'Codex は standard モードで起動してください。' }
if ($Agent -eq 'opencode' -and $Profile -ne 'standard') { throw 'OpenCode は standard モードで起動してください。' }
if ($WebSearch -and $Agent -ne 'opencode') { throw '-WebSearch は OpenCode だけで指定できます。' }
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw "作業フォルダが見つかりません: $Workspace" }

if ($env:AI_SAFE_DRY_RUN -eq '1') {
    if ($Profile -eq 'maximum' -and -not (Test-Path -LiteralPath (Join-Path $root 'bouncer\scripts\run-local.ps1'))) {
        throw "ローカルBouncer Gatewayが見つかりません: $(Join-Path $root 'bouncer')"
    }
    Write-Output 'Bouncer統合版 dry-run'
    Write-Output "  workspace: $Workspace"
    Write-Output "  agent:     $Agent"
    Write-Output "  profile:   $Profile"
    Write-Output '  monitor:   enabled'
    if ($Profile -eq 'maximum') {
        Write-Output '  gateway:   http://127.0.0.1:8787 (local only)'
    } elseif ($Agent -eq 'opencode') {
        Write-Output '  gateway:   http://127.0.0.1:8788 (send inspection, no local LLM)'
    } else {
        Write-Output '  gateway:   bypassed (AIの応答速度を優先)'
    }
    exit 0
}

$monitorScript = Join-Path $hooks 'open-monitor.ps1'
if (-not (Test-Path -LiteralPath $monitorScript -PathType Leaf)) {
    throw 'Bouncer統合版がこの作業フォルダに導入されていません。先に統合版のインストーラーを実行してください。'
}

$powerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
if (-not $powerShell) { $powerShell = Get-Command pwsh -ErrorAction SilentlyContinue }
if (-not $powerShell) { throw 'PowerShell が見つかりません。' }

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$monitorProc = $null
$gatewayProc = $null

try {
    $env:AI_SAFE_PROFILE = $Profile
    $env:AI_SAFE_AGENT = $Agent
    $monitorOut = Join-Path $logDir 'integrated-monitor.log'
    $monitorErr = Join-Path $logDir 'integrated-monitor.err.log'
    $monitorProc = Start-Process -FilePath $powerShell.Source `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$monitorScript`"") `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $monitorOut -RedirectStandardError $monitorErr

    if ($Profile -eq 'maximum') {
        $bouncerRunner = Join-Path $root 'bouncer\scripts\run-local.ps1'
        if (-not (Test-Path -LiteralPath $bouncerRunner -PathType Leaf)) {
            throw "ローカルBouncer Gatewayが見つかりません: $(Join-Path $root 'bouncer')"
        }
        $env:BOUNCER_REVIEW_MODE = 'block'
        $env:BOUNCER_AI_FAILURE_MODE = 'block'
        $gatewayOut = Join-Path $logDir 'bouncer-gateway.log'
        $gatewayErr = Join-Path $logDir 'bouncer-gateway.err.log'
        $gatewayProc = Start-Process -FilePath $powerShell.Source `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$bouncerRunner`"") `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $gatewayOut -RedirectStandardError $gatewayErr

        $ready = $false
        for ($i = 0; $i -lt 180; $i++) {
            try {
                $health = Invoke-WebRequest -Uri 'http://127.0.0.1:8787/bouncer/health' -UseBasicParsing -TimeoutSec 1
                if ($health.StatusCode -eq 200) { $ready = $true; break }
            } catch { Start-Sleep -Seconds 1 }
            if ($gatewayProc.HasExited) { break }
        }
        if (-not $ready -or $gatewayProc.HasExited) {
            throw "Bouncer Gatewayを起動できませんでした。確認先: $gatewayErr"
        }
    }

    $exitCode = 0
    switch ("${Agent}:${Profile}") {
        'codex:standard' {
            & (Join-Path $hooks 'launch-codex-safe.ps1') -Workspace $Workspace
            $exitCode = $LASTEXITCODE
        }
        'claude:standard' {
            & (Join-Path $hooks 'launch-claude-safe.ps1') -Workspace $Workspace
            $exitCode = $LASTEXITCODE
        }
        'claude:assisted' {
            & (Join-Path $hooks 'launch-claude-safe.ps1') -Workspace $Workspace -Assisted
            $exitCode = $LASTEXITCODE
        }
        'claude:maximum' {
            $env:BOUNCER_INTEGRATED_MODE = '1'
            $env:ANTHROPIC_BASE_URL = 'http://127.0.0.1:8787'
            & (Join-Path $hooks 'launch-claude-safe.ps1') -Workspace $Workspace
            $exitCode = $LASTEXITCODE
        }
        'opencode:standard' {
            & (Join-Path $hooks 'opencode\launch-opencode-deepseek.ps1') -Workspace $Workspace -WebSearch:$WebSearch
            $exitCode = $LASTEXITCODE
        }
    }
    exit $exitCode
} finally {
    if ($gatewayProc -and -not $gatewayProc.HasExited) { Stop-Process -Id $gatewayProc.Id -Force -ErrorAction SilentlyContinue }
    if ($monitorProc -and -not $monitorProc.HasExited) { Stop-Process -Id $monitorProc.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:\BOUNCER_INTEGRATED_MODE, Env:\ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
}
