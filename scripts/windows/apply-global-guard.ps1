# apply-global-guard.ps1 — この PC の Claude と Codex の「全体設定」に、危険コマンドのガードを反映する。
#   Claude (%USERPROFILE%\.claude\settings.json):
#     permissions.deny を union し、guard の絶対パスを指す hooks を追加。どのフォルダから claude を
#     起動しても rm -r / cat .env / curl|sh 等をブロックする。
#   Codex (%USERPROFILE%\.codex\config.toml + hooks.json):
#     approval_policy=on-request / approvals_reviewer=auto_review / sandbox_mode=workspace-write /
#     shell_environment_policy.exclude(APIキー) 等の決定的保護を反映(常時有効)。guard の絶対パス
#     hooks も配線する(発火には codex の /hooks で一度だけ信頼が要る)。
# 既存設定は壊さない(union / 管理キーのみ)。反映前に自動バックアップ。取り消しは
# uninstall-global-guard.ps1 で元へ戻せる。実体マージは node (scripts/common/apply-global-*.js)。
param([switch]$DryRun)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# 配置: <workspace>\.ai-safety\hooks\windows\apply-global-guard.ps1
$workspace = (Resolve-Path (Join-Path $here "..\..\..")).Path
$guardDir = $here
$common = Join-Path $here "..\common"
$claudeJs = Join-Path $common "apply-global-guard.js"
$codexJs  = Join-Path $common "apply-global-codex.js"

$src = if ($env:AI_SAFE_DENY_SRC) { $env:AI_SAFE_DENY_SRC } else { Join-Path $workspace ".claude\settings.json" }
$claudeTarget = if ($env:AI_SAFE_GLOBAL_CLAUDE) { $env:AI_SAFE_GLOBAL_CLAUDE } else { Join-Path $HOME ".claude\settings.json" }
$codexConfig  = if ($env:AI_SAFE_GLOBAL_CODEX) { $env:AI_SAFE_GLOBAL_CODEX } else { Join-Path $HOME ".codex\config.toml" }
$codexHooks   = if ($env:AI_SAFE_GLOBAL_CODEX_HOOKS) { $env:AI_SAFE_GLOBAL_CODEX_HOOKS } else { Join-Path $HOME ".codex\hooks.json" }
$stateArgs = @()
if ($env:AI_SAFE_GLOBAL_STATE) { $stateArgs = @("--state", $env:AI_SAFE_GLOBAL_STATE) }
$dryArgs = @()
if ($DryRun) { $dryArgs = @("--dry-run") }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error "node が見つかりません。Node.js を入れてから実行してください。"
    exit 2
}
if (-not (Test-Path -LiteralPath $src)) {
    Write-Error "deny の元設定が見つかりません: $src`n  → 先に「1_安全パッケージを準備」を実行してください。"
    exit 2
}
if (-not (Test-Path -LiteralPath $claudeJs) -or -not (Test-Path -LiteralPath $codexJs)) {
    Write-Error "反映スクリプトが見つかりません: $common`n  → 先に「1_安全パッケージを準備」を実行してください。"
    exit 2
}

$rc = 0
Write-Host "-- Claude 全体設定に反映 --------------------------------"
& node $claudeJs apply --source $src --target $claudeTarget --os windows --guard-dir $guardDir @stateArgs @dryArgs
if ($LASTEXITCODE -ne 0) { $rc = 1 }

Write-Host ""
Write-Host "-- Codex 全体設定に反映 ---------------------------------"
& node $codexJs apply --config-target $codexConfig --hooks-target $codexHooks --os windows --guard-dir $guardDir @stateArgs @dryArgs
if ($LASTEXITCODE -ne 0) { $rc = 1 }
Write-Host "  ※ Codex の guard hook を発火させるには、一度だけ codex を起動して /hooks で信頼してください。"
Write-Host "     常時有効な保護(サンドボックス・承認・APIキー除外)は上の config.toml で決定的に効きます。"

exit $rc
