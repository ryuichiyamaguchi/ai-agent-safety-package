param(
    [string]$Workspace = "$env:USERPROFILE\Documents\my-ai-workspace",
    [ValidateSet('codex','claude','opencode','d-claude')]
    [string]$Agent = 'codex',
    [ValidateSet('standard','assisted','maximum')]
    # $PROFILE は PowerShell の自動変数なので、変数名は $SafetyProfile にする。
    # 既存の呼び出し元 (スタート/*.bat, docs) は -Profile のまま使えるように別名を残す。
    [Alias('Profile')]
    [string]$SafetyProfile = 'standard',
    [switch]$WebSearch,
    # OpenCode のみ。前回のセッションを開き直す。
    [switch]$Resume,
    # OpenCode のみ。作業フォルダ (ワークスペース内のプロジェクトフォルダ)。
    [string]$Project = ""
)

$ErrorActionPreference = 'Stop'
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$root = Join-Path $Workspace '.ai-safety'
$hooks = Join-Path $root 'hooks\windows'
$logDir = if ($env:AI_SAFE_LOG_DIR) { $env:AI_SAFE_LOG_DIR } else { Join-Path $env:USERPROFILE '.ai-safety\logs' }

if ($Agent -eq 'codex' -and $SafetyProfile -ne 'standard') { throw 'Codex は standard モードで起動してください。' }
if ($Agent -eq 'opencode' -and $SafetyProfile -ne 'standard') { throw 'OpenCode は standard モードで起動してください。' }
if ($Agent -eq 'd-claude' -and $SafetyProfile -ne 'standard') { throw 'd-claude は standard モードで起動してください。' }
if ($WebSearch -and $Agent -ne 'opencode') { throw '-WebSearch は OpenCode だけで指定できます。' }
if ($Resume -and $Agent -ne 'opencode') { throw '-Resume は OpenCode だけで指定できます。' }
if ($Project -and $Agent -ne 'opencode') { throw '-Project は OpenCode だけで指定できます。' }
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw "作業フォルダが見つかりません: $Workspace" }

# どのボタン(スタート等)から呼ばれても、AI は必ず作業フォルダを起点に起動する。
# Claude Code は起動時の cwd を CLAUDE_PROJECT_DIR とし、配布 settings のフックを
# $env:CLAUDE_PROJECT_DIR\.ai-safety\... から解決するため、cwd が workspace の外だと
# ガード欠落(fail-closed)で全プロンプトがブロックされる。
Set-Location -LiteralPath $Workspace

if ($env:AI_SAFE_DRY_RUN -eq '1') {
    if ($SafetyProfile -eq 'maximum' -and -not (Test-Path -LiteralPath (Join-Path $root 'bouncer\scripts\run-local.ps1'))) {
        throw "ローカルBouncer Gatewayが見つかりません: $(Join-Path $root 'bouncer')"
    }
    Write-Output 'Bouncer統合版 dry-run'
    Write-Output "  workspace: $Workspace"
    Write-Output "  agent:     $Agent"
    Write-Output "  profile:   $SafetyProfile"
    Write-Output '  monitor:   enabled'
    if ($Agent -eq 'opencode') {
        Write-Output ('  session:   ' + $(if ($Resume) { 'continue last' } else { 'new' }))
        if ($Project) { Write-Output "  project:   $Project" }
    }
    if ($SafetyProfile -eq 'maximum') {
        Write-Output '  gateway:   http://127.0.0.1:8787 (local only)'
    } elseif ($Agent -eq 'opencode' -or $Agent -eq 'd-claude') {
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
    $env:AI_SAFE_PROFILE = $SafetyProfile
    $env:AI_SAFE_AGENT = $Agent
    $monitorOut = Join-Path $logDir 'integrated-monitor.log'
    $monitorErr = Join-Path $logDir 'integrated-monitor.err.log'
    $monitorProc = Start-Process -FilePath $powerShell.Source `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$monitorScript`"") `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $monitorOut -RedirectStandardError $monitorErr

    if ($SafetyProfile -eq 'maximum') {
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
    switch ("${Agent}:${SafetyProfile}") {
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
            & (Join-Path $hooks 'opencode\launch-opencode-deepseek.ps1') -Workspace $Workspace -WebSearch:$WebSearch -Resume:$Resume -Project $Project
            $exitCode = $LASTEXITCODE
        }
        'd-claude:standard' {
            $consent = Join-Path $hooks 'launch-deepseek-safe.ps1'
            $authFile = Join-Path $env:USERPROFILE '.deepseek-claude\auth'
            $deepseekGateway = Join-Path $hooks 'deepseek\launch-deepseek-gateway.ps1'
            if (-not (Test-Path -LiteralPath $consent -PathType Leaf)) {
                throw "DeepSeek同意ゲートが見つかりません: $consent"
            }
            if (-not (Test-Path -LiteralPath $deepseekGateway -PathType Leaf)) {
                throw "DeepSeek送信検査Gatewayが見つかりません: $deepseekGateway"
            }
            if (-not (Test-Path -LiteralPath $authFile -PathType Leaf)) {
                throw 'DeepSeek APIキーが未登録です。スタート\（上級）1_DeepSeekキーを登録 を先に実行してください。'
            }
            & $powerShell.Source -NoProfile -ExecutionPolicy Bypass -File $consent -ConsentOnly
            if ($LASTEXITCODE -ne 0) { throw 'DeepSeekへの送信をキャンセルしました。' }
            $deepseekKey = ([System.IO.File]::ReadAllText($authFile)).Trim()
            if (-not $deepseekKey) { throw 'DeepSeek APIキーの登録ファイルが空です。登録し直してください。' }
            $env:ANTHROPIC_AUTH_TOKEN = $deepseekKey
            $env:ANTHROPIC_MODEL = 'deepseek-v4-flash[1m]'
            $env:ANTHROPIC_DEFAULT_OPUS_MODEL = 'deepseek-v4-flash[1m]'
            $env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'deepseek-v4-flash[1m]'
            $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = 'deepseek-v4-flash'
            $env:CLAUDE_CODE_SUBAGENT_MODEL = 'deepseek-v4-flash'
            $env:CLAUDE_CODE_EFFORT_LEVEL = 'max'
            & $powerShell.Source -NoProfile -ExecutionPolicy Bypass -File $deepseekGateway -Workspace $Workspace
            $exitCode = $LASTEXITCODE
        }
    }
    exit $exitCode
} finally {
    if ($gatewayProc -and -not $gatewayProc.HasExited) { Stop-Process -Id $gatewayProc.Id -Force -ErrorAction SilentlyContinue }
    if ($monitorProc -and -not $monitorProc.HasExited) { Stop-Process -Id $monitorProc.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:\BOUNCER_INTEGRATED_MODE, Env:\ANTHROPIC_BASE_URL, Env:\ANTHROPIC_AUTH_TOKEN, Env:\ANTHROPIC_MODEL, Env:\ANTHROPIC_DEFAULT_OPUS_MODEL, Env:\ANTHROPIC_DEFAULT_SONNET_MODEL, Env:\ANTHROPIC_DEFAULT_HAIKU_MODEL, Env:\CLAUDE_CODE_SUBAGENT_MODEL, Env:\CLAUDE_CODE_EFFORT_LEVEL, Env:\DS_CLAUDE_MODE -ErrorAction SilentlyContinue
}
