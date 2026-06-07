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

# codex 0.135: `--profile safe` が参照する $CODEX_HOME/safe.config.toml も配置する。
# (config.toml に `[profiles.safe]` を残すと 0.135 では起動が fatal error になるため分離済み。)
# config.toml が更新されたら safe.config.toml も追従させたいので、毎回上書きコピーする。
$workspaceSafeProfile = Join-Path $Workspace ".codex\safe.config.toml"
$safeCodexProfile = Join-Path $safeCodexHome "safe.config.toml"
if (Test-Path -LiteralPath $workspaceSafeProfile) {
    Copy-Item -LiteralPath $workspaceSafeProfile -Destination $safeCodexProfile -Force
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
                # M-3: Receive-Job は配列を返すことがあるため末尾要素を整数として取得する。
                # フェイルクローズ方向: 末尾が 0 のときだけ green に解放する。
                if (@($jobRc)[-1] -eq 0) {
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
