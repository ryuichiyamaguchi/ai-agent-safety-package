param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = "",
    [string]$AutoFlag = ""   # "--auto" を受け取る位置引数。Safe Auto Mode を有効化する。
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$env:AI_SAFE_ROOT = Join-Path $Workspace ".ai-safety"
$env:AI_SAFE_POLICY = Join-Path $env:AI_SAFE_ROOT "policy\safety-policy.json"
$env:AI_SAFE_LOG_DIR = Join-Path $HOME ".ai-safety\logs"

# A-1: CODEX_HOME は workspace 外 (HOME/.codex-safe) を向かせる。
# auth.json を workspace ツリーに物理コピーしないことで
# git add / OneDrive 同期 / workspace zip 化による平文流出を防ぐ。
$safeCodexHome = Join-Path $HOME ".codex-safe"
if (-not (Test-Path -LiteralPath $safeCodexHome)) {
    New-Item -ItemType Directory -Force -Path $safeCodexHome | Out-Null
}
$env:CODEX_HOME = $safeCodexHome

# workspace 内 .codex/ に config.toml が置かれている場合は .codex-safe/ へコピーして使う。
# auth.json は絶対にコピーしない。
# codex 0.135 fix: 旧版が置いた legacy config.toml (`[profiles.safe]` 入り) が .codex-safe/ に
# 残っていると --profile safe と衝突して fatal error になる。SSOT は workspace の
# .codex\config.toml (install が管理する新版) なので、safe.config.toml と同じく毎回上書きして
# 常に最新を反映させる ("既存ならスキップ" は legacy が永久に残る罠だったため撤廃)。
$workspaceCodexConfigSrc = Join-Path $Workspace ".codex\config.toml"
$safeCodexConfig = Join-Path $safeCodexHome "config.toml"
if (Test-Path -LiteralPath $workspaceCodexConfigSrc) {
    Copy-Item -LiteralPath $workspaceCodexConfigSrc -Destination $safeCodexConfig -Force
}

# codex 0.135: `--profile safe` が参照する $CODEX_HOME/safe.config.toml も配置する。
# (config.toml に `[profiles.safe]` を残すと 0.135 では起動が fatal error になるため分離済み。)
# config.toml が更新されたら safe.config.toml も追従させたいので、毎回上書きコピーする。
$workspaceSafeProfile = Join-Path $Workspace ".codex\safe.config.toml"
$safeCodexProfile = Join-Path $safeCodexHome "safe.config.toml"
if (Test-Path -LiteralPath $workspaceSafeProfile) {
    Copy-Item -LiteralPath $workspaceSafeProfile -Destination $safeCodexProfile -Force
}

# Hook trust 自動付与 (codex 0.135+ 対応・最重要) — mac launch-codex-safe.sh と同型。
# codex 0.135 以降は信頼していないフックを黙ってスキップするため、受講者が /hooks を手動で
# 信頼するまで guard が一切発火せず見守りモニターも無反応になる。launcher が起動のたびに
# 同梱フックの trusted_hash を safe.config.toml の [hooks.state] に注入して最初から Active にする。
# - trusted_hash はフックのコマンド内容由来で workspace パスに依存しない。
# - Windows の値は mac codex に hooks.windows.json を読ませて採取した暫定値。
#   Windows 実機の codex がキーをどの区切り (\ か /)・どの正規化で書くかは未確認なので、
#   実機検証で /hooks の Active を確認し、ずれていれば codex が書く [hooks.state] の
#   書式に合わせてここを調整すること (runbook 参照)。
# - IMPORTANT: hooks.windows.json を変更したらこのハッシュ表も再採取して更新する。
$hooksJson = Join-Path $Workspace ".codex\hooks.json"
if ((Test-Path -LiteralPath $hooksJson) -and (Test-Path -LiteralPath $safeCodexProfile)) {
    # TOML basic string 用に \ を \\ にエスケープする (Windows パス区切り対策)。
    $tomlPath = $hooksJson -replace '\\', '\\'
    $hookEntries = @(
        @('pre_tool_use:0:0',      '7cd5817d3031a107271994456a15b400232360984668dd261559283b75bb9780'),
        @('pre_tool_use:1:0',      'f55891da00eaa094a3c770c7227882a7bba69482fd93fd2e1ca08391e60ad7aa'),
        @('pre_tool_use:2:0',      'a7ecf1e0d05fd8ef0d4dc06b5891d4b0b4bc4f6f6711b895a4b11c737d3392cc'),
        @('post_tool_use:0:0',     'f2a4a55a367c421547ff81ced29b5406a7556a1e71759003d6e6eccdecfb7827'),
        @('user_prompt_submit:0:0','a254ae6612f7de19f6342536d0cc57699d2e345e6f0ad01bc899811caf951407')
    )
    $stateLines = @('', '[hooks.state]')
    foreach ($e in $hookEntries) {
        $stateLines += ('[hooks.state."{0}:{1}"]' -f $tomlPath, $e[0])
        $stateLines += ('trusted_hash = "sha256:{0}"' -f $e[1])
    }
    Add-Content -LiteralPath $safeCodexProfile -Value ($stateLines -join "`r`n")
}

if (-not (Test-Path -LiteralPath $env:AI_SAFE_POLICY)) {
    throw "AI Safety package is not installed in workspace: $Workspace"
}
if ($env:AI_SAFE_DRY_RUN -ne '1' -and -not (Test-Path -LiteralPath $safeCodexConfig)) {
    throw "Codex safety config was not found: $safeCodexConfig"
}

# auth.json は $HOME\.codex\auth.json をそのまま参照させる。
# SymbolicLink が使える環境ではリンクを張る。使えない環境では
# CODEX_HOME=$HOME\.codex-safe のまま Codex が $HOME\.codex の auth を探す。
# いずれにせよ workspace ツリーへの物理コピーはしない。
$srcAuth = Join-Path $HOME ".codex\auth.json"
$safeCodexAuth = Join-Path $safeCodexHome "auth.json"

if ($env:AI_SAFE_DRY_RUN -ne '1' -and -not (Test-Path -LiteralPath $srcAuth)) {
    throw "Codex auth not found at $srcAuth. Please run 'codex login' first."
}

# A-1: workspace 内 .codex/auth.json に物理コピーが残っている場合は削除する (旧バージョン残骸)。
$legacyAuth = Join-Path $Workspace ".codex\auth.json"
if (Test-Path -LiteralPath $legacyAuth) {
    $legacyItem = Get-Item -LiteralPath $legacyAuth -Force
    $isLink = $false
    if ($legacyItem.PSObject.Properties.Name -contains 'LinkType') {
        $isLink = [bool]$legacyItem.LinkType
    }
    if (-not $isLink) {
        Write-Warning "A-1: Removing legacy physical auth.json from workspace tree: $legacyAuth"
        Remove-Item -LiteralPath $legacyAuth -Force
    }
}

# .codex-safe/ に auth.json がなければ HOME\.codex\auth.json へのシンボリックリンクを試みる。
# 失敗しても CODEX_HOME を $HOME\.codex に切り替えて動作継続する (物理コピー禁止)。
# DRY_RUN 時は実ファイル操作をスキップする(テスト用)。
if ($env:AI_SAFE_DRY_RUN -ne '1' -and -not (Test-Path -LiteralPath $safeCodexAuth)) {
    $linkCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $safeCodexAuth -Target $srcAuth -ErrorAction Stop | Out-Null
        $linkCreated = $true
    } catch {
        Write-Warning "SymbolicLink creation failed ($($_.Exception.Message)). Using HOME\.codex directly."
    }
    if (-not $linkCreated) {
        # フォールバック: CODEX_HOME を元の HOME\.codex に戻す。workspace には何も置かない。
        $env:CODEX_HOME = Join-Path $HOME ".codex"
    }
}

# Safe Auto Mode: --auto かつ doctor の隔離チェックが green のときだけ承認を下げる。
# Windows 方針(ユーザー承認 2026-06-22): Windows codex 0.135 の sandbox はネットワーク隔離を
# 提供しない(Test-NetworkEgress が構造的に必ず FAIL し、かつネット接続プローブで起動前に数十秒
# フリーズ=「オートが起動しない」の真因)。そこで Windows のオートは doctor の 'codex-fileonly'
# (ファイル隔離 Test-WriteOutside のみ)で判定し、ネット送信の隔離は承認任せとする割り切り。
# mac(launch-codex-safe.sh)は seatbelt がネット隔離するので従来どおり ①② で判定(変更しない)。
# フェイルクローズ設計:
#   (a) doctor パスが存在しない → Test-Path で弾く → untrusted
#   (b) doctor 呼び出しで例外発生 → try/catch で捕捉 → untrusted
#   (c) doctor がハング → Start-Job + Wait-Job -Timeout 30 で上限 30 秒 → untrusted
#   (d) doctor が非0終了 → $LASTEXITCODE != 0 → untrusted
# green(on-failure)は「doctor が確かに走って exit 0 を返したときだけ」。
$approval = 'untrusted'
if ($AutoFlag -eq '--auto') {
    $doctorPath = if ($env:AI_SAFE_DOCTOR) { $env:AI_SAFE_DOCTOR } else { Join-Path $PSScriptRoot 'doctor.ps1' }
    $isolationOk = $false
    if (-not (Test-Path -LiteralPath $doctorPath -ErrorAction SilentlyContinue)) {
        # (a) doctor ファイル不在 → フェイルクローズ
        [Console]::Error.WriteLine("⚠ オートを有効にできません: doctor が見つかりません ($doctorPath)")
        [Console]::Error.WriteLine("  → 安全のため都度承認モードで起動します。直すには doctor を配置してください。")
    } else {
        # フリーズに見えないよう「確認中」を明示する(codex sandbox を起動して実証するため数秒かかる)。
        [Console]::Error.WriteLine("🔍 OS 隔離(ファイル金庫)を確認しています…数秒お待ちください。")
        # doctor を Start-Job で起動しタイムアウト上限 30 秒で呼ぶ。
        # codex-fileonly はファイル隔離のみなので 'codex'(①②)より軽く速い。
        # (b)(c) 例外・ハング どちらもフェイルクローズ。
        try {
            $isCmdFile = $doctorPath -match '\.(cmd|bat)$'
            $job = if ($isCmdFile) {
                Start-Job -ScriptBlock { & cmd.exe /c $using:doctorPath *> $null; $LASTEXITCODE }
            } else {
                Start-Job -ScriptBlock {
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $using:doctorPath -IsolationCheck codex-fileonly *> $null
                    $LASTEXITCODE
                }
            }
            $completed = Wait-Job -Job $job -Timeout 30
            if ($null -eq $completed) {
                # タイムアウト (c) → フェイルクローズ
                Stop-Job -Job $job; Remove-Job -Job $job -Force
                [Console]::Error.WriteLine("⚠ オートを有効にできません: doctor が 60 秒以内に応答しませんでした。")
                [Console]::Error.WriteLine("  → 安全のため都度承認モードで起動します。直すには doctor を実行してください。")
            } else {
                $jobRc = Receive-Job -Job $job
                Remove-Job -Job $job -Force
                # M-3: Receive-Job は配列を返すことがあるため末尾要素を整数として取得する。
                # フェイルクローズ方向: 末尾が 0 のときだけ green に解放する。
                if (@($jobRc)[-1] -eq 0) {
                    $isolationOk = $true
                } else {
                    # (d) 非0終了 → フェイルクローズ
                    [Console]::Error.WriteLine("⚠ オートを有効にできません: OS 隔離(金庫)を確認できませんでした。")
                    [Console]::Error.WriteLine("  → 安全のため都度承認モードで起動します。直すには doctor を実行してください。")
                }
            }
        } catch {
            # (b) 例外 → フェイルクローズ
            [Console]::Error.WriteLine("⚠ オートを有効にできません: doctor 呼び出しでエラーが発生しました: $($_.Exception.Message)")
            [Console]::Error.WriteLine("  → 安全のため都度承認モードで起動します。直すには doctor を実行してください。")
        }
    }
    if ($isolationOk) {
        $approval = 'on-failure'
    }
}

# A-2: hooks 有効化フラグを launcher 側でも明示渡し。
# config.toml の features.hooks=true と合わせて二重保証する。
$argsList = @(
    "--cd", $Workspace,
    "--profile", "safe",
    "--sandbox", "workspace-write",
    "--ask-for-approval", $approval,
    "-c", "windows.sandbox=`"unelevated`"",
    "-c", "features.hooks=true"
)

if ($env:AI_SAFE_DRY_RUN -eq '1') {
    Write-Output ("codex " + ($argsList -join ' '))
    exit 0
}

# codex バイナリ検出（PATH に無くても npm グローバル等から見つける）。
# npm install -g @openai/codex は Windows で %APPDATA%\npm\codex.cmd に入る。
$Codex = $env:CODEX_BIN
if (-not $Codex) {
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd) { $Codex = $cmd.Source }
}
if (-not $Codex) {
    foreach ($c in @(
        (Join-Path $env:APPDATA "npm\codex.cmd"),
        (Join-Path $env:APPDATA "npm\codex"),
        (Join-Path $env:USERPROFILE ".local\bin\codex.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\codex")
    )) { if ($c -and (Test-Path -LiteralPath $c)) { $Codex = $c; break } }
}
if (-not $Codex) {
    Write-Host "codex コマンドが見つかりません。"
    Write-Host "「0_AIツールをまとめて入れる-Windows.bat」を実行したか、'npm install -g @openai/codex' を確認してください。"
    Write-Host "（場所を手動指定する場合は環境変数 CODEX_BIN にフルパスを設定）"
    exit 1
}

if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & $Codex @argsList $Prompt
} else {
    & $Codex @argsList
}
exit $LASTEXITCODE
