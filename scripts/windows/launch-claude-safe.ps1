param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = ""
)

# M13: Claude Code の approval 制御は CLI フラグでは渡せない（Codex の
# --ask-for-approval untrusted に相当する仕組みは settings.json 側にある）。
# 本パッケージは configs\claude\settings.windows.json の permissions / hooks 経由で
# 同等の効果（PreToolUse hook による fail-closed 判定 + 危険コマンド deny）を出している。
# 追加の保険として --permission-mode default を渡し、Claude Code 側のデフォルト
# 承認モードを明示する。古い CLI でフラグ非対応の場合はフォールバックする。
$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$settings = Join-Path $Workspace ".claude\settings.json"
$env:AI_SAFE_ROOT = Join-Path $Workspace ".ai-safety"
$env:AI_SAFE_POLICY = Join-Path $env:AI_SAFE_ROOT "policy\safety-policy.json"
$env:AI_SAFE_LOG_DIR = Join-Path $HOME ".ai-safety\logs"

# claude-safe は「普通の Claude（あなたのログイン認証）」を起動する。DeepSeek 連携(d-claude)が
# 残したルーティング系の環境変数を引き継ぐと、無効トークンを Anthropic に送って 401 になる
# (永続 setx の置き土産=footgun)。このプロセス内で消し、claude-safe を常に素の Anthropic に向ける。
# ただし d-claude (DeepSeek 駆動) は gateway 経由でこのスクリプトを呼び、DeepSeek キーと
# Gateway の BASE_URL/MODEL を「使う」ために渡してくる。その経路では gateway が
# DS_CLAUDE_MODE=1 を立てるので Remove をスキップする (消すと "not logged in" になる)。
if ($env:DS_CLAUDE_MODE -ne '1') {
    foreach ($v in @('ANTHROPIC_AUTH_TOKEN','ANTHROPIC_BASE_URL','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL','ANTHROPIC_CUSTOM_MODEL_OPTION')) {
        if (Test-Path "Env:\$v") { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
    }
}

if (-not (Test-Path -LiteralPath $settings)) {
    throw "Claude safety settings were not found: $settings"
}
if (-not (Test-Path -LiteralPath $env:AI_SAFE_POLICY)) {
    throw "AI Safety package is not installed in workspace: $Workspace"
}

# claude バイナリ検出（PATH に無くても npm グローバル / native installer から見つける）。
# npm install -g @anthropic-ai/claude-code は Windows で %APPDATA%\npm\claude.cmd に入る。
$Claude = $env:CLAUDE_BIN
if (-not $Claude) {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) { $Claude = $cmd.Source }
}
if (-not $Claude) {
    foreach ($c in @(
        (Join-Path $env:APPDATA "npm\claude.cmd"),
        (Join-Path $env:APPDATA "npm\claude"),
        (Join-Path $env:USERPROFILE ".local\bin\claude.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\claude")
    )) { if ($c -and (Test-Path -LiteralPath $c)) { $Claude = $c; break } }
}
if (-not $Claude) {
    Write-Host "claude コマンドが見つかりません。"
    Write-Host "「0_AIツールをまとめて入れる-Windows.bat」を実行したか、'npm install -g @anthropic-ai/claude-code' を確認してください。"
    Write-Host "（場所を手動指定する場合は環境変数 CLAUDE_BIN にフルパスを設定）"
    exit 1
}

$argsList = @("--settings", $settings, "--setting-sources", "user,project,local")
# claude --help で --permission-mode が存在するか確認してから付ける
$helpText = ""
try { $helpText = (& $Claude --help 2>&1 | Out-String) } catch { $helpText = "" }
if ($helpText -match "--permission-mode") {
    $argsList = @("--permission-mode", "default") + $argsList
}

if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & $Claude @argsList $Prompt
} else {
    & $Claude @argsList
}
exit $LASTEXITCODE
