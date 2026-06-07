# explainer.test.ps1 — Windows コマンド解説エンジンの実行時テスト (pwsh / PS5.1)
# 目的: mac の explainer.test.sh と同等の「誤った安心ゼロ」+「具体解説が描画される」を
#       PowerShell 実行時に検証する。StrictMode 2.0 下での .Count アンラップ例外
#       (要素1個の List/Where-Object 戻りが scalar 化し .Count が落ちる)を回帰ガードする。
# 実行: pwsh -NoProfile -File scripts/windows/test/explainer.test.ps1
#       (pwsh が無い環境ではスキップ。配布前の仮想Windows実機QAで必ず実行する)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here "..\..\..")).Path
. (Join-Path $repo "scripts\windows\lib\SafetyPolicy.ps1")
. (Join-Path $repo "scripts\windows\lib\Explainer.ps1")

$pass = 0; $fail = 0
function Ok($m)  { Write-Host "PASS $m"; $script:pass++ }
function Ng($m)  { Write-Host "FAIL $m"; $script:fail++ }

# calm = 安心文「しません」が WhatDo に含まれるか
function Get-Calm([string]$cmd) {
    $e = Get-CommandExplanation $cmd
    if ($e.WhatDo -match "しません") { return "calm" } else { return "nocalm" }
}

# ---- 1) StrictMode 回帰: 単一セグメントの一覧/読みで例外死せず具体解説が出る ----
try {
    $e = Get-CommandExplanation "Get-ChildItem -Path C:\Temp"
    if (-not [string]::IsNullOrEmpty($e.WhatDo) -and $e.WhatDo -match "一覧") {
        Ok "R1: Get-ChildItem (single segment) -> 具体解説あり (StrictMode .Count 回帰ガード)"
    } else { Ng "R1: Get-ChildItem -> WhatDo 空または非具体: [$($e.WhatDo)]" }
} catch { Ng "R1: Get-ChildItem で例外: $($_.Exception.Message)" }

try {
    $e = Get-CommandExplanation "cat foo.txt"
    if ($e.WhatDo -match "foo\.txt" -and $e.WhatDo -match "読") { Ok "R2: cat foo.txt -> 対象 foo.txt の読み解説" }
    else { Ng "R2: cat foo.txt -> [$($e.WhatDo)]" }
} catch { Ng "R2: cat foo.txt で例外: $($_.Exception.Message)" }

# ---- 2) 純粋リーダーは calm ----
foreach ($c in @("ls","cat foo.txt","wc foo","Get-ChildItem C:\Temp","type foo.txt","head -n 5 foo")) {
    if ((Get-Calm $c) -eq "calm") { Ok "calm: $c" } else { Ng "calm expected: $c" }
}

# ---- 3) 危険/複合/昇格は nocalm (誤った安心ゼロ) ----
$tab = [char]9; $lf = [char]10; $cr = [char]13
$danger = @(
    @("cat foo > out.txt", "redirect"),
    @("cat foo | findstr x", "pipe"),
    @("cat foo; ls", "compound ;"),
    @("cat foo.txt;", "trailing ;"),
    @("cat foo.txt|", "trailing |"),
    @("sudo cat foo", "escalation"),
    @("sudo${tab}cat foo", "escalation TAB"),
    @("Remove-Item -Recurse build", "recursive delete"),
    @("echo x > f", "write redirect"),
    @("Get-ChildItem | Remove-Item", "pipe to delete"),
    @("cat foo${lf}touch x", "newline separator"),
    @("cat foo${cr}touch x", "CR separator")
)
foreach ($d in $danger) {
    if ((Get-Calm $d[0]) -eq "nocalm") { Ok "nocalm: $($d[1])" } else { Ng "nocalm expected ($($d[1])): $($d[0])" }
}

# ---- 4) 削除は danger 警告が出る ----
try {
    $e = Get-CommandExplanation "Remove-Item -Recurse build"
    if ($e.Danger -match "削除") { Ok "danger: Remove-Item -Recurse -> 削除警告" } else { Ng "danger: Remove-Item -Recurse -> [$($e.Danger)]" }
} catch { Ng "danger Remove-Item で例外: $($_.Exception.Message)" }

# ---- 5) now.html 描画 end-to-end (Write-NowCard が whatdo セクションを書く) ----
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("expltest-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:AI_SAFE_LOG_DIR = $tmp
$cards = Join-Path $repo "configs\safety\cards"
$env:AI_SAFE_CARDS_DIR = $cards
try {
    $hook = '{"tool_name":"Bash","tool_input":{"command":"Get-ChildItem -Path C:\\Temp"}}' | ConvertFrom-Json
    Write-NowCard -CardId "default-bash" -RiskDefault "low" -Mode "bash" -CardsDir $cards -HookInput $hook | Out-Null
    $html = Get-Content -Raw (Join-Path $tmp "now.html")
    if ($html -match "これは何をする" -and $html -match "一覧を見ようとしています") {
        Ok "E2E: now.html に具体解説セクションが描画される"
    } else { Ng "E2E: now.html に whatdo セクションが無い" }
} catch { Ng "E2E: Write-NowCard で例外: $($_.Exception.Message)" }
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "explainer.test.ps1 summary: pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 } else { exit 0 }
