param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = "",
    [switch]$Auto,  # "--auto" / "-Auto" で Safe Auto Mode を有効化する。
    # 長時間おまかせモード。承認を一切出さずに走らせる (--ask-for-approval never)。
    # 承認を省ける根拠は Codex 純正サンドボックス (--sandbox workspace-write /
    # windows.sandbox=unelevated) が作業フォルダ外への書き込みを止めているから。壁は外さない。
    [switch]$LongRun
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$env:AI_SAFE_ROOT = Join-Path $Workspace ".ai-safety"
$env:AI_SAFE_POLICY = Join-Path $env:AI_SAFE_ROOT "policy\safety-policy.json"
$env:AI_SAFE_LOG_DIR = Join-Path $HOME ".ai-safety\logs"

# A-1: CODEX_HOME は workspace 外 (HOME/.codex-safe) を向かせる。
# auth.json を workspace ツリーに物理コピーしないことで
# git add / OneDrive 同期 / workspace zip 化による平文流出を防ぐ。
$safeCodexHome = Join-Path $HOME ".codex-safe"
if (-not (Test-Path -LiteralPath $safeCodexHome)) {
    New-Item -ItemType Directory -Force -Path $safeCodexHome | Out-Null
}
$env:CODEX_HOME = $safeCodexHome

# workspace 内 .codex/ に config.toml が置かれている場合は .codex-safe/ へコピーして使う。
# auth.json は絶対にコピーしない。
# codex 0.135 fix: 旧版が置いた legacy config.toml (`[profiles.safe]` 入り) が .codex-safe/ に
# 残っていると --profile safe と衝突して fatal error になる。SSOT は workspace の
# .codex\config.toml (install が管理する新版) なので、safe.config.toml と同じく毎回上書きして
# 常に最新を反映させる ("既存ならスキップ" は legacy が永久に残る罠だったため撤廃)。
$workspaceCodexConfigSrc = Join-Path $Workspace ".codex\config.toml"
$safeCodexConfig = Join-Path $safeCodexHome "config.toml"
if (Test-Path -LiteralPath $workspaceCodexConfigSrc) {
    Copy-Item -LiteralPath $workspaceCodexConfigSrc -Destination $safeCodexConfig -Force
}

# codex 0.135: `--profile safe` が参照する $CODEX_HOME/safe.config.toml も配置する。
# (config.toml に `[profiles.safe]` を残すと 0.135 では起動が fatal error になるため分離済み。)
# config.toml が更新されたら safe.config.toml も追従させたいので、毎回上書きコピーする。
$workspaceSafeProfile = Join-Path $Workspace ".codex\safe.config.toml"
$safeCodexProfile = Join-Path $safeCodexHome "safe.config.toml"
if (Test-Path -LiteralPath $workspaceSafeProfile) {
    Copy-Item -LiteralPath $workspaceSafeProfile -Destination $safeCodexProfile -Force
}

# Hook trust 自動付与 (codex 0.135+ 対応・最重要) — mac launch-codex-safe.sh と同型。
# codex 0.135 以降は信頼していないフックを黙ってスキップするため、受講者が /hooks を手動で
# 信頼するまで guard が一切発火せず見守りモニターも無反応になる。launcher が起動のたびに
# 同梱フックの trusted_hash を safe.config.toml の [hooks.state] に注入して最初から Active にする。
# - trusted_hash はフックのコマンド内容由来で workspace パスに依存しない。
# - Windows の値は mac codex に hooks.windows.json を読ませて採取した暫定値。
#   Windows 実機の codex がキーをどの区切り (\ か /)・どの正規化で書くかは未確認なので、
#   実機検証で /hooks の Active を確認し、ずれていれば codex が書く [hooks.state] の
#   書式に合わせてここを調整すること (runbook 参照)。
# - IMPORTANT: hooks.windows.json を変更したらこのハッシュ表も再採取して更新する。
$hooksJson = Join-Path $Workspace ".codex\hooks.json"
if ((Test-Path -LiteralPath $hooksJson) -and (Test-Path -LiteralPath $safeCodexProfile)) {
    # TOML basic string 用に \ を \\ にエスケープする (Windows パス区切り対策)。
    $tomlPath = $hooksJson -replace '\\', '\\'
    $hookEntries = @(
        @('pre_tool_use:0:0',      '7cd5817d3031a107271994456a15b400232360984668dd261559283b75bb9780'),
        @('pre_tool_use:1:0',      'f55891da00eaa094a3c770c7227882a7bba69482fd93fd2e1ca08391e60ad7aa'),
        @('pre_tool_use:2:0',      'a7ecf1e0d05fd8ef0d4dc06b5891d4b0b4bc4f6f6711b895a4b11c737d3392cc'),
        @('post_tool_use:0:0',     'f2a4a55a367c421547ff81ced29b5406a7556a1e71759003d6e6eccdecfb7827'),
        @('user_prompt_submit:0:0','a254ae6612f7de19f6342536d0cc57699d2e345e6f0ad01bc899811caf951407')
    )
    $stateLines = @('', '[hooks.state]')
    foreach ($e in $hookEntries) {
        $stateLines += ('[hooks.state."{0}:{1}"]' -f $tomlPath, $e[0])
        $stateLines += ('trusted_hash = "sha256:{0}"' -f $e[1])
    }
    Add-Content -LiteralPath $safeCodexProfile -Value ($stateLines -join "`r`n")
}

if (-not (Test-Path -LiteralPath $env:AI_SAFE_POLICY)) {
    Write-Host "AI安全パッケージがこのフォルダにまだ導入されていません。"
    Write-Host "対象フォルダ: $Workspace"
    Write-Host "先に「導入(インストール)」を実行してから、もう一度この起動ボタンを押してください。"
    exit 1
}
if ($env:AI_SAFE_DRY_RUN -ne '1' -and -not (Test-Path -LiteralPath $safeCodexConfig)) {
    Write-Host "Codex の安全設定ファイルがまだ準備できていません。"
    Write-Host "先に「導入(インストール)」を実行してから、もう一度この起動ボタンを押してください。"
    Write-Host "（確認した場所: $safeCodexConfig）"
    exit 1
}

# auth.json は $HOME\.codex\auth.json をそのまま参照させる。
# SymbolicLink が使える環境ではリンクを張る。使えない環境では
# CODEX_HOME=$HOME\.codex-safe のまま Codex が $HOME\.codex の auth を探す。
# いずれにせよ workspace ツリーへの物理コピーはしない。
$srcAuth = Join-Path $HOME ".codex\auth.json"
$safeCodexAuth = Join-Path $safeCodexHome "auth.json"

if ($env:AI_SAFE_DRY_RUN -ne '1' -and -not (Test-Path -LiteralPath $srcAuth)) {
    Write-Host "Codex にまだログインしていません。"
    Write-Host "ターミナルで『codex login』を実行してログインしてから、もう一度この起動ボタンを押してください。"
    Write-Host "（確認した場所: $srcAuth）"
    exit 1
}

# A-1: workspace 内 .codex/auth.json に物理コピーが残っている場合は削除する (旧バージョン残骸)。
$legacyAuth = Join-Path $Workspace ".codex\auth.json"
if (Test-Path -LiteralPath $legacyAuth) {
    $legacyItem = Get-Item -LiteralPath $legacyAuth -Force
    $isLink = $false
    if ($legacyItem.PSObject.Properties.Name -contains 'LinkType') {
        $isLink = [bool]$legacyItem.LinkType
    }
    if (-not $isLink) {
        Write-Warning "A-1: Removing legacy physical auth.json from workspace tree: $legacyAuth"
        Remove-Item -LiteralPath $legacyAuth -Force
    }
}

# .codex-safe/ に auth.json がなければ HOME\.codex\auth.json へのシンボリックリンクを試みる。
# 失敗しても CODEX_HOME を $HOME\.codex に切り替えて動作継続する (物理コピー禁止)。
# DRY_RUN 時は実ファイル操作をスキップする(テスト用)。
if ($env:AI_SAFE_DRY_RUN -ne '1' -and -not (Test-Path -LiteralPath $safeCodexAuth)) {
    $linkCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $safeCodexAuth -Target $srcAuth -ErrorAction Stop | Out-Null
        $linkCreated = $true
    } catch {
        Write-Warning "SymbolicLink creation failed ($($_.Exception.Message)). Using HOME\.codex directly."
    }
    if (-not $linkCreated) {
        # フォールバック: CODEX_HOME を元の HOME\.codex に戻す。workspace には何も置かない。
        $env:CODEX_HOME = Join-Path $HOME ".codex"
    }
}

# Safe Auto Mode: --auto なら承認を on-failure に下げて自走させる。
# 危険コマンドは PreToolUse hook(guard-bash) が approval 非依存で exit2 deny するため、
# OS 隔離(egress)の実証可否に関わらず自走してよい(診断 2026-06-26 §4 で実証)。
# Windows codex 0.135 の sandbox はネット隔離を提供しない(Test-NetworkEgress が構造的に FAIL)
# ため従来は永久 untrusted=「ターン1/3」だった。これを廃し、隔離チェックは結果を「開示」のみ行う。
# v1.12.0 教室プロファイル: 既定を untrusted → on-request に変更（モデルが承認要と自己判断
# した時だけ確認）。config/safe.config.toml 側の approvals_reviewer=auto_review が承認要求を
# 二次レビューする。決定的 deny は guard-bash が approval 非依存で担う。
$approval = 'on-request'
if ($Auto) {
    # --auto は隔離結果に関わらず on-failure(自走)。危険は hook(guard-bash) が止める。
    $approval = 'on-failure'
    $doctorPath = if ($env:AI_SAFE_DOCTOR) { $env:AI_SAFE_DOCTOR } else { Join-Path $PSScriptRoot 'doctor.ps1' }
    $isolationOk = $false
    if (Test-Path -LiteralPath $doctorPath -ErrorAction SilentlyContinue) {
        [Console]::Error.WriteLine("🔍 OS 隔離(ファイル金庫)を確認しています…数秒お待ちください。")
        try {
            $isCmdFile = $doctorPath -match '\.(cmd|bat)$'
            $job = if ($isCmdFile) {
                Start-Job -ScriptBlock { & cmd.exe /c $using:doctorPath *> $null; $LASTEXITCODE }
            } else {
                Start-Job -ScriptBlock {
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $using:doctorPath -IsolationCheck codex-fileonly *> $null
                    $LASTEXITCODE
                }
            }
            $completed = Wait-Job -Job $job -Timeout 30
            if ($null -eq $completed) {
                Stop-Job -Job $job; Remove-Job -Job $job -Force
            } else {
                $jobRc = Receive-Job -Job $job
                Remove-Job -Job $job -Force
                if (@($jobRc)[-1] -eq 0) { $isolationOk = $true }
            }
        } catch {
            $isolationOk = $false
        }
    }
    if ($isolationOk) {
        [Console]::Error.WriteLine("🔒 OS隔離(金庫)を確認: ワークスペース外への書込を遮断しています。")
    } else {
        [Console]::Error.WriteLine("⚠ ネット遮断はOSで未実証です(自走は継続)。危険なコマンドは安全フックがブロックします。")
    }
}

if ($LongRun) {
    # 目を離す前提のモード。確認は出さない (出しても答える人がいない)。
    # 壁 (--sandbox workspace-write) と決定的 deny 床 (guard-bash hook) はそのまま。
    $approval = 'never'
}

# A-2: hooks 有効化フラグを launcher 側でも明示渡し。
# config.toml の features.hooks=true と合わせて二重保証する。
$argsList = @(
    "--cd", $Workspace,
    "--profile", "safe",
    "--sandbox", "workspace-write",
    "--ask-for-approval", $approval,
    "-c", "windows.sandbox=`"unelevated`"",
    "-c", "features.hooks=true"
)

if ($env:AI_SAFE_DRY_RUN -eq '1') {
    Write-Output ("codex " + ($argsList -join ' '))
    exit 0
}

# codex バイナリ検出（PATH に無くても npm グローバル等から見つける）。
# npm install -g @openai/codex は Windows で %APPDATA%\npm\codex.cmd に入る。
$Codex = $env:CODEX_BIN
if (-not $Codex) {
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd) { $Codex = $cmd.Source }
}
if (-not $Codex) {
    foreach ($c in @(
        (Join-Path $env:APPDATA "npm\codex.cmd"),
        (Join-Path $env:APPDATA "npm\codex"),
        (Join-Path $env:USERPROFILE ".local\bin\codex.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\codex")
    )) { if ($c -and (Test-Path -LiteralPath $c)) { $Codex = $c; break } }
}
if (-not $Codex) {
    Write-Host "codex コマンドが見つかりません。"
    Write-Host "「0_AIツールをまとめて入れる-Windows.bat」を実行したか、'npm install -g @openai/codex' を確認してください。"
    Write-Host "（場所を手動指定する場合は環境変数 CODEX_BIN にフルパスを設定）"
    exit 1
}

if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & $Codex @argsList $Prompt
} else {
    & $Codex @argsList
}
exit $LASTEXITCODE
