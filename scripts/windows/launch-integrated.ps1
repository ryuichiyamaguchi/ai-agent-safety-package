param(
    [string]$Workspace = "$env:USERPROFILE\Documents\my-ai-workspace",
    # menu = 課金プラン順の対話メニューを表示して、選ばれた組み合わせで起動する。
    [ValidateSet('menu','codex','claude','opencode','d-claude')]
    [string]$Agent = 'codex',
    [ValidateSet('standard','assisted')]
    # $PROFILE は PowerShell の自動変数なので、変数名は $SafetyProfile にする。
    # 既存の呼び出し元 (スタート/*.bat, docs) は -Profile のまま使えるように別名を残す。
    [Alias('Profile')]
    [string]$SafetyProfile = 'standard',
    [switch]$WebSearch,
    # OpenCode のみ。長時間おまかせモード（確認を出さない代わりに ask を deny 側へ倒す）。
    [switch]$LongRun,
    # OpenCode のみ。前回のセッションを開き直す。
    [switch]$Resume,
    # OpenCode のみ。無料モデル / 契約モデルの指定（OpenCode 側ランチャーが対応している場合だけ渡す）。
    [switch]$Free,
    [switch]$Plan,
    # OpenCode のみ。作業フォルダ (ワークスペース内のプロジェクトフォルダ)。
    [string]$Project = ""
)

$ErrorActionPreference = 'Stop'
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$root = Join-Path $Workspace '.ai-safety'
$hooks = Join-Path $root 'hooks\windows'
$logDir = if ($env:AI_SAFE_LOG_DIR) { $env:AI_SAFE_LOG_DIR } else { Join-Path $env:USERPROFILE '.ai-safety\logs' }

# --- ネイティブコマンドを「標準エラーで落ちない」形で呼ぶ ---------------------------------
# Windows PowerShell 5.1 は、ネイティブコマンド (node 等) が標準エラーへ 1 行でも出すと、
# その出力をリダイレクト (2>$null / 2>&1) やパイプで受けた時点で NativeCommandError という
# エラーレコードに変換する。$ErrorActionPreference = 'Stop' の下ではそれが終了時エラーになるので、
# 「情報メッセージが 1 行出ただけ」でランチャー全体が止まる (2>$null では抑止できない)。
# 合否の判定は必ず .ExitCode / .Output で行い、異常なら従来どおり throw すること (fail-closed)。
function Invoke-NativeQuiet {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$Arguments = @()
    )
    $prevEap = $ErrorActionPreference
    $prevErrCount = $global:Error.Count
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $raw = @(& $File @Arguments 2>&1)
        $code = $LASTEXITCODE
        $stdout = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        $stderr = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        return [pscustomobject]@{
            ExitCode = $code
            Output   = ($stdout | Out-String)
            Error    = (($stderr | ForEach-Object { [string]$_ }) -join "`n")
        }
    } finally {
        $ErrorActionPreference = $prevEap
        while ($global:Error.Count -gt $prevErrCount) { $global:Error.RemoveAt(0) }
    }
}

# --- 対話メニュー (-Agent menu のとき) ------------------------------------------------
# 並びは「どの課金プランの人か」順。スタートのボタンはここへ委譲すれば、
# mac / Windows でメニューの正本が 1 か所（このランチャー）にまとまる。
function Select-ProjectFolder {
    # OpenCode は「起動したフォルダ」が作業対象になり、動き出したあとで cd しても移らない
    # (OpenCode 本体の仕様)。案件ごとにフォルダを分けて作業できるよう、起動前にどこで
    # 始めるかを選んでもらう。パスを打たせず、作業フォルダ直下の一覧から番号で選ぶ。
    # 何も入れずに Enter なら従来どおり作業フォルダ直下で起動する。
    $dirs = @(Get-ChildItem -LiteralPath $Workspace -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '.*' -and $_.Name -ne 'スタート' -and $_.Name -ne 'safe-workspace' })
    if ($dirs.Count -eq 0) { return '' }
    Write-Host ''
    Write-Host 'どのフォルダで作業しますか？'
    Write-Host '────────────────────────────────'
    Write-Host ('0) ' + (Split-Path -Leaf $Workspace) + '（そのまま）')
    for ($i = 0; $i -lt $dirs.Count; $i++) {
        Write-Host ('' + ($i + 1) + ') ' + $dirs[$i].Name)
    }
    Write-Host ''
    $pick = Read-Host '番号を入力してください [0]'
    if (-not $pick) { $pick = '0' }
    if ($pick -notmatch '^[0-9]+$') {
        Write-Host '番号で選んでください。作業フォルダ直下で起動します。'
        return ''
    }
    $n = [int]$pick
    if ($n -eq 0) { return '' }
    if ($n -gt $dirs.Count) {
        Write-Host 'その番号はありません。作業フォルダ直下で起動します。'
        return ''
    }
    $sel = $dirs[$n - 1]
    Write-Host ('「' + $sel.Name + '」で起動します。')
    return $sel.FullName
}

if ($Agent -eq 'menu') {
    Write-Host ''
    Write-Host 'AIをまとめて起動（安全装置つき）'
    Write-Host 'いまの契約（課金プラン）に合わせて番号を選んでください。'
    Write-Host '────────────────────────────────'
    Write-Host ' 1) OpenCode（無料モデルを自分で選ぶ）… 完全無課金で使いたい人向け（送信検査なし）'
    Write-Host ' 2) セーフ AntiGravity（agy）       … こちらも無料（Google の無料 CLI）'
    Write-Host ' 3) OpenCode + DeepSeek             … DeepSeek のキーに少額チャージして使う人向け（送信検査つき）'
    Write-Host ' 4) DeepSeek-Claude（d-claude）     … DeepSeek の API キーを登録してある人向け'
    Write-Host '    ※4 は在校中のみ。卒業後は使えなくなります（OpenCode へ移行 → 説明書 docs/20_卒業後ガイド）'
    Write-Host ' 5) Claude Code                     … Claude を課金契約している人向け'
    Write-Host ' 6) セーフ Codex                    … Codex（ChatGPT）を使う人向け。デスクトップアプリは無料プランでも使えます'
    Write-Host '────────────────────────────────'
    Write-Host 'そのほかの起動方法:'
    Write-Host ' 7) Claude AI補助モード             … Claude 課金の人向け。グレーな操作を AI が二重チェックします'
    Write-Host ' 8) OpenCode（Web検索を確認制でON） … OpenCode で Web 検索も使いたい人向け'
    Write-Host ' 9) OpenCode（前回の続きから開く）  … 前回の OpenCode 作業のつづきをする人向け'
    Write-Host '10) 長時間おまかせモード（上級）    … 目を離して長時間 AI に任せたい人向け'
    Write-Host ''
    $choice = Read-Host '番号を入力してください [1]'
    if (-not $choice) { $choice = '1' }
    switch ($choice) {
        # 1 は無料モデルの自由選択（-Free）。DeepSeek キー不要・送信検査 Gateway なし。
        # 安全設定（permission の表）は DeepSeek 版と同一（2026-08-24 依頼者裁定）。
        '1'  { $Agent = 'opencode'; $SafetyProfile = 'standard'; $Free = $true; $Project = Select-ProjectFolder }
        '2'  {
            # 旧ボタン「4_セーフAntiGravityを起動」と同じ挙動（専用ランチャーへ委譲）。
            $agyLauncher = Join-Path $hooks 'launch-agy-safe.ps1'
            if (-not (Test-Path -LiteralPath $agyLauncher -PathType Leaf)) {
                throw "AntiGravity 用の起動スクリプトが見つかりません: $agyLauncher"
            }
            if ($env:AI_SAFE_DRY_RUN -eq '1') {
                Write-Output '安全装置（Bouncer）dry-run'
                Write-Output "  workspace: $Workspace"
                Write-Output '  agent:     agy (launch-agy-safe.ps1 へ委譲)'
                exit 0
            }
            & $agyLauncher -Workspace $Workspace
            exit $LASTEXITCODE
        }
        '3'  { $Agent = 'opencode'; $SafetyProfile = 'standard'; $Project = Select-ProjectFolder }
        '4'  { $Agent = 'd-claude'; $SafetyProfile = 'standard' }
        '5'  { $Agent = 'claude'; $SafetyProfile = 'standard' }
        '6'  { $Agent = 'codex'; $SafetyProfile = 'standard' }
        '7'  { $Agent = 'claude'; $SafetyProfile = 'assisted' }
        '8'  { $Agent = 'opencode'; $SafetyProfile = 'standard'; $WebSearch = $true; $Project = Select-ProjectFolder }
        '9'  { $Agent = 'opencode'; $SafetyProfile = 'standard'; $Resume = $true; $Project = Select-ProjectFolder }
        '10' {
            # 既存ボタン「6_長時間おまかせモードで起動」と同じ挙動（専用ランチャーへ委譲。
            # どの AI で走らせるかは launch-longrun.ps1 側の選択画面で選ぶ）。
            $longrunLauncher = Join-Path $hooks 'launch-longrun.ps1'
            if (-not (Test-Path -LiteralPath $longrunLauncher -PathType Leaf)) {
                throw "長時間おまかせモードの起動スクリプトが見つかりません: $longrunLauncher"
            }
            if ($env:AI_SAFE_DRY_RUN -eq '1') {
                Write-Output '安全装置（Bouncer）dry-run'
                Write-Output "  workspace: $Workspace"
                Write-Output '  agent:     longrun (launch-longrun.ps1 へ委譲)'
                exit 0
            }
            & $longrunLauncher -Workspace $Workspace
            exit $LASTEXITCODE
        }
        default { throw '1〜10 の番号を選んでください。' }
    }
}

if ($Agent -eq 'codex' -and $SafetyProfile -ne 'standard') { throw 'Codex は standard モードで起動してください。' }
if ($Agent -eq 'opencode' -and $SafetyProfile -ne 'standard') { throw 'OpenCode は standard モードで起動してください。' }
if ($Agent -eq 'd-claude' -and $SafetyProfile -ne 'standard') { throw 'd-claude は standard モードで起動してください。' }
if ($WebSearch -and $Agent -ne 'opencode') { throw '-WebSearch は OpenCode だけで指定できます。' }
if ($LongRun -and $Agent -ne 'opencode') { throw '-LongRun は OpenCode だけで指定できます。' }
if ($Resume -and $Agent -ne 'opencode') { throw '-Resume は OpenCode だけで指定できます。' }
if ($Free -and $Agent -ne 'opencode') { throw '-Free は OpenCode だけで指定できます。' }
if ($Plan -and $Agent -ne 'opencode') { throw '-Plan は OpenCode だけで指定できます。' }
if ($Free -and $Plan) { throw '-Free と -Plan は同時に指定できません。' }
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
        if ($Free) { Write-Output '  model:     free (無料モデル指定)' }
        elseif ($Plan) { Write-Output '  model:     plan (契約モデル指定)' }
    }
    if ($Agent -eq 'opencode' -and $Free) {
        Write-Output '  gateway:   none (-Free / 送信検査 Gateway を使いません)'
    } elseif ($Agent -eq 'opencode' -or $Agent -eq 'd-claude') {
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
            $ocLauncher = Join-Path $hooks 'opencode\launch-opencode-deepseek.ps1'
            # -Free / -Plan（モデル切り替え）は、この作業フォルダの OpenCode ランチャーが
            # そのパラメータに対応している場合だけ渡す。未対応の版に渡すとパラメータエラーで
            # 起動そのものが止まるため、外して標準設定で起動する（案内は出す）。
            $ocArgs = @{ Workspace = $Workspace; WebSearch = $WebSearch; LongRun = $LongRun; Resume = $Resume; Project = $Project }
            if ($Free -or $Plan) {
                $wanted = if ($Free) { 'Free' } else { 'Plan' }
                $ocCmd = Get-Command $ocLauncher -ErrorAction SilentlyContinue
                if ($ocCmd -and $ocCmd.Parameters -and $ocCmd.Parameters.ContainsKey($wanted)) {
                    $ocArgs[$wanted] = $true
                } else {
                    Write-Output ('※ この作業フォルダの OpenCode 起動スクリプトは -' + $wanted + ' に未対応のため、標準設定で起動します。')
                }
            }
            & $ocLauncher @ocArgs
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
                $hasKey = (Invoke-NativeQuiet -File $nodeCmd.Source -Arguments @($secretStore, '--has', 'deepseek')).Output.Trim()
                if ($hasKey -ne 'yes') {
                    throw 'DeepSeek APIキーが未登録です。スタート\キーと金庫\1_DeepSeekキーを登録 を先に実行してください。'
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
            # 既定は Flash のまま。かしこい deepseek-v4-pro を /model の一覧にも出しておき、
            # 受講者が `/model deepseek-v4-pro` でその場かぎり切り替えられるようにする
            # (実測: `/model <名前>` は "for this session only"。設定ファイルは書き換わらない)。
            $env:ANTHROPIC_CUSTOM_MODEL_OPTION = 'deepseek-v4-pro'
            $env:ANTHROPIC_CUSTOM_MODEL_OPTION_NAME = 'DeepSeek V4 Pro'
            $env:ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION = 'むずかしい作業向け。V4 Flash より料金が高くなります'
            & $powerShell.Source -NoProfile -ExecutionPolicy Bypass -File $deepseekGateway -Workspace $Workspace
            $exitCode = $LASTEXITCODE
        }
    }
    exit $exitCode
} finally {
    if ($monitorProc -and -not $monitorProc.HasExited) { Stop-Process -Id $monitorProc.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:\ANTHROPIC_AUTH_TOKEN, Env:\ANTHROPIC_MODEL, Env:\ANTHROPIC_DEFAULT_OPUS_MODEL, Env:\ANTHROPIC_DEFAULT_SONNET_MODEL, Env:\ANTHROPIC_DEFAULT_HAIKU_MODEL, Env:\CLAUDE_CODE_SUBAGENT_MODEL, Env:\CLAUDE_CODE_EFFORT_LEVEL, Env:\DS_CLAUDE_MODE, `
        Env:\ANTHROPIC_CUSTOM_MODEL_OPTION, Env:\ANTHROPIC_CUSTOM_MODEL_OPTION_NAME, Env:\ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION -ErrorAction SilentlyContinue
}
