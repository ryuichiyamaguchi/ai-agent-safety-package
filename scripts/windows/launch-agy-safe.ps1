param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = "",
    [switch]$Auto   # "--auto" / "-Auto" で Safe Auto Mode を有効化する。
)

# launch-agy-safe.ps1
#
# Antigravity CLI (agy) を安全装置付きで起動する Windows 用 launcher。
# v1.3.0 で新規追加（Gemini CLI から Antigravity CLI への移行対応）。
#
# 強制する防御:
#   --sandbox          : agy のターミナル制限サンドボックスを必須化
#   --add-dir <ws>     : 作業ディレクトリを明示
# Safe Auto Mode (--auto / $Auto):
#   doctor green かつ agy 存在 → --dangerously-skip-permissions を付与(--sandbox は維持)
#   実証はしていない旨を起動時に必ず表示(overclaim 回避)。
# 渡さないフラグ:
#   --dangerously-skip-permissions（--auto green 以外では絶対に付けない）

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
        if ($cmd) { $Agy = $cmd.Source }
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

# Safe Auto Mode 分岐(宣言ベース・option B): doctor green のとき
# --dangerously-skip-permissions を付与(--sandbox は維持)。実証はしていない旨を必ず表示。
# フェイルクローズ設計(codex launcher と同一方針):
#   (a) doctor パスが存在しない → Test-Path で弾く → skip-permissions 付与しない
#   (b) doctor 呼び出しで例外発生 → try/catch → skip-permissions 付与しない
#   (c) doctor がハング → Start-Job + Wait-Job -Timeout 60 → skip-permissions 付与しない
#   (d) doctor が非0終了 → skip-permissions 付与しない
$autoArgs = @()
if ($Auto) {
    $doctorPath = if ($env:AI_SAFE_DOCTOR) { $env:AI_SAFE_DOCTOR } else { Join-Path $PSScriptRoot 'doctor.ps1' }
    $isolationOk = $false
    if (-not (Test-Path -LiteralPath $doctorPath -ErrorAction SilentlyContinue)) {
        # (a) doctor ファイル不在 → フェイルクローズ
        [Console]::Error.WriteLine("⚠ オートを有効にできません: agy の隔離チェックに失敗しました。")
        [Console]::Error.WriteLine("  → 安全のため通常モード(--sandbox のみ)で起動します。")
    } else {
        # doctor を Start-Job で起動しタイムアウト上限 60 秒で呼ぶ。
        try {
            $isCmdFile = $doctorPath -match '\.(cmd|bat)$'
            $job = if ($isCmdFile) {
                Start-Job -ScriptBlock { & cmd.exe /c $using:doctorPath *> $null; $LASTEXITCODE }
            } else {
                Start-Job -ScriptBlock {
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $using:doctorPath -IsolationCheck agy *> $null
                    $LASTEXITCODE
                }
            }
            $completed = Wait-Job -Job $job -Timeout 60
            if ($null -eq $completed) {
                # タイムアウト (c) → フェイルクローズ
                Stop-Job -Job $job; Remove-Job -Job $job -Force
                [Console]::Error.WriteLine("⚠ オートを有効にできません: agy の隔離チェックに失敗しました。")
                [Console]::Error.WriteLine("  → 安全のため通常モード(--sandbox のみ)で起動します。")
            } else {
                $jobRc = Receive-Job -Job $job
                Remove-Job -Job $job -Force
                # M-3: Receive-Job は配列を返すことがあるため末尾要素を整数として取得する。
                # フェイルクローズ方向: 末尾が 0 のときだけ green に解放する。
                if (@($jobRc)[-1] -eq 0) {
                    $isolationOk = $true
                } else {
                    # (d) 非0終了 → フェイルクローズ
                    [Console]::Error.WriteLine("⚠ オートを有効にできません: agy の隔離チェックに失敗しました。")
                    [Console]::Error.WriteLine("  → 安全のため通常モード(--sandbox のみ)で起動します。")
                }
            }
        } catch {
            # (b) 例外 → フェイルクローズ
            [Console]::Error.WriteLine("⚠ オートを有効にできません: agy の隔離チェックに失敗しました。")
            [Console]::Error.WriteLine("  → 安全のため通常モード(--sandbox のみ)で起動します。")
        }
    }
    if ($isolationOk) {
        $autoArgs = @('--dangerously-skip-permissions')
        # 未実証(宣言ベース)であることを必ず表示する(overclaim 回避)。
        [Console]::Error.WriteLine("ℹ オートを有効化しました(agy)。注意: agy の隔離は --sandbox を信頼するもので、")
        [Console]::Error.WriteLine("  Codex のように独立検証(実証・verified)されていません。重要作業では手動承認の利用も検討してください。")
    }
}

$argsList = @("--sandbox", "--add-dir", $Workspace) + $autoArgs

if ($env:AI_SAFE_DRY_RUN -eq '1') {
    Write-Output ("$Agy " + ($argsList -join ' '))
    exit 0
}

if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & $Agy @argsList --prompt $Prompt
} else {
    & $Agy @argsList
}
exit $LASTEXITCODE
