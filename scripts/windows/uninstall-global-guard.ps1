# uninstall-global-guard.ps1 — apply-global-guard.ps1 で入れた「全体設定」への変更を取り消し、
# 適用前のバックアップから元へ戻す。対象は 4 エンジン:
#   Claude Code (%USERPROFILE%\.claude\settings.json)
#   Codex       (%USERPROFILE%\.codex\config.toml, hooks.json)
#   agy/Gemini  (%USERPROFILE%\.gemini\settings.json)
#   OpenCode    (%USERPROFILE%\.config\opencode\opencode.json | .jsonc)
# 記録(~\.ai-safety\global-guard-state.json)を辿って「入れた分だけ」を正確に戻すので、
# 入れていないエンジンには触らない。
param([switch]$DryRun)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspace = (Resolve-Path (Join-Path $here "..\..\..")).Path
$common = Join-Path $here "..\common"
$claudeJs   = Join-Path $common "apply-global-guard.js"
$codexJs    = Join-Path $common "apply-global-codex.js"
$agyJs      = Join-Path $common "apply-global-agy.js"
$opencodeJs = Join-Path $common "apply-global-opencode.js"

$claudeTarget = if ($env:AI_SAFE_GLOBAL_CLAUDE) { $env:AI_SAFE_GLOBAL_CLAUDE } else { Join-Path $HOME ".claude\settings.json" }
$codexConfig  = if ($env:AI_SAFE_GLOBAL_CODEX) { $env:AI_SAFE_GLOBAL_CODEX } else { Join-Path $HOME ".codex\config.toml" }
$codexHooks   = if ($env:AI_SAFE_GLOBAL_CODEX_HOOKS) { $env:AI_SAFE_GLOBAL_CODEX_HOOKS } else { Join-Path $HOME ".codex\hooks.json" }
$agyTarget    = if ($env:AI_SAFE_GLOBAL_AGY) { $env:AI_SAFE_GLOBAL_AGY } else { Join-Path $HOME ".gemini\settings.json" }
$opencodeDir  = if ($env:AI_SAFE_GLOBAL_OPENCODE_DIR) { $env:AI_SAFE_GLOBAL_OPENCODE_DIR } elseif ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME "opencode" } else { Join-Path $HOME ".config\opencode" }
$stateArgs = @()
if ($env:AI_SAFE_GLOBAL_STATE) { $stateArgs = @("--state", $env:AI_SAFE_GLOBAL_STATE) }
$dryArgs = @()
if ($DryRun) { $dryArgs = @("--dry-run") }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error "node が見つかりません。Node.js を入れてから実行してください。"
    exit 2
}
foreach ($js in @($claudeJs, $codexJs, $agyJs, $opencodeJs)) {
    if (-not (Test-Path -LiteralPath $js)) {
        Write-Error "取り消しスクリプトが見つかりません: $js"
        exit 2
    }
}

$rc = 0
Write-Host "-- 1) Claude Code の全体設定を元に戻す -------------------"
& node @(@($claudeJs, "uninstall", "--target", $claudeTarget) + $stateArgs + $dryArgs)
if ($LASTEXITCODE -ne 0) { $rc = 1 }

Write-Host ""
Write-Host "-- 2) Codex の全体設定を元に戻す -------------------------"
& node @(@($codexJs, "uninstall", "--config-target", $codexConfig, "--hooks-target", $codexHooks) + $stateArgs + $dryArgs)
if ($LASTEXITCODE -ne 0) { $rc = 1 }

Write-Host ""
Write-Host "-- 3) agy / Gemini の全体設定を元に戻す ------------------"
& node @(@($agyJs, "uninstall", "--target", $agyTarget) + $stateArgs + $dryArgs)
if ($LASTEXITCODE -ne 0) { $rc = 1 }

Write-Host ""
Write-Host "-- 4) OpenCode の全体設定を元に戻す ----------------------"
& node @(@($opencodeJs, "uninstall", "--config-dir", $opencodeDir) + $stateArgs + $dryArgs)
if ($LASTEXITCODE -ne 0) { $rc = 1 }

exit $rc
