param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = ""
)

# launch-agy-safe.ps1
#
# Antigravity CLI (agy) を安全装置付きで起動する Windows 用 launcher。
# v1.3.0 で新規追加（Gemini CLI から Antigravity CLI への移行対応）。
#
# 強制する防御:
#   --sandbox          : agy のターミナル制限サンドボックスを必須化
#   --add-dir <ws>     : 作業ディレクトリを明示
# 渡さないフラグ:
#   --dangerously-skip-permissions（絶対に付けない）

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)

$env:AI_SAFE_ROOT = Join-Path $Workspace ".ai-safety"
$env:AI_SAFE_POLICY = Join-Path $env:AI_SAFE_ROOT "policy\safety-policy.json"
$env:AI_SAFE_LOG_DIR = Join-Path $HOME ".ai-safety\logs"

# agy バイナリ検出
$Agy = $env:AGY
if (-not $Agy) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Antigravity\agy.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\agy.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\agy")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $Agy = $candidate
            break
        }
    }
    if (-not $Agy) {
        $cmd = Get-Command agy -ErrorAction SilentlyContinue
        if ($cmd) { $Agy = $cmd.Path }
    }
}

if (-not $Agy -or -not (Test-Path -LiteralPath $Agy)) {
    Write-Error @"
Antigravity CLI (agy) が見つかりません。

インストール手順 (PowerShell):
  irm https://antigravity.google/cli/install.ps1 | iex

インストール後、以下のいずれかを満たしてください:
  - %LOCALAPPDATA%\Antigravity\ が `$env:PATH` に含まれている
  - 環境変数 `AGY` に agy バイナリのフルパスをセット
"@
    exit 2
}

# 推奨設定の案内（初回のみ）
$Recommended = Join-Path $env:AI_SAFE_ROOT "configs\agy\recommended-settings.json"
$HintFlag = Join-Path $HOME ".ai-safety\.agy-recommended-shown"
if ((Test-Path -LiteralPath $Recommended) -and (-not (Test-Path -LiteralPath $HintFlag))) {
    $hintDir = Split-Path -Parent $HintFlag
    if (-not (Test-Path -LiteralPath $hintDir)) {
        New-Item -ItemType Directory -Path $hintDir -Force | Out-Null
    }
    # C-4: here-string 終端行に引数を付けられないため変数に格納してから Write-Host
    $hintMsg = @"
[初回ヒント] agy の推奨セキュリティ設定があります:
  $Recommended

agy 起動後、画面右下の `/settings` を開いて、上記 JSON の各キーと同じ値に
合わせてください（特に allow_access_gitignore / allow_edit_gitignore /
allow_auto_run_commands は OFF 推奨）。

このヒントは次回以降は表示されません（再表示する場合は次のファイルを削除:
  $HintFlag）
"@
    Write-Host $hintMsg -ForegroundColor Yellow
    Set-Content -LiteralPath $HintFlag -Value (Get-Date -Format "o") -ErrorAction SilentlyContinue
}

$argsList = @("--sandbox", "--add-dir", $Workspace)
if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & $Agy @argsList --prompt $Prompt
} else {
    & $Agy @argsList
}
exit $LASTEXITCODE
