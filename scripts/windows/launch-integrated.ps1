param(
    [string]$Workspace = "$env:USERPROFILE\Documents\my-ai-workspace",
    [ValidateSet('codex','claude','opencode','d-claude')]
    [string]$Agent = 'codex',
    [ValidateSet('standard','assisted')]
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
    Write-Output '安全装置（Bouncer）dry-run'
    Write-Output "  workspace: $Workspace"
    Write-Output "  agent:     $Agent"
    Write-Output "  profile:   $SafetyProfile"
    Write-Output '  monitor:   enabled'
    if ($Agent -eq 'opencode') {
        Write-Output ('  session:   ' + $(if ($Resume) { 'continue last' } else { 'new' }))
        if ($Project) { Write-Output "  project:   $Project" }
    }
    if ($Agent -eq 'opencode' -or $Agent -eq 'd-claude') {
        Write-Output '  gateway:   http://127.0.0.1:8788 (send inspection, no local LLM)'
    } else {
        Write-Output '  gateway:   bypassed (AIの応答速度を優先)'
    }
    exit 0
}

$monitorScript = Join-Path $hooks 'open-monitor.ps1'
if (-not (Test-Path -LiteralPath $monitorScript -PathType Leaf)) {
    throw '安全装置（Bouncer）がこの作業フォルダに導入されていません。先に統合版のインストーラーを実行してください。'
}

$powerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
if (-not $powerShell) { $powerShell = Get-Command pwsh -ErrorAction SilentlyContinue }
if (-not $powerShell) { throw 'PowerShell が見つかりません。' }

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$monitorProc = $null

try {
    $env:AI_SAFE_PROFILE = $SafetyProfile
    $env:AI_SAFE_AGENT = $Agent
    $monitorOut = Join-Path $logDir 'integrated-monitor.log'
    $monitorErr = Join-Path $logDir 'integrated-monitor.err.log'
    $monitorProc = Start-Process -FilePath $powerShell.Source `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$monitorScript`"") `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $monitorOut -RedirectStandardError $monitorErr

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
        'opencode:standard' {
            & (Join-Path $hooks 'opencode\launch-opencode-deepseek.ps1') -Workspace $Workspace -WebSearch:$WebSearch -Resume:$Resume -Project $Project
            $exitCode = $LASTEXITCODE
        }
        'd-claude:standard' {
            $consent = Join-Path $hooks 'launch-deepseek-safe.ps1'
            $deepseekGateway = Join-Path $hooks 'deepseek\launch-deepseek-gateway.ps1'
            $secretStore = Join-Path $root 'hooks\common\secret-store.js'
            if (-not (Test-Path -LiteralPath $consent -PathType Leaf)) {
                throw "DeepSeek同意ゲートが見つかりません: $consent"
            }
            if (-not (Test-Path -LiteralPath $deepseekGateway -PathType Leaf)) {
                throw "DeepSeek送信検査Gatewayが見つかりません: $deepseekGateway"
            }
            # 鍵の有無は「環境変数 → OS の金庫(DPAPI) → 旧平文」の解決結果で判定する。
            # 金庫化 (secret-migrate.js) で旧平文 .deepseek-claude\auth は削除されるので、
            # 平文ファイルの実在を条件にすると金庫に鍵があっても起動できなくなる。
            # 順序の SSOT は scripts\common\secret-store.js の resolve()。ここはそれを呼ぶだけ。
            # node や secret-store.js が無い環境では判定を保留し、gateway 側の同じ 3 段解決に任せる。
            $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
            if ($nodeCmd -and (Test-Path -LiteralPath $secretStore -PathType Leaf)) {
                $hasKey = (& $nodeCmd.Source $secretStore '--has' 'deepseek' 2>$null | Out-String).Trim()
                if ($hasKey -ne 'yes') {
                    throw 'DeepSeek APIキーが未登録です。スタート\（上級）1_DeepSeekキーを登録 を先に実行してください。'
                }
            }
            & $powerShell.Source -NoProfile -ExecutionPolicy Bypass -File $consent -ConsentOnly
            if ($LASTEXITCODE -ne 0) { throw 'DeepSeekへの送信をキャンセルしました。' }
            # 実キーはここでは読まない。Gateway 子プロセスだけが読む (Claude Code には渡さない)。
            # gateway は同じ 3 段解決で鍵を取り、ANTHROPIC_AUTH_TOKEN は起動限りの合言葉で上書きする。
            Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
            # モデル名に [1m] (1M コンテキスト指定) を付けると、Claude Code 2.1.226 以降は
            # それを名前の一部として扱い「そんなモデルは無い」で起動できなくなる (実機で再現)。
            # DeepSeek が公開しているのは deepseek-v4-flash / deepseek-v4-pro の 2 つだけ。
            # 1M コンテキストは CLAUDE_CODE_MAX_CONTEXT_TOKENS で伝える。
            $env:ANTHROPIC_MODEL = 'deepseek-v4-flash'
            $env:ANTHROPIC_DEFAULT_OPUS_MODEL = 'deepseek-v4-flash'
            $env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'deepseek-v4-flash'
            $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = '1048576'
            $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = 'deepseek-v4-flash'
            $env:CLAUDE_CODE_SUBAGENT_MODEL = 'deepseek-v4-flash'
            $env:CLAUDE_CODE_EFFORT_LEVEL = 'max'
            & $powerShell.Source -NoProfile -ExecutionPolicy Bypass -File $deepseekGateway -Workspace $Workspace
            $exitCode = $LASTEXITCODE
        }
    }
    exit $exitCode
} finally {
    if ($monitorProc -and -not $monitorProc.HasExited) { Stop-Process -Id $monitorProc.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:\ANTHROPIC_AUTH_TOKEN, Env:\ANTHROPIC_MODEL, Env:\ANTHROPIC_DEFAULT_OPUS_MODEL, Env:\ANTHROPIC_DEFAULT_SONNET_MODEL, Env:\ANTHROPIC_DEFAULT_HAIKU_MODEL, Env:\CLAUDE_CODE_SUBAGENT_MODEL, Env:\CLAUDE_CODE_EFFORT_LEVEL, Env:\DS_CLAUDE_MODE -ErrorAction SilentlyContinue
}
