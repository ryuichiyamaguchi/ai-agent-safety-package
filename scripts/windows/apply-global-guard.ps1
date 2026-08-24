# apply-global-guard.ps1 — この PC の「全体設定」に、4 エンジン分の最低限の安全設定を入れる。
#   Claude Code (%USERPROFILE%\.claude\settings.json):
#     permissions.deny を union し、guard の絶対パスを指す hooks を追加。どのフォルダから claude を
#     起動しても rm -r / cat .env / curl|sh 等をブロックする。
#   Codex (%USERPROFILE%\.codex\config.toml + hooks.json):
#     approval_policy=on-request / approvals_reviewer=auto_review / sandbox_mode=workspace-write /
#     shell_environment_policy.exclude(APIキー) 等の決定的保護を反映(常時有効)。guard の絶対パス
#     hooks も配線する(発火には codex の /hooks で一度だけ信頼が要る)。
#     ※ Codex のデスクトップアプリも同じ config.toml を読むため、アプリ側にも同時に効く。
#   agy / Gemini CLI (%USERPROFILE%\.gemini\settings.json):
#     guard の絶対パス hooks を配線する。
#   OpenCode (%USERPROFILE%\.config\opencode\opencode.json):
#     permission.bash の最小 deny / ask を反映する(OpenCode には hook 層が無いため)。
# 既存設定は壊さない(union / 管理キーのみ)。反映前に自動バックアップ。取り消しは
# uninstall-global-guard.ps1 で元へ戻せる。実体マージは node (scripts/common/apply-global-*.js)。
param([switch]$DryRun, [switch]$Yes)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# 配置: <workspace>\.ai-safety\hooks\windows\apply-global-guard.ps1
$workspace = (Resolve-Path (Join-Path $here "..\..\..")).Path
$guardDir = $here
$common = Join-Path $here "..\common"
$claudeJs   = Join-Path $common "apply-global-guard.js"
$codexJs    = Join-Path $common "apply-global-codex.js"
$agyJs      = Join-Path $common "apply-global-agy.js"
$opencodeJs = Join-Path $common "apply-global-opencode.js"

$src = if ($env:AI_SAFE_DENY_SRC) { $env:AI_SAFE_DENY_SRC } else { Join-Path $workspace ".claude\settings.json" }
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
if (-not (Test-Path -LiteralPath $src)) {
    Write-Error "deny の元設定が見つかりません: $src`n  → 先に「1_安全パッケージを準備」を実行してください。"
    exit 2
}
foreach ($js in @($claudeJs, $codexJs, $agyJs, $opencodeJs)) {
    if (-not (Test-Path -LiteralPath $js)) {
        Write-Error "反映スクリプトが見つかりません: $js`n  → 先に「1_安全パッケージを準備」を実行してください。"
        exit 2
    }
}

# ---- 実行前の「何を・どこに入れるか」一覧 --------------------------------
$ocTarget = Join-Path $opencodeDir "opencode.json"
if (Test-Path -LiteralPath (Join-Path $opencodeDir "opencode.jsonc")) { $ocTarget = Join-Path $opencodeDir "opencode.jsonc" }

Write-Host "この PC の「全体設定」に、次の内容を入れます。"
Write-Host "（どのフォルダから AI を起動しても最低限の安全が効くようにする設定です。）"
Write-Host ""
Write-Host " 1) Claude Code   -> $claudeTarget"
Write-Host "      危険コマンドの禁止リスト（再帰削除 / .env の読み取り / 外部への送信など）と、"
Write-Host "      安全ガードの呼び出し（絶対パス）を追加します。"
Write-Host ""
Write-Host " 2) Codex         -> $codexConfig"
Write-Host "                    $codexHooks"
Write-Host "      承認の求め方（on-request）・二次レビュー（auto_review）・"
Write-Host "      作業フォルダ外への書き込み禁止（sandbox_mode = workspace-write）・"
Write-Host "      API キーを子プロセスに渡さない設定を入れます。通信は開けたままにします。"
Write-Host "      ※ Codex のデスクトップアプリも同じ config.toml を読むので、アプリにも同時に効きます。"
Write-Host ""
Write-Host " 3) agy / Gemini  -> $agyTarget"
Write-Host "      安全ガードの呼び出し（絶対パス）を追加します。"
Write-Host ""
Write-Host " 4) OpenCode      -> $ocTarget"
Write-Host "      危険コマンドの禁止（rm / sudo / git reset --hard）と、"
Write-Host "      確認を挟むコマンド（git push / npm publish / 他エージェントの起動 など）を追加します。"
Write-Host ""
Write-Host "・既存の設定は壊しません（安全に関係のない項目は 1 つも変えません）。"
Write-Host "・書き込む前に ~\.ai-safety\backups\ へ自動でバックアップを取ります。"
Write-Host "・元に戻したいときは「キーと金庫\13_PC全体の安全設定を解除」を実行してください。"

$skipConfirm = $DryRun -or $Yes -or ($env:AI_SAFE_ASSUME_YES -eq "1") -or (-not [Environment]::UserInteractive)
if (-not $skipConfirm) {
    Write-Host ""
    $ans = Read-Host "この内容で入れますか？ [y/N]"
    if ($ans -notmatch '^(y|Y|yes|YES)$') {
        Write-Host "中止しました。設定は 1 つも変更していません。"
        exit 0
    }
}

# ---- 反映 ---------------------------------------------------------------
$script:rc = 0
# exit 3 = 「壊れた設定なので触らずスキップ」。失敗ではないので rc は上げない。
function Invoke-Engine {
    param([string[]]$EngineArgs)
    & node @EngineArgs
    if ($LASTEXITCODE -eq 3) {
        Write-Host "  -> スキップしました（既存の設定ファイルを安全に読めないため）。"
    } elseif ($LASTEXITCODE -ne 0) {
        $script:rc = 1
    }
}

Write-Host ""
Write-Host "-- 1) Claude Code の全体設定に反映 -----------------------"
Invoke-Engine (@($claudeJs, "apply", "--source", $src, "--target", $claudeTarget, "--os", "windows", "--guard-dir", $guardDir) + $stateArgs + $dryArgs)

Write-Host ""
Write-Host "-- 2) Codex の全体設定に反映 -----------------------------"
Invoke-Engine (@($codexJs, "apply", "--config-target", $codexConfig, "--hooks-target", $codexHooks, "--os", "windows", "--guard-dir", $guardDir) + $stateArgs + $dryArgs)
Write-Host "  ※ Codex の guard hook を発火させるには、一度だけ codex を起動して /hooks で信頼してください。"
Write-Host "     常時有効な保護(サンドボックス・承認・APIキー除外)は上の config.toml で決定的に効きます。"
Write-Host "     この config.toml は Codex デスクトップアプリも読むので、アプリ側にも同時に効きます。"

Write-Host ""
Write-Host "-- 3) agy / Gemini の全体設定に反映 ----------------------"
Invoke-Engine (@($agyJs, "apply", "--target", $agyTarget, "--os", "windows", "--guard-dir", $guardDir) + $stateArgs + $dryArgs)

Write-Host ""
Write-Host "-- 4) OpenCode の全体設定に反映 --------------------------"
Invoke-Engine (@($opencodeJs, "apply", "--config-dir", $opencodeDir) + $stateArgs + $dryArgs)

exit $script:rc
