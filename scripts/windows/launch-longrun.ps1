# launch-longrun.ps1 — 「長時間おまかせモード」で AI を起動する（Windows 側の実体）。
#
# ねらい:
#   目を離して AI に長く作業させたいとき、承認ダイアログで止まらずに進める。
#   ただし「全部素通し」にはしない。**その環境で使える最大限の守りを効かせたうえで**、
#   確認だけを省く。
#
# 対応:
#   Claude / Codex / OpenCode / AntiGravity(agy) の 4 つ。
#   （mac 側の実体は scripts/macos/launch-longrun.sh）
#
# 「壁」の有無:
#   壁 = OS が作業フォルダの外への書き込みを強制的に止める仕組み（サンドボックス）。
#     ・Windows の Codex … Codex 純正サンドボックス（--sandbox workspace-write /
#       windows.sandbox=unelevated）→ 壁あり（ただしネット遮断は提供されない）
#     ・Windows の Claude … Claude Code 純正サンドボックスは macOS / Linux / WSL2 のみ
#       対応（公式 https://code.claude.com/docs/en/sandboxing）→ 壁なし
#     ・OpenCode / agy … 壁なし
#   壁がある環境: 内容を表示して Enter で起動。
#   壁が無い環境: **一度だけ確認を取る**。「壁が無いこと」「止まるのは危険コマンドの
#     禁止リストだけであること」を示し、明示的に「はい」と入力してもらってから進む。
#     ※ v1.17.0 までは Windows では理由を出して起動を拒否していた。これは実装側が勝手に
#       安全側へ倒した設計で、依頼者の意図と違ったため v1.17.1 で撤廃した。
#
# どの環境でも外さないもの:
#   - deny 床は 1 本も外さない、disableBypassPermissionsMode: "disable" を維持、
#     記録（hooks / 監査ログ）も外さない、恒久的な設定ファイルは書き換えない。
param(
    [string]$Workspace = "$env:USERPROFILE\Documents\my-ai-workspace",
    [ValidateSet('', 'claude', 'codex', 'opencode', 'agy')]
    [string]$Engine = '',
    [string]$Prompt = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
    Write-Host "作業フォルダが見つかりません: $Workspace"
    exit 2
}
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$root = Join-Path $Workspace '.ai-safety'
$hooks = Join-Path $root 'hooks\windows'
$policy = Join-Path $root 'policy\safety-policy.json'
if (-not (Test-Path -LiteralPath $policy -PathType Leaf)) {
    Write-Host "このフォルダには安全パッケージが入っていません: $Workspace"
    Write-Host "「（上級）14_新しい作業フォルダを安全にする」でこのフォルダを安全にしてから、もう一度実行してください。"
    exit 2
}
$env:AI_SAFE_ROOT = $root
$env:AI_SAFE_POLICY = $policy
if (-not $env:AI_SAFE_LOG_DIR) { $env:AI_SAFE_LOG_DIR = Join-Path $env:USERPROFILE '.ai-safety\logs' }

# 素の Claude（ログイン認証）で動かす。DeepSeek 連携の置き土産を持ち込まない。
Remove-Item Env:\ANTHROPIC_AUTH_TOKEN, Env:\ANTHROPIC_BASE_URL, Env:\ANTHROPIC_MODEL, `
    Env:\ANTHROPIC_DEFAULT_OPUS_MODEL, Env:\ANTHROPIC_DEFAULT_SONNET_MODEL, `
    Env:\ANTHROPIC_DEFAULT_HAIKU_MODEL, Env:\CLAUDE_CODE_SUBAGENT_MODEL, `
    Env:\CLAUDE_CODE_EFFORT_LEVEL, Env:\DS_CLAUDE_MODE -ErrorAction SilentlyContinue

$claudeSettings = Join-Path $Workspace '.claude\settings.json'

# 外部コマンドの呼び出しには必ず上限をかける（`claude -p` が返ってこない事故が過去にある）。
function Invoke-Limited {
    param([int]$TimeoutSec, [string]$File, [string[]]$Arguments)
    $job = Start-Job -ScriptBlock {
        & $using:File @using:Arguments 2>&1 | Out-String
    }
    $done = Wait-Job -Job $job -Timeout $TimeoutSec
    if ($null -eq $done) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return $null
    }
    $out = (Receive-Job -Job $job | Out-String)
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    return $out
}

# 壁（OS のサンドボックス）が効くか。Windows で壁があるのは Codex だけ。
function Test-Wall {
    param([string]$Name)
    if ($Name -eq 'codex') { return $true }
    return $false
}
function Wall-Text { param([string]$Name) if (Test-Wall $Name) { '壁あり' } else { '壁なし' } }
function Engine-Label {
    param([string]$Name)
    switch ($Name) {
        'claude' { 'Claude' }
        'codex' { 'Codex' }
        'opencode' { 'OpenCode' }
        'agy' { 'AntiGravity' }
        default { $Name }
    }
}

if (-not $Engine) {
    Write-Host ''
    Write-Host '════════════════════════════════════════════════════════'
    Write-Host '  長時間おまかせモード（目を離す前提のモードです）'
    Write-Host '════════════════════════════════════════════════════════'
    Write-Host ''
    Write-Host ('  対象の作業フォルダ: ' + (Split-Path -Leaf $Workspace))
    Write-Host ('  （フルパス: ' + $Workspace + '）')
    Write-Host ''
    Write-Host '  どの AI におまかせしますか。番号を入れて Enter を押してください。'
    Write-Host ''
    Write-Host ('    1) Claude       （' + (Wall-Text 'claude') + '）')
    Write-Host ('    2) Codex        （' + (Wall-Text 'codex') + '）')
    Write-Host ('    3) OpenCode     （' + (Wall-Text 'opencode') + '）')
    Write-Host ('    4) AntiGravity  （' + (Wall-Text 'agy') + '）')
    Write-Host ''
    Write-Host '    0) やめる'
    Write-Host ''
    Write-Host '  ※「壁」= OS が作業フォルダの外への書き込みを止める仕組みです。'
    Write-Host '    壁が無いものを選んだ場合は、このあと確認が 1 回出ます。'
    Write-Host ''
    $choice = Read-Host '番号'
    switch ($choice) {
        '1' { $Engine = 'claude' }
        '2' { $Engine = 'codex' }
        '3' { $Engine = 'opencode' }
        '4' { $Engine = 'agy' }
        '0' { Write-Host 'やめました。'; exit 0 }
        default { Write-Host 'やめました。'; exit 0 }
    }
}

$wall = Test-Wall $Engine

Write-Host ''
Write-Host '════════════════════════════════════════════════════════'
Write-Host ('  長時間おまかせモード / ' + (Engine-Label $Engine))
Write-Host '════════════════════════════════════════════════════════'
Write-Host ''
Write-Host ('  対象の作業フォルダ: ' + (Split-Path -Leaf $Workspace))
Write-Host ('  （フルパス: ' + $Workspace + '）')
Write-Host ''

if ($wall) {
    Write-Host '  この環境には「壁」があります。'
    Write-Host '  承認を省けるのは、Codex 純正サンドボックスが'
    Write-Host '    ・作業フォルダの外への書き込み'
    Write-Host '  を OS の力で止めているからです。'
    Write-Host '  （Windows の Codex サンドボックスはネットの遮断までは行いません。'
    Write-Host '    外へ出す操作は危険コマンドの禁止リストと記録で見ています。）'
} else {
    Write-Host '  ⚠ この環境には「壁」がありません。'
    Write-Host '  壁（OS による書き込み制限）が使えないため、AI が作業フォルダの外の'
    Write-Host '  ファイルを書き換えることを OS の力で止めることはできません。'
    Write-Host '  止まるのは危険コマンドの禁止リストだけです。'
}
Write-Host ''
Write-Host '  それでも止まるもの（外していません）:'
Write-Host '    ・再帰削除（rm -rf など）'
Write-Host '    ・秘密ファイルの読み取り（.env / SSH 鍵 / クラウドの資格情報）'
Write-Host '    ・ダウンロードしたものをそのまま実行する形'
Write-Host '    ・sudo / git push / git reset / git checkout / git restore / git rebase'
Write-Host '    ・「全部素通しモード」への切り替えそのもの'
Write-Host '  記録（見張りと監査ログ）は、どの環境でも残ります。'
Write-Host ''
Write-Host '  止まらないもの（気をつけてください）:'
Write-Host '    ・作業フォルダの中のファイルの読み取り・書き換え・削除'
if (-not $wall) {
    Write-Host '    ・作業フォルダの外への書き込み（OS では止められません）'
}
Write-Host '    → この作業フォルダに大事なファイルを置かないでください。'
Write-Host '    → 終わったら「6_見守りモニターを起動」や記録で、何をしたか必ず確認してください。'
Write-Host ''

if ($wall) {
    Read-Host '上の内容でよければ Enter、やめるなら Ctrl+C を押してください' | Out-Null
} else {
    # 壁が無い環境では、一度だけ明示的な同意を取る（依頼者の裁定）。
    Write-Host '  この環境には壁（OS による書き込み制限）がありません。'
    Write-Host '  止まるのは危険コマンドの禁止リストだけです。'
    Write-Host '  目を離す前提で続けますか。'
    Write-Host ''
    $consent = Read-Host '  続けるなら「はい」と入力して Enter（やめるなら Enter だけ）'
    if ($consent -notin @('はい', 'ハイ', 'はい。', 'yes', 'Yes', 'YES', 'y', 'Y')) {
        Write-Host ''
        Write-Host 'やめました。'
        exit 0
    }
    Write-Host ''
}

Write-Host '長時間おまかせモードで起動します。'
Write-Host ''

Set-Location -LiteralPath $Workspace

$powerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
if (-not $powerShell) { $powerShell = Get-Command pwsh -ErrorAction SilentlyContinue }
if (-not $powerShell) { Write-Host 'PowerShell が見つかりません。'; exit 1 }

if ($Engine -eq 'codex') {
    & (Join-Path $hooks 'launch-codex-safe.ps1') -Workspace $Workspace -Prompt $Prompt -LongRun
    exit $LASTEXITCODE
}
if ($Engine -eq 'agy') {
    & (Join-Path $hooks 'launch-agy-safe.ps1') -Workspace $Workspace -Prompt $Prompt -LongRun
    exit $LASTEXITCODE
}
if ($Engine -eq 'opencode') {
    # OpenCode は統合ランチャー経由（見守りモニターと送信検査ゲートウェイが一緒に立つ）。
    & (Join-Path $hooks 'launch-integrated.ps1') -Workspace $Workspace -Agent opencode -SafetyProfile standard -LongRun
    exit $LASTEXITCODE
}

# --- ここから Claude 専用の経路 -------------------------------------------------------
# 恒久的な設定ファイルは書き換えない。このモード用の差分だけを当てた JSON を一時フォルダへ
# 書き出し、`claude --settings <一時ファイル>` で渡す。終了時に必ず消す。
if (-not (Test-Path -LiteralPath $claudeSettings -PathType Leaf)) {
    Write-Host "この作業フォルダに Claude の安全設定がありません: $claudeSettings"
    Write-Host '「8_安全パッケージを最新版に更新」を実行して設定を入れ直してください。'
    exit 2
}
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Host 'node コマンドが見つかりません（このモードの設定づくりに必要です）。'
    Write-Host '先に Node.js（LTS 版）を入れてください。'
    exit 1
}
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeCmd) {
    Write-Host 'claude コマンドが見つかりません。'
    Write-Host '先に Claude Code をインストールしてください（例: npm install -g @anthropic-ai/claude-code@latest）。'
    exit 1
}

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ai-safe-longrun-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$tmpSettings = Join-Path $tmpDir 'settings.json'
try {
    # Windows には壁が無いので sandbox 節は足さない（宣言だけして守れているように見せない）。
    # ask は空にし、そこにあったものは deny 側へ寄せる。緩める方向へは動かさない。
    $builder = @'
const fs = require("fs");
const src = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const p = src.permissions || (src.permissions = {});
const ask = Array.isArray(p.ask) ? p.ask : [];
const deny = Array.isArray(p.deny) ? p.deny.slice() : [];
for (const rule of ask) if (!deny.includes(rule)) deny.push(rule);
p.ask = [];
p.deny = deny;
p.defaultMode = "acceptEdits";
p.disableBypassPermissionsMode = "disable";
fs.writeFileSync(process.argv[2], JSON.stringify(src, null, 2));
'@
    $builderFile = Join-Path $tmpDir 'build-settings.js'
    [System.IO.File]::WriteAllText($builderFile, $builder, (New-Object System.Text.UTF8Encoding($false)))
    & $node.Source $builderFile $claudeSettings $tmpSettings
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpSettings -PathType Leaf)) {
        Write-Host 'このモード用の設定を作れませんでした。'
        exit 1
    }

    $claudeArgs = @('--settings', $tmpSettings, '--setting-sources', 'user,project,local')
    # `claude --help` が返ってこない事故が過去にあったので、上限 30 秒で打ち切る。
    # 打ち切られた場合は --permission-mode を付けない（設定側の defaultMode で足りる）。
    $help = Invoke-Limited -TimeoutSec 30 -File $claudeCmd.Source -Arguments @('--help')
    if ($help -and $help.Contains('--permission-mode')) {
        $claudeArgs = @('--permission-mode', 'acceptEdits') + $claudeArgs
    }

    Write-Host '（終了すると一時設定は自動で消えます）'
    Write-Host ''

    if ($Prompt -and $Prompt.Trim().Length -gt 0) {
        & $claudeCmd.Source @claudeArgs $Prompt
    } else {
        & $claudeCmd.Source @claudeArgs
    }
    exit $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
