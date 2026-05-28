param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = ""
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
if (-not (Test-Path -LiteralPath $safeCodexConfig)) {
    throw "Codex safety config was not found: $safeCodexConfig"
}

# auth.json は $HOME\.codex\auth.json をそのまま参照させる。
# SymbolicLink が使える環境ではリンクを張る。使えない環境では
# CODEX_HOME=$HOME\.codex-safe のまま Codex が $HOME\.codex の auth を探す。
# いずれにせよ workspace ツリーへの物理コピーはしない。
$srcAuth = Join-Path $HOME ".codex\auth.json"
$safeCodexAuth = Join-Path $safeCodexHome "auth.json"

if (-not (Test-Path -LiteralPath $srcAuth)) {
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
if (-not (Test-Path -LiteralPath $safeCodexAuth)) {
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

# A-2: hooks 有効化フラグを launcher 側でも明示渡し。
# config.toml の features.hooks=true と合わせて二重保証する。
$argsList = @(
    "--cd", $Workspace,
    "--profile", "safe",
    "--sandbox", "workspace-write",
    "--ask-for-approval", "untrusted",
    "-c", "windows.sandbox=`"unelevated`"",
    "-c", "features.hooks=true"
)

if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & codex @argsList $Prompt
} else {
    & codex @argsList
}
exit $LASTEXITCODE
