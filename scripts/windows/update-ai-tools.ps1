# update-ai-tools.ps1 — AI ツールをまとめて入れる・更新する（スタート「2_AIツールをまとめて入れる」の実体）。
#
# 対象:
#   - Codex CLI   : npm install -g @openai/codex@latest
#   - Claude Code : npm install -g @anthropic-ai/claude-code@<tested-tool-versions.json の値>
#   - OpenCode    : npm install -g opencode-ai@latest
#   - agy (AntiGravity CLI): 入っていなければ公式インストーラーで入れる。入っていれば
#                   公式の自動更新に任せる（このボタンでは更新しない）
#   - Playwright MCP: d-claude / OpenCode のブラウザ操作の部品を事前に入れる（v1.19.3〜）
#   - Gemini CLI       : 移行済み・対象外
#
# 方針:
#   - 2026-10（v1.19.5）から、入っていないツールも新しく入れる（旧版は「未インストールは
#     スキップ」だった。受講者が 1 つずつ別の手順で入れる手間をなくすため）。
#   - 1 つ失敗しても残りを続行し、最後にまとめを表示する
#   - 管理者権限は要求しない
#   - agy の公式インストーラーは「irm ... | iex」と案内されているが、ここでは HTTPS で一度
#     ファイルに保存してから実行する（途中で切れた内容を実行しない）
param(
    [string]$Workspace = (Get-Location).Path
)
$ErrorActionPreference = "Continue"
$OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AgyInstallUrl = "https://antigravity.google/cli/install.ps1"

function Line($s) { Write-Host $s }

# --- 動作確認済み版の表 (SSOT) を探す ---------------------------------------
# 1) workspace 配置版 (install が .ai-safety\ にコピーする)
# 2) リポジトリ直実行時: <repo>\configs\tested-tool-versions.json
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$versionsJson = $null
foreach ($cand in @(
        (Join-Path $Workspace ".ai-safety\tested-tool-versions.json"),
        (Join-Path $scriptDir "..\..\configs\tested-tool-versions.json")
    )) {
    if (Test-Path -LiteralPath $cand) { $versionsJson = $cand; break }
}
# 2026-08-20: Claude Code の固定版インストールを廃止し、最新版追従にした（純正サンドボックスを
# 使う方針に切り替えたため）。表が無い場合も "latest" にフォールバックして更新を止めない。
$claudePin = ""
if ($versionsJson) {
    try {
        $claudePin = ([System.IO.File]::ReadAllText($versionsJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).claudeCode
    } catch { $claudePin = "" }
}
if (-not $claudePin) { $claudePin = "latest" }

# agy の場所（launch-agy-safe.ps1 と同じ探し方: 環境変数 AGY → PATH → 既定の置き場所）
function Find-Agy {
    if ($env:AGY -and (Test-Path -LiteralPath $env:AGY)) { return $env:AGY }
    $cmd = Get-Command agy -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "agy\bin\agy.exe"),   # 公式インストーラーの現在の置き場所（2026-10 確認）
        (Join-Path $env:LOCALAPPDATA "Antigravity\agy.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\agy.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\agy")
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Test-Tool($cmdName) {
    if ($cmdName -eq "agy") { return [bool](Find-Agy) }
    return [bool](Get-Command $cmdName -ErrorAction SilentlyContinue)
}

function Plan-Line($name, $cmdName, $whenInstalled) {
    $label = $name.PadRight(12)
    if (Test-Tool $cmdName) { Line ("   ・" + $label + " → " + $whenInstalled) }
    else { Line ("   ・" + $label + " → 入っていないので新しく入れる") }
}

Line ""
Line " == AI ツールをまとめて入れる・更新する =="
Line ""
Line " これからすること:"
Plan-Line "Codex CLI" "codex" "最新版に更新"
Plan-Line "Claude Code" "claude" "最新版に更新"
Plan-Line "OpenCode" "opencode" "最新版に更新"
Plan-Line "agy" "agy" "そのまま（公式の自動更新に任せる）"
Line "   ・Playwright   → d-claude / OpenCode のブラウザ操作の部品（決まった版を先に入れておく）"
Line ""
Line " 入れたあとは、それぞれのツールで一度ログインが必要です（使うツールだけで大丈夫です）。"
Line ""
# AI_SAFE_NO_PROMPT=1 のときは確認を飛ばす（自動テスト用）
if ($env:AI_SAFE_NO_PROMPT -ne "1") { Read-Host " Enter で続行します（やめるときは Ctrl+C）" | Out-Null }

$results = New-Object System.Collections.ArrayList

function Get-ToolVersion($cmdName) {
    # --version の出力から x.y.z を 1 つ取り出す
    $out = ""
    try { $out = (& cmd /c ($cmdName + " --version") 2>&1 | Out-String) } catch { $out = "" }
    $m = [regex]::Match([string]$out, '[0-9]+\.[0-9]+\.[0-9]+')
    if ($m.Success) { return $m.Value }
    return ""
}

function Show-FailHint($name) {
    Line ("【失敗】" + $name + " を入れられませんでした。よくある原因: ①ネット接続 ②npm が見つからない（スタート.html の Step 0 をやり直す）。")
    Line " もう一度このボタンを押して直らなければ、9_困ったとき診断 を実行してください。"
}

# --- npm の存在確認（npm の 3 つだけに必要。agy は npm 不要） ------------------
$npmOk = [bool](Get-Command npm -ErrorAction SilentlyContinue)
if (-not $npmOk) {
    Line ""
    Line "【注意】Node.js (npm) が入っていません。Codex CLI・Claude Code・OpenCode は入れられません。"
    Line " スタート.html の Step 0 に戻って Node.js を入れてから、もう一度このボタンを押してください。"
    Line " （agy は Node.js が無くても入れられるので、このまま続けます）"
}

function Install-OrUpdate-Tool($name, $cmdName, $pkg) {
    if (-not $npmOk) {
        [void]$results.Add($name + ": できませんでした（Node.js が入っていない）")
        return
    }
    if (-not (Get-Command $cmdName -ErrorAction SilentlyContinue)) {
        Line ""
        Line ("── " + $name + " は入っていないので、新しく入れます")
        & cmd /c ("npm install -g " + $pkg)
        if ($LASTEXITCODE -eq 0) {
            $after = Get-ToolVersion $cmdName
            if (-not $after) { $after = "版不明" }
            [void]$results.Add($name + ": 新しく入れました (" + $after + ")")
        } else {
            Show-FailHint $name
            [void]$results.Add($name + ": 失敗（上のメッセージを確認）")
        }
        return
    }
    $before = Get-ToolVersion $cmdName
    Line ""
    if ($before) { Line ("── " + $name + " を更新します（現在の版: " + $before + "）") }
    else { Line ("── " + $name + " を更新します（現在の版: 不明）") }
    & cmd /c ("npm install -g " + $pkg)
    if ($LASTEXITCODE -eq 0) {
        $after = Get-ToolVersion $cmdName
        if ($before -and ($before -eq $after)) {
            [void]$results.Add($name + ": 変更なし (" + $before + ")")
        } else {
            if (-not $before) { $before = "不明" }
            if (-not $after) { $after = "不明" }
            [void]$results.Add($name + ": 更新OK (" + $before + " → " + $after + ")")
        }
    } else {
        Show-FailHint $name
        [void]$results.Add($name + ": 失敗（上のメッセージを確認）")
    }
}

Install-OrUpdate-Tool "Codex CLI" "codex" "@openai/codex@latest"
# Claude Code は最新版に追従する（2026-08-20 に固定をやめた）。Codex / OpenCode と同じ処理を通す。
Install-OrUpdate-Tool "Claude Code" "claude" ("@anthropic-ai/claude-code@" + $claudePin)
Install-OrUpdate-Tool "OpenCode" "opencode" "opencode-ai@latest"

# --- agy (AntiGravity CLI) -------------------------------------------------
Line ""
$agyNow = Find-Agy
if ($agyNow) {
    Line "── agy (AntiGravity) はこのボタンでは更新しません。"
    Line "   公式の自動更新に任せます（手動でやり直す場合は説明書 09_各AIのインストール の公式手順で）。"
    [void]$results.Add("agy: 入っている（更新は公式の自動更新に任せる）")
} else {
    Line "── agy (AntiGravity) は入っていないので、公式のインストーラーで新しく入れます"
    $agyTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("agy-install-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".ps1")
    $fetched = $false
    try {
        Invoke-WebRequest -Uri $AgyInstallUrl -OutFile $agyTmp -UseBasicParsing -ErrorAction Stop
        $fetched = (Test-Path -LiteralPath $agyTmp) -and ((Get-Item -LiteralPath $agyTmp).Length -gt 0)
    } catch { $fetched = $false }
    if ($fetched) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $agyTmp
        $agyRc = $LASTEXITCODE
        $agyNew = Find-Agy
        if ($agyNew) {
            [void]$results.Add("agy: 新しく入れました (" + $agyNew + ")")
        } elseif ($agyRc -eq 0) {
            [void]$results.Add("agy: 入れましたが、見つかりません（PowerShell を開き直してください。説明書 09_各AIのインストール に対処あり）")
        } else {
            Line "【失敗】agy のインストーラーが途中で止まりました。上のメッセージを確認してください。"
            [void]$results.Add("agy: 失敗（上のメッセージを確認）")
        }
    } else {
        Line "【失敗】agy のインストーラーを取得できませんでした（ネット接続を確認してください）。"
        [void]$results.Add("agy: 失敗（インストーラーを取得できない）")
    }
    Remove-Item -LiteralPath $agyTmp -Force -ErrorAction SilentlyContinue
}

# --- Playwright（d-claude / OpenCode のブラウザ操作）を先に入れておく ------------------
# 入れておかないと d-claude / OpenCode の最初の起動でダウンロードが走り、教室で一斉に
# 起動すると時間切れになる（2026-10 実機）。版は tested-tool-versions.json の playwrightMcp。
$prefetch = Join-Path $PSScriptRoot "..\common\playwright-prefetch.js"
Line ""
Line "── Playwright（ブラウザ操作の部品）を準備します"
if ((Test-Path -LiteralPath $prefetch) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    & node $prefetch
    if ($LASTEXITCODE -eq 0) {
        [void]$results.Add("Playwright: 準備OK（起動時にダウンロードしません）")
    } else {
        [void]$results.Add("Playwright: 失敗（起動時に取りに行きます。もう一度押すとやり直せます）")
    }
} else {
    [void]$results.Add("Playwright: スキップ（Node.js か部品が見つかりません）")
}

Line ""
Line " == 結果まとめ =="
foreach ($r in $results) { Line ("   " + $r) }
Line ""
Line " いまの版:"
$nodeVer = ""
try { $nodeVer = (& cmd /c "node -v" 2>&1 | Out-String).Trim() } catch { $nodeVer = "" }
if (-not $nodeVer) { $nodeVer = "不明" }
Line ("   node:        " + $nodeVer)
if (Get-Command codex -ErrorAction SilentlyContinue) { Line ("   Codex CLI:   " + (Get-ToolVersion "codex")) }
if (Get-Command claude -ErrorAction SilentlyContinue) { Line ("   Claude Code: " + (Get-ToolVersion "claude")) }
if (Get-Command opencode -ErrorAction SilentlyContinue) { Line ("   OpenCode:    " + (Get-ToolVersion "opencode")) }
$agyFinal = Find-Agy
if ($agyFinal) { Line ("   agy:         " + $agyFinal) }
Line ""
Line " 次にやること: 使うツールに一度ログインしてください（例: スタートの「4_AIを起動する」から起動すると案内が出ます）。"
Line ""
