param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = "",
    [string]$AutoFlag = ""   # "--auto" を受け取る位置引数。Safe Auto Mode を有効化する。
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
$workspaceCodexConfigSrc = Join-Path $Workspace ".codex\config.toml"
$safeCodexConfig = Join-Path $safeCodexHome "config.toml"
if ((Test-Path -LiteralPath $workspaceCodexConfigSrc) -and (-not (Test-Path -LiteralPath $safeCodexConfig))) {
    Copy-Item -LiteralPath $workspaceCodexConfigSrc -Destination $safeCodexConfig -Force
}

if (-not (Test-Path -LiteralPath $env:AI_SAFE_POLICY)) {
    throw "AI Safety package is not installed in workspace: $Workspace"
}
if ($env:AI_SAFE_DRY_RUN -ne '1' -and -not (Test-Path -LiteralPath $safeCodexConfig)) {
    throw "Codex safety config was not found: $safeCodexConfig"
}

# auth.json は $HOME\.codex\auth.json をそのまま参照させる。
# SymbolicLink が使える環境ではリンクを張る。使えない環境では
# CODEX_HOME=$HOME\.codex-safe のまま Codex が $HOME\.codex の auth を探す。
# いずれにせよ workspace ツリーへの物理コピーはしない。
$srcAuth = Join-Path $HOME ".codex\auth.json"
$safeCodexAuth = Join-Path $safeCodexHome "auth.json"

if ($env:AI_SAFE_DRY_RUN -ne '1' -and -not (Test-Path -LiteralPath $srcAuth)) {
    throw "Codex auth not found at $srcAuth. Please run 'codex login' first."
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

# Safe Auto Mode: --auto かつ doctor の隔離チェックが green のときだけ承認を下げる。
# フェイルクローズ設計:
#   (a) doctor パスが存在しない → Test-Path で弾く → untrusted
#   (b) doctor 呼び出しで例外発生 → try/catch で捕捉 → untrusted
#   (c) doctor がハング → Start-Job + Wait-Job -Timeout 60 で上限 60 秒 → untrusted
#   (d) doctor が非0終了 → $LASTEXITCODE != 0 → untrusted
# green(on-failure)は「doctor が確かに走って exit 0 を返したときだけ」。
$approval = 'untrusted'
if ($AutoFlag -eq '--auto') {
    $doctorPath = if ($env:AI_SAFE_DOCTOR) { $env:AI_SAFE_DOCTOR } else { Join-Path $PSScriptRoot 'doctor.ps1' }
    $isolationOk = $false
    if (-not (Test-Path -LiteralPath $doctorPath -ErrorAction SilentlyContinue)) {
        # (a) doctor ファイル不在 → フェイルクローズ
        [Console]::Error.WriteLine("⚠ オートを有効にできません: doctor が見つかりません ($doctorPath)")
        [Console]::Error.WriteLine("  → 安全のため都度承認モードで起動します。直すには doctor を配置してください。")
    } else {
        # doctor を Start-Job で起動しタイムアウト上限 60 秒で呼ぶ。
        # (b)(c) 例外・ハング どちらもフェイルクローズ。
        try {
            $isCmdFile = $doctorPath -match '\.(cmd|bat)$'
            $job = if ($isCmdFile) {
                Start-Job -ScriptBlock { & cmd.exe /c $using:doctorPath *> $null; $LASTEXITCODE }
            } else {
                Start-Job -ScriptBlock {
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $using:doctorPath -IsolationCheck codex *> $null
                    $LASTEXITCODE
                }
            }
            $completed = Wait-Job -Job $job -Timeout 60
            if ($null -eq $completed) {
                # タイムアウト (c) → フェイルクローズ
                Stop-Job -Job $job; Remove-Job -Job $job -Force
                [Console]::Error.WriteLine("⚠ オートを有効にできません: doctor が 60 秒以内に応答しませんでした。")
                [Console]::Error.WriteLine("  → 安全のため都度承認モードで起動します。直すには doctor を実行してください。")
            } else {
                $jobRc = Receive-Job -Job $job
                Remove-Job -Job $job -Force
                if ($jobRc -eq 0) {
                    $isolationOk = $true
                } else {
                    # (d) 非0終了 → フェイルクローズ
                    [Console]::Error.WriteLine("⚠ オートを有効にできません: OS 隔離(金庫)を確認できませんでした。")
                    [Console]::Error.WriteLine("  → 安全のため都度承認モードで起動します。直すには doctor を実行してください。")
                }
            }
        } catch {
            # (b) 例外 → フェイルクローズ
            [Console]::Error.WriteLine("⚠ オートを有効にできません: doctor 呼び出しでエラーが発生しました: $($_.Exception.Message)")
            [Console]::Error.WriteLine("  → 安全のため都度承認モードで起動します。直すには doctor を実行してください。")
        }
    }
    if ($isolationOk) {
        $approval = 'on-failure'
    }
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

if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & codex @argsList $Prompt
} else {
    & codex @argsList
}
exit $LASTEXITCODE
