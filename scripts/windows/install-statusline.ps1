# install-statusline.ps1 — 軽量ステータスライン(statusline.mjs)を Claude 全体設定
# (%USERPROFILE%\.claude\settings.json) に登録する。claude / d-claude 両方に効く。
# 配置: <workspace>\.ai-safety\hooks\windows\install-statusline.ps1
param([string]$Mode = "install")
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$js = Join-Path $here "..\common\install-statusline.js"
$script = Join-Path $here "..\common\statusline.mjs"
$target = if ($env:AI_SAFE_GLOBAL_CLAUDE) { $env:AI_SAFE_GLOBAL_CLAUDE } else { Join-Path $HOME ".claude\settings.json" }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error "node が見つかりません。Node.js を入れてから実行してください。"
    exit 2
}
if (-not (Test-Path -LiteralPath $js) -or -not (Test-Path -LiteralPath $script)) {
    Write-Error "スクリプトが見つかりません（先に「1_安全パッケージを準備」を実行してください）: $js"
    exit 2
}

if ($Mode -eq "uninstall") {
    node $js uninstall --target $target
} else {
    node $js install --target $target --script $script --os windows
}
exit $LASTEXITCODE
