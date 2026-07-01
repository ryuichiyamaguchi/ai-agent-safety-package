# apply-global-deny.ps1 — この PC の Claude 全体設定 (%USERPROFILE%\.claude\settings.json) に、
# 危険コマンドの deny (curl / rm -rf / .env 読取 / git push / 外部送信ドメイン等) を反映する。
# A案 (宣言的 deny のみ): 既存の hooks / env / allow / ask は壊さず、permissions.deny だけ union マージ。
# 実行前に ~/.ai-safety/backups/ へ自動バックアップ。実体のマージは scripts/common/apply-global-deny.js
# (node) が行う (OS 共通・mac で検証済み)。workspace + launcher 経由の従来防御とは独立 (併用可)。
param([switch]$DryRun)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# 配置: <workspace>\.ai-safety\hooks\windows\apply-global-deny.ps1
$workspace = (Resolve-Path (Join-Path $here "..\..\..")).Path
$src = if ($env:AI_SAFE_DENY_SRC) { $env:AI_SAFE_DENY_SRC } else { Join-Path $workspace ".claude\settings.json" }
$js  = Join-Path $here "..\common\apply-global-deny.js"
$target = if ($env:AI_SAFE_GLOBAL_CLAUDE) { $env:AI_SAFE_GLOBAL_CLAUDE } else { Join-Path $HOME ".claude\settings.json" }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error "node が見つかりません。Node.js を入れてから実行してください。"
    exit 2
}
if (-not (Test-Path -LiteralPath $src)) {
    Write-Error "deny の元設定が見つかりません: $src`n  → 先に安全パッケージのインストール（1_安全パッケージを準備）を実行してください。"
    exit 2
}
if (-not (Test-Path -LiteralPath $js)) {
    Write-Error "apply-global-deny.js が見つかりません: $js"
    exit 2
}

Write-Host "この PC の Claude 全体（%USERPROFILE%\.claude\settings.json）に、危険コマンドの deny を反映します。"
Write-Host "（既存の設定は壊しません。反映前に自動でバックアップを取ります。）"
if ($DryRun) { node $js $src $target "--dry-run" } else { node $js $src $target }
exit $LASTEXITCODE
