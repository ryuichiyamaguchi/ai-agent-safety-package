# explainer.test.ps1 — Windows の解説表示のテスト (pwsh / PS5.1)
# 目的: mac の explainer.test.sh と同等の「誤った安心ゼロ」+「具体解説が描画される」を、
#       Windows の見張りが使う入口（Explainer.ps1 の Invoke-Explain）から検証する。
# v1.19.0: 解説の本体は scripts\common\explainer.js（Mac/Windows 共通の 1 本）に移った。
#       ここでは (1) explainer.js の説明文 (2) PowerShell から Node を呼ぶ入口（PS 5.1 で UTF-8 を正しく渡すか）
#       (3) Node が無いときの簡易表示 を確かめる。
# 実行: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\explainer.test.ps1

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here "..\..\..")).Path
. (Join-Path $repo "scripts\windows\lib\SafetyPolicy.ps1")
. (Join-Path $repo "scripts\windows\lib\Explainer.ps1")

$pass = 0; $fail = 0
function Ok($m)  { Write-Host "PASS $m"; $script:pass++ }
function Ng($m)  { Write-Host "FAIL $m"; $script:fail++ }

$js = Join-Path $repo "scripts\common\explainer.js"
$node = Resolve-ExplainerNode
if (-not $node) {
    Write-Host "SKIP node が見つからないため explainer.js のテストを飛ばします（簡易表示のテストだけ行います）"
}

# explainer.js の explain-command を呼んで { WhatDo; Icon; Danger } を返す。
# PS 5.1 のパイプは $OutputEncoding（既定 ASCII）で渡すため日本語が壊れる。ProcessStartInfo で UTF-8 のまま渡す。
function Get-CommandExplanation([string]$Full) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node
    $psi.Arguments = "`"$js`" explain-command"
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $utf8 = New-Object System.Text.UTF8Encoding $false
    if ($psi.PSObject.Properties['StandardOutputEncoding']) { $psi.StandardOutputEncoding = $utf8 }
    $proc = [System.Diagnostics.Process]::Start($psi)
    # 見張りの入口（Explainer.ps1 の Invoke-ExplainerJs）と同じ渡し方: バイト列を書き、Flush してから閉じる。
    # Flush を省くと Windows PowerShell 5.1 では node に何も届かないことがあった（GitHub Actions で判明）。
    $bytes = $utf8.GetBytes($Full)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.BaseStream.Flush()
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    [void]$proc.WaitForExit(10000)
    if ([string]::IsNullOrWhiteSpace($out)) {
        Write-Host ("  (explain-command の出力が空: exit=" + $proc.ExitCode + " stderr=" + $err + ")")
    }
    $j = $out | ConvertFrom-Json
    return [PSCustomObject]@{ WhatDo = [string]$j.whatdo; Icon = [string]$j.icon; Danger = [string]$j.danger }
}

# calm = 安心文「しません」が WhatDo に含まれるか
function Get-Calm([string]$cmd) {
    $e = Get-CommandExplanation $cmd
    if ($e.WhatDo -match "しません") { return "calm" } else { return "nocalm" }
}

if ($node) {
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

# ---- 5) now.html 描画 end-to-end（見張りが使う入口 Invoke-Explain → explainer.js） ----
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("expltest-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:AI_SAFE_LOG_DIR = $tmp
$env:AI_SAFE_CARDS_DIR = Join-Path $repo "configs\safety\cards"
try {
    $hook = '{"tool_name":"Bash","tool_input":{"command":"Get-ChildItem -Path C:\\Temp\\資料"}}' | ConvertFrom-Json
    Invoke-Explain -HookInput $hook -Mode "bash" -Policy $null
    $html = [System.IO.File]::ReadAllText((Join-Path $tmp "now.html"), [System.Text.Encoding]::UTF8)
    if ($html -match "これは何をする" -and $html -match "一覧を見ようとしています" -and $html -match "資料") {
        Ok "E2E: Invoke-Explain -> now.html に具体解説（日本語のパスも化けない）"
    } else { Ng "E2E: now.html に whatdo セクションが無い、または日本語が化けた" }
    if ($html -notmatch "<p>---</p>") { Ok "E2E: カードの管理用の行（---）を本文に出さない" } else { Ng "E2E: now.html に frontmatter が出ている" }
} catch { Ng "E2E: Invoke-Explain で例外: $($_.Exception.Message)" }
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

# ---- 6) Node が見つからないときの簡易表示 ----
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("expltest-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:AI_SAFE_LOG_DIR = $tmp
$env:AI_SAFE_EXPLAINER_NODE = (Join-Path $tmp "no-such-node.exe")
try {
    $hook = '{"tool_name":"Bash","tool_input":{"command":"echo <b>x</b> > 出力.txt"}}' | ConvertFrom-Json
    Invoke-Explain -HookInput $hook -Mode "bash" -Policy $null
    $html = [System.IO.File]::ReadAllText((Join-Path $tmp "now.html"), [System.Text.Encoding]::UTF8)
    $md = [System.IO.File]::ReadAllText((Join-Path $tmp "now.md"), [System.Text.Encoding]::UTF8)
    if ($html -match "card=fallback" -and $html -match "&lt;b&gt;x&lt;/b&gt; &gt; 出力.txt") { Ok "fallback: now.html に操作の文字列をエスケープして表示" } else { Ng "fallback: now.html が期待どおりでない" }
    if ($md -match "出力.txt" -and $md -match "Node.js") { Ok "fallback: now.md に操作と案内を表示" } else { Ng "fallback: now.md が期待どおりでない" }
} catch { Ng "fallback で例外: $($_.Exception.Message)" }
finally {
    Remove-Item Env:\AI_SAFE_EXPLAINER_NODE -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "explainer.test.ps1 summary: pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 } else { exit 0 }
