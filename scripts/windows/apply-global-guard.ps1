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
#
# hook が呼ぶ guard の置き場（v1.19.x〜）:
#   以前は作業フォルダの中 (<ws>\.ai-safety\hooks\windows\guard-*.ps1) を絶対パスで指していた。
#   hook はスクリプトが見つからないと安全側に倒して exit 2 するため、作業フォルダを移動・名前変更
#   すると、この PC のすべての Claude セッションが止まっていた。そこで反映の前に guard 一式を
#   %USERPROFILE%\.ai-safety\global\ へ複製し（scripts\common\stage-global-runtime.js）、hook は
#   そちらを指す。古い版で入れた「作業フォルダを指す hook」は、反映のたびに張り替わる。
#
# 使い方:
#   apply-global-guard.ps1          … 「キーと金庫\12」から。内容を見せて確認してから入れる。
#                                      以前「13」で解除した記録 (~\.ai-safety\global-guard-optout) は消す。
#   apply-global-guard.ps1 -Auto    … install.ps1（導入・更新）から。確認なしで入れ、短い案内だけ出す。
#                                      解除の記録があるとき・AI_SAFE_NO_GLOBAL_GUARD=1 のときは何もしない。
#   apply-global-guard.ps1 -DryRun  … 何も書かずに、入れる内容だけ表示する。
#
# 既存設定は壊さない(union / 管理キーのみ)。反映前に自動バックアップ。取り消しは
# uninstall-global-guard.ps1 で元へ戻せる。実体マージは node (scripts/common/apply-global-*.js)。
param([switch]$DryRun, [switch]$Yes, [switch]$Auto)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# 配置: <workspace>\.ai-safety\hooks\windows\apply-global-guard.ps1
$workspace = (Resolve-Path (Join-Path $here "..\..\..")).Path
$common = Join-Path $here "..\common"
$claudeJs   = Join-Path $common "apply-global-guard.js"
$codexJs    = Join-Path $common "apply-global-codex.js"
$agyJs      = Join-Path $common "apply-global-agy.js"
$opencodeJs = Join-Path $common "apply-global-opencode.js"
$stageJs    = Join-Path $common "stage-global-runtime.js"

$src = if ($env:AI_SAFE_DENY_SRC) { $env:AI_SAFE_DENY_SRC } else { Join-Path $workspace ".claude\settings.json" }
$claudeTarget = if ($env:AI_SAFE_GLOBAL_CLAUDE) { $env:AI_SAFE_GLOBAL_CLAUDE } else { Join-Path $HOME ".claude\settings.json" }
$codexConfig  = if ($env:AI_SAFE_GLOBAL_CODEX) { $env:AI_SAFE_GLOBAL_CODEX } else { Join-Path $HOME ".codex\config.toml" }
$codexHooks   = if ($env:AI_SAFE_GLOBAL_CODEX_HOOKS) { $env:AI_SAFE_GLOBAL_CODEX_HOOKS } else { Join-Path $HOME ".codex\hooks.json" }
$agyTarget    = if ($env:AI_SAFE_GLOBAL_AGY) { $env:AI_SAFE_GLOBAL_AGY } else { Join-Path $HOME ".gemini\settings.json" }
$opencodeDir  = if ($env:AI_SAFE_GLOBAL_OPENCODE_DIR) { $env:AI_SAFE_GLOBAL_OPENCODE_DIR } elseif ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME "opencode" } else { Join-Path $HOME ".config\opencode" }
# guard 一式の固定の置き場。hook はここを指す（作業フォルダの場所に依存しない）。
$globalRuntime = Join-Path $HOME ".ai-safety\global"
$guardDir = Join-Path $globalRuntime "hooks\windows"
# 「13_PC全体の安全設定を解除」を押した記録。あれば導入・更新のたびに入れ直すことはしない。
$optoutMarker = Join-Path $HOME ".ai-safety\global-guard-optout"
$stateArgs = @()
if ($env:AI_SAFE_GLOBAL_STATE) { $stateArgs = @("--state", $env:AI_SAFE_GLOBAL_STATE) }
$dryArgs = @()
if ($DryRun) { $dryArgs = @("--dry-run") }

if ($Auto) {
    if ($env:AI_SAFE_NO_GLOBAL_GUARD -eq "1") {
        Write-Host "PC 全体の安全設定: AI_SAFE_NO_GLOBAL_GUARD=1 のため入れませんでした。"
        exit 0
    }
    if (Test-Path -LiteralPath $optoutMarker) {
        Write-Host "PC 全体の安全設定: 以前「13_PC全体の安全設定を解除」で解除されているため、入れ直していません。"
        exit 0
    }
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error "node が見つかりません。Node.js を入れてから実行してください。"
    exit 2
}
if (-not (Test-Path -LiteralPath $src)) {
    Write-Error "deny の元設定が見つかりません: $src`n  → 先に「1_安全パッケージを準備」を実行してください。"
    exit 2
}
foreach ($js in @($claudeJs, $codexJs, $agyJs, $opencodeJs, $stageJs)) {
    if (-not (Test-Path -LiteralPath $js)) {
        Write-Error "反映スクリプトが見つかりません: $js`n  → 先に「1_安全パッケージを準備」を実行してください。"
        exit 2
    }
}

# ---- 実行前の「何を・どこに入れるか」一覧 --------------------------------
$ocTarget = Join-Path $opencodeDir "opencode.json"
if (Test-Path -LiteralPath (Join-Path $opencodeDir "opencode.jsonc")) { $ocTarget = Join-Path $opencodeDir "opencode.jsonc" }

if (-not $Auto) {
    Write-Host "この PC の「全体設定」に、次の内容を入れます。"
    Write-Host "（どのフォルダから AI を起動しても最低限の安全が効くようにする設定です。"
    Write-Host "  安全パッケージを導入・更新すると、最初からこの設定が入ります。）"
    Write-Host ""
    Write-Host " 1) Claude Code   -> $claudeTarget"
    Write-Host "      危険コマンドの禁止リスト（再帰削除 / .env の読み取り / 外部への送信など）と、"
    Write-Host "      安全ガードの呼び出しを追加します。"
    Write-Host ""
    Write-Host " 2) Codex         -> $codexConfig"
    Write-Host "                    $codexHooks"
    Write-Host "      承認の求め方（on-request）・二次レビュー（auto_review）・"
    Write-Host "      作業フォルダ外への書き込み禁止（sandbox_mode = workspace-write）・"
    Write-Host "      API キーを子プロセスに渡さない設定を入れます。通信は開けたままにします。"
    Write-Host "      ※ Codex のデスクトップアプリも同じ config.toml を読むので、アプリにも同時に効きます。"
    Write-Host ""
    Write-Host " 3) agy / Gemini  -> $agyTarget"
    Write-Host "      安全ガードの呼び出しを追加します。"
    Write-Host ""
    Write-Host " 4) OpenCode      -> $ocTarget"
    Write-Host "      危険コマンドの禁止（rm / sudo / git reset --hard）と、"
    Write-Host "      確認を挟むコマンド（git push / npm publish / 他エージェントの起動 など）を追加します。"
    Write-Host ""
    Write-Host ("・安全ガードの本体は " + $globalRuntime + " に置きます。")
    Write-Host "  作業フォルダを移動したり名前を変えたりしても、この設定は効き続けます。"
    Write-Host "・既存の設定は壊しません（安全に関係のない項目は 1 つも変えません）。"
    Write-Host "・書き込む前に ~\.ai-safety\backups\ へ自動でバックアップを取ります。"
    Write-Host "・元に戻したいときは「キーと金庫\13_PC全体の安全設定を解除」を実行してください。"
}

$skipConfirm = $DryRun -or $Yes -or $Auto -or ($env:AI_SAFE_ASSUME_YES -eq "1") -or (-not [Environment]::UserInteractive)
if (-not $skipConfirm) {
    Write-Host ""
    $ans = Read-Host "この内容で入れますか？ [y/N]"
    if ($ans -notmatch '^(y|Y|yes|YES)$') {
        Write-Host "中止しました。設定は 1 つも変更していません。"
        exit 0
    }
}

# ---- 自分で入れ直したので「解除した」記録を消す ----------------------------
# 12 を押す＝PC 全体の安全設定を使うという意思表示。今後の導入・更新でも入れ直すようにする。
if ((-not $Auto) -and (-not $DryRun) -and (Test-Path -LiteralPath $optoutMarker)) {
    try {
        Remove-Item -LiteralPath $optoutMarker -Force
        Write-Host ""
        Write-Host "以前の「解除した」記録を消しました。これからは安全パッケージの更新のたびに、この設定を入れ直します。"
    } catch {
        Write-Warning ("解除した記録を消せませんでした: " + $optoutMarker)
    }
}

# ---- guard 一式を固定の置き場へ複製（hook はここを指す） ---------------------
# node の出力は ASCII だけ（Windows PowerShell 5.1 のコンソールで UTF-8 が化けるため）。
# 標準エラーはリダイレクトしない（5.1 はリダイレクトした標準エラーを NativeCommandError にする）。
if ($DryRun) {
    Write-Host ""
    Write-Host ("[dry-run] 安全ガードの本体を " + $globalRuntime + " に置き直します（今回は書き込みません）。")
} else {
    $global:LASTEXITCODE = 0
    if ($Auto) {
        & node $stageJs --os windows --guard-src $here --dest $globalRuntime | Out-Null
    } else {
        Write-Host ""
        Write-Host ("-- 0) 安全ガードの本体を置く（" + $globalRuntime + "） ------")
        & node $stageJs --os windows --guard-src $here --dest $globalRuntime
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Error ("安全ガードの本体を " + $globalRuntime + " に置けませんでした（上のメッセージを確認してください）。全体設定は 1 つも変更していません。")
        exit 2
    }
}

# ---- 反映 ---------------------------------------------------------------
$script:rc = 0
$script:status = @()
# exit 3 = 「壊れた設定なので触らずスキップ」。失敗ではないので rc は上げない。
# -Auto のときは各エンジンの詳細を出さず、最後に 1 行ずつまとめて表示する。
function Invoke-Engine {
    param([string]$Label, [string[]]$EngineArgs)
    $global:LASTEXITCODE = 0
    if ($Auto) {
        & node @EngineArgs | Out-Null
    } else {
        & node @EngineArgs
    }
    $code = $LASTEXITCODE
    if ($code -eq 3) {
        if (-not $Auto) { Write-Host "  -> スキップしました（既存の設定ファイルを安全に読めないため）。" }
        $script:status += ("  ・" + $Label + ": スキップ（既存の設定ファイルを安全に読めないため触っていません）")
    } elseif ($code -ne 0) {
        $script:rc = 1
        $script:status += ("  ・" + $Label + ": 失敗（上のメッセージを確認してください）")
    } else {
        $script:status += ("  ・" + $Label + ": 反映しました")
    }
}

if (-not $Auto) { Write-Host ""; Write-Host "-- 1) Claude Code の全体設定に反映 -----------------------" }
Invoke-Engine "Claude Code  (~\.claude\settings.json)" (@($claudeJs, "apply", "--source", $src, "--target", $claudeTarget, "--os", "windows", "--guard-dir", $guardDir) + $stateArgs + $dryArgs)

if (-not $Auto) { Write-Host ""; Write-Host "-- 2) Codex の全体設定に反映 -----------------------------" }
Invoke-Engine "Codex        (~\.codex\config.toml と hooks.json。デスクトップアプリにも効きます)" (@($codexJs, "apply", "--config-target", $codexConfig, "--hooks-target", $codexHooks, "--os", "windows", "--guard-dir", $guardDir) + $stateArgs + $dryArgs)
if (-not $Auto) {
    Write-Host "  ※ Codex の guard hook を発火させるには、一度だけ codex を起動して /hooks で信頼してください。"
    Write-Host "     常時有効な保護(サンドボックス・承認・APIキー除外)は上の config.toml で決定的に効きます。"
    Write-Host "     この config.toml は Codex デスクトップアプリも読むので、アプリ側にも同時に効きます。"
}

if (-not $Auto) { Write-Host ""; Write-Host "-- 3) agy / Gemini の全体設定に反映 ----------------------" }
Invoke-Engine "agy / Gemini (~\.gemini\settings.json)" (@($agyJs, "apply", "--target", $agyTarget, "--os", "windows", "--guard-dir", $guardDir) + $stateArgs + $dryArgs)

if (-not $Auto) { Write-Host ""; Write-Host "-- 4) OpenCode の全体設定に反映 --------------------------" }
Invoke-Engine "OpenCode     (~\.config\opencode\opencode.json)" (@($opencodeJs, "apply", "--config-dir", $opencodeDir) + $stateArgs + $dryArgs)

if ($Auto) {
    Write-Host ""
    Write-Host "-- PC 全体の安全設定（最初から入っています） ---------------"
    Write-Host "この PC のどのフォルダから AI を起動しても、危険な操作（再帰削除・.env の読み取り・外部への送信など）が"
    Write-Host "止まるように、次の全体設定を更新しました（変更前の状態は ~\.ai-safety\backups\ に保存済み）。"
    foreach ($line in @($script:status)) { Write-Host $line }
    Write-Host "  安全ガードの本体は ~\.ai-safety\global\ にあるので、作業フォルダを移動しても効き続けます。"
    Write-Host "  やめたいとき: スタート\キーと金庫\13_PC全体の安全設定を解除（次の更新からも入れ直しません）"
}

exit $script:rc
