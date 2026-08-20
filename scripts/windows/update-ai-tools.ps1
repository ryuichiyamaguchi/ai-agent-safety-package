# update-ai-tools.ps1 — AI ツール本体 (npm パッケージ) をまとめて更新する。
#
# 対象:
#   - Codex CLI   : npm install -g @openai/codex@latest
#   - Claude Code : npm install -g @anthropic-ai/claude-code@<動作確認済み版>
#                   (最新版にはしない。版は tested-tool-versions.json が SSOT)
#   - OpenCode    : npm install -g opencode-ai@latest
# 対象外:
#   - agy (AntiGravity): 公式の自動更新に任せる (案内のみ表示)
#   - Gemini CLI       : 移行済み・対象外
#
# 方針 (設計書 §4-3):
#   - 未インストールのツールはスキップする (新規インストールはさせない)
#   - 1 つ失敗しても残りを続行し、最後にまとめを表示する
#   - 管理者権限は要求しない
param(
    [string]$Workspace = (Get-Location).Path
)
$ErrorActionPreference = "Continue"
$OutputEncoding = [System.Text.Encoding]::UTF8

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

Line ""
Line " == AI ツールを最新版に更新します =="
Line ""
Line " 更新するもの（入っているものだけ）:"
Line "   ・Codex CLI    → 最新版"
Line "   ・Claude Code  → 最新版"
Line "   ・OpenCode     → 最新版"
Line " 更新しないもの:"
Line "   ・agy (AntiGravity) → 公式の自動更新に任せます（作業フォルダの docs\09_各AIのインストール.md を参照）"
Line ""
Read-Host " Enter で続行します（やめるときは Ctrl+C）" | Out-Null

# --- npm の存在確認 ----------------------------------------------------------
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Line ""
    Line "【失敗】Node.js (npm) が入っていません。"
    Line " スタート.html の Step 0 に戻って Node.js を入れてから、もう一度このボタンを押してください。"
    exit 1
}

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
    Line ("【失敗】" + $name + " を更新できませんでした。よくある原因: ①ネット接続 ②npm が見つからない（スタート.html の Step 0 をやり直す）。")
    Line " もう一度このボタンを押して直らなければ、10_困ったとき診断 を実行してください。"
}

function Update-Tool($name, $cmdName, $pkg) {
    if (-not (Get-Command $cmdName -ErrorAction SilentlyContinue)) {
        Line ""
        Line ("── " + $name + ": 入っていないためスキップします（新規インストールはしません）")
        [void]$results.Add($name + ": スキップ (未インストール)")
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

Update-Tool "Codex CLI" "codex" "@openai/codex@latest"

# Claude Code は最新版に追従する（2026-08-20 に固定をやめた）。Codex / OpenCode と同じ
# Update-Tool を通す（未インストールならスキップする挙動も共通）。
Update-Tool "Claude Code" "claude" ("@anthropic-ai/claude-code@" + $claudePin)

Update-Tool "OpenCode" "opencode" "opencode-ai@latest"

Line ""
Line "── agy (AntiGravity) はこのボタンでは更新しません。"
Line "   公式の自動更新に任せます（手動でやり直す場合は説明書 09_各AIのインストール の公式手順で）。"
[void]$results.Add("agy: 対象外 (公式の自動更新に任せる)")

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
Line ""
