﻿param(
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

if (-not (Test-Path -LiteralPath $settings)) {
    throw "Claude safety settings were not found: $settings"
}
if (-not (Test-Path -LiteralPath $env:AI_SAFE_POLICY)) {
    throw "AI Safety package is not installed in workspace: $Workspace"
}

$argsList = @("--settings", $settings, "--setting-sources", "user,project,local")
# claude --help で --permission-mode が存在するか確認してから付ける
$helpText = ""
try { $helpText = (& claude --help 2>&1 | Out-String) } catch { $helpText = "" }
if ($helpText -match "--permission-mode") {
    $argsList = @("--permission-mode", "default") + $argsList
}

if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & claude @argsList $Prompt
} else {
    & claude @argsList
}
exit $LASTEXITCODE
