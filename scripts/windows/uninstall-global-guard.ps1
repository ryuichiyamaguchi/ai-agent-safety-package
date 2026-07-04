# uninstall-global-guard.ps1 — apply-global-guard.ps1 で反映した「全体設定」への変更を取り消し、
# 適用前のバックアップから %USERPROFILE%\.claude\settings.json と .codex\config.toml / hooks.json を
# 元へ戻す。記録(~\.ai-safety\global-guard-state.json)を辿って復元するので確実に元に戻せる。
param([switch]$DryRun)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspace = (Resolve-Path (Join-Path $here "..\..\..")).Path
$common = Join-Path $here "..\common"
$claudeJs = Join-Path $common "apply-global-guard.js"
$codexJs  = Join-Path $common "apply-global-codex.js"

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
if (-not (Test-Path -LiteralPath $claudeJs) -or -not (Test-Path -LiteralPath $codexJs)) {
    Write-Error "取り消しスクリプトが見つかりません: $common"
    exit 2
}

$rc = 0
Write-Host "-- Claude 全体設定を元に戻す ----------------------------"
& node $claudeJs uninstall --target $claudeTarget @stateArgs @dryArgs
if ($LASTEXITCODE -ne 0) { $rc = 1 }

Write-Host ""
Write-Host "-- Codex 全体設定を元に戻す -----------------------------"
& node $codexJs uninstall --config-target $codexConfig --hooks-target $codexHooks @stateArgs @dryArgs
if ($LASTEXITCODE -ne 0) { $rc = 1 }

exit $rc
