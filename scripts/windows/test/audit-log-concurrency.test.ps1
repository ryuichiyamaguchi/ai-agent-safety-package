# audit-log-concurrency.test.ps1 — 監査ログへの同時書き込みで hook が fail-closed しないことの回帰テスト（v1.19.6）
#
# 受講者の Windows 実機で、Claude Code の WebFetch が
#   「AI Safety Guard FAILED CLOSED (webfetch): ストリームを読み取れませんでした。」
# で止まった。Claude Code は 1 回の操作に対してフックを並べて同時に動かし（作業フォルダの
# guard-observe / guard-webfetch と PC 全体の guard-webfetch の 3 本）、それぞれが同じ監査ログへ
# Add-Content で追記していた。Windows PowerShell 5.1 の Add-Content は、ほかのプロセスと
# ぶつかると「Stream was not readable」で落ちる（PowerShell/PowerShell#27947）。
#
#   1) Write-AuditLog を複数プロセスから同時に大量に呼び、1 件も失敗せず、行が欠けず混ざらないこと
#      （その日最初のファイル作成も同時に起きるよう、空のログフォルダから始める）
#   2) 本物の guard-webfetch.ps1 を 3 本同時に何度か動かし、どれも fail-closed しないこと
#   3) ランチャーと同じく環境変数が作業フォルダ側の安全ルール（中身は同じ）を指していても、
#      「同梱のものと違う」という警告を出さないこと。中身が違うときは今までどおり警告すること
#   参考: Windows PowerShell 5.1 では、直す前の Add-Content で同じ負荷をかけたときの失敗数も表示する
#         （判定には使わない。競合はタイミング次第なので）
# 実行: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\audit-log-concurrency.test.ps1

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here "..\..\..")).Path
$lib = Join-Path $repo "scripts\windows\lib\SafetyPolicy.ps1"
$guardWebFetch = Join-Path $repo "scripts\windows\guard-webfetch.ps1"
$policy = Join-Path $repo "policy\safety-policy.json"

$pass = 0; $fail = 0
function Ok($m) { Write-Host "PASS $m"; $script:pass++ }
function Ng($m) { Write-Host "FAIL $m"; $script:fail++ }

$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = "powershell.exe" }
Write-Host ("PowerShell " + $PSVersionTable.PSVersion + " (" + $PSVersionTable.PSEdition + ")")

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("auditconc-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# --- 子プロセス: 合図を待ってから一斉に書く ---------------------------------------
$child = Join-Path $tmp "writer.ps1"
$childBody = @'
param([string]$Lib, [string]$Ready, [string]$Go, [int]$Count, [string]$Tag, [string]$Method, [string]$ErrFile)
$ErrorActionPreference = 'Stop'
. $Lib
$policy = Get-SafetyPolicy
$hi = '{"hook_event_name":"PreToolUse","tool_name":"WebFetch","cwd":"C:\\work","tool_input":{"url":"https://github.com/example/repo"}}' | ConvertFrom-Json
Set-Content -LiteralPath $Ready -Value 'ready'
$deadline = (Get-Date).AddSeconds(90)
while (-not (Test-Path -LiteralPath $Go)) {
    if ((Get-Date) -gt $deadline) { exit 99 }
    Start-Sleep -Milliseconds 5
}
$errors = New-Object System.Collections.Generic.List[string]
for ($i = 1; $i -le $Count; $i++) {
    try {
        if ($Method -eq 'old') {
            # 直す前（v1.19.5 まで）と同じ書き方。参考表示用。
            $path = Join-Path $env:AI_SAFE_LOG_DIR ('events-' + (Get-Date -Format 'yyyy-MM-dd') + '.jsonl')
            if (-not (Test-Path -LiteralPath $path)) { $null = New-Item -ItemType File -Force -Path $path }
            ('{"tag":"' + $Tag + '","i":' + $i + '}') | Add-Content -LiteralPath $path -Encoding UTF8
        } else {
            Write-AuditLog $hi 'webfetch' 'allow' ('stress ' + $Tag + ' ' + $i) 'observed' $policy
        }
    } catch {
        $errors.Add($_.Exception.Message)
    }
}
if ($errors.Count -gt 0) {
    [System.IO.File]::WriteAllLines($ErrFile, $errors.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
}
exit ([Math]::Min($errors.Count, 98))
'@
[System.IO.File]::WriteAllText($child, $childBody, (New-Object System.Text.UTF8Encoding($true)))

function Invoke-ConcurrentWriters([int]$Writers, [int]$Count, [string]$Method, [string]$LogDir) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $run = Join-Path $tmp ("run-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $run | Out-Null
    $go = Join-Path $run "go"
    $procs = @()
    for ($k = 0; $k -lt $Writers; $k++) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $psExe
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $child + '" -Lib "' + $lib + '" -Ready "' + (Join-Path $run ("ready-" + $k)) + '" -Go "' + $go + '" -Count ' + $Count + ' -Tag w' + $k + ' -Method ' + $Method + ' -ErrFile "' + (Join-Path $run ("err-" + $k + ".txt")) + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables["AI_SAFE_LOG_DIR"] = $LogDir
        foreach ($name in @("AI_SAFE_POLICY", "AI_SAFE_ROOT")) {
            if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) }
        }
        $procs += [System.Diagnostics.Process]::Start($psi)
    }
    # 全員が書き始める直前で待っている状態にしてから、一斉に始めさせる。
    $deadline = (Get-Date).AddSeconds(90)
    while (@(Get-ChildItem -LiteralPath $run -Filter "ready-*").Count -lt $Writers -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    Set-Content -LiteralPath $go -Value "go"
    $codes = @()
    foreach ($p in $procs) {
        $null = $p.Handle
        if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { }; $codes += -1 } else { $p.WaitForExit(); $codes += $p.ExitCode }
    }
    $messages = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $run -Filter "err-*.txt")) {
        $messages += @([System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8))
    }
    $lines = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $LogDir -Filter "events-*.jsonl")) {
        $lines += @([System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8) | Where-Object { $_ -ne "" })
    }
    return [PSCustomObject]@{ Codes = $codes; Messages = $messages; Lines = $lines }
}

# --- 1) Write-AuditLog の同時書き込み -----------------------------------------------
$writers = 6; $count = 40
$r = Invoke-ConcurrentWriters $writers $count "new" (Join-Path $tmp "logs-new")
$bad = @($r.Codes | Where-Object { $_ -ne 0 })
if ($bad.Count -eq 0) { Ok ("同時に書いた " + $writers + " プロセスがすべて成功した") }
else { Ng ("失敗したプロセスがある（終了コード: " + ($r.Codes -join ",") + "）: " + (@($r.Messages | Select-Object -Unique) -join " / ")) }

$expected = $writers * $count
if (@($r.Lines).Count -eq $expected) { Ok ("監査ログの行数が書いた数と一致した（" + $expected + " 行）") }
else { Ng ("監査ログの行数が合わない: 期待 " + $expected + " / 実際 " + @($r.Lines).Count) }

$broken = 0; $seen = @{}
foreach ($line in $r.Lines) {
    try {
        $o = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json
        $seen[[string]$o.reason] = $true
    } catch { $broken++ }
}
if ($broken -eq 0) { Ok "どの行も 1 件の JSON として読める（行が混ざっていない）" } else { Ng ("JSON として読めない行がある: " + $broken) }
if ($seen.Count -eq $expected) { Ok "書いた行が 1 件も欠けていない" } else { Ng ("欠けた行がある: 異なる行は " + $seen.Count + " / " + $expected) }

# --- 参考: 直す前の Add-Content で同じ負荷をかけたとき（Windows PowerShell 5.1 のみ・判定しない）
if ($PSVersionTable.PSEdition -eq "Desktop") {
    $old = Invoke-ConcurrentWriters $writers $count "old" (Join-Path $tmp "logs-old")
    $oldFailures = @($old.Messages).Count
    Write-Host ("INFO 直す前の Add-Content: 失敗 " + $oldFailures + " 件 / " + $expected + " 件、残った行 " + @($old.Lines).Count)
    foreach ($m in @($old.Messages | Group-Object | Sort-Object Count -Descending | Select-Object -First 3)) {
        Write-Host ("INFO   " + $m.Count + " 件: " + $m.Name)
    }
}

# --- 2) 本物の guard-webfetch.ps1 を 3 本同時に ----------------------------------------
# ランチャーと同じく、環境変数は「作業フォルダ側の安全ルール（中身は同梱と同じ）」を指す。
$wsRoot = Join-Path $tmp "workspace\.ai-safety"
New-Item -ItemType Directory -Force -Path (Join-Path $wsRoot "policy") | Out-Null
$wsPolicy = Join-Path $wsRoot "policy\safety-policy.json"
Copy-Item -LiteralPath $policy -Destination $wsPolicy -Force

function Start-Guard([string]$Json, [string]$LogDir, [string]$PolicyRoot) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$guardWebFetch`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables["AI_SAFE_LOG_DIR"] = $LogDir
    $psi.EnvironmentVariables["AI_SAFE_ROOT"] = $PolicyRoot
    $psi.EnvironmentVariables["AI_SAFE_POLICY"] = (Join-Path $PolicyRoot "policy\safety-policy.json")
    $p = [System.Diagnostics.Process]::Start($psi)
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($Json)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.BaseStream.Flush()
    $p.StandardInput.Close()
    return $p
}
function Wait-Guard($p) {
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { }; return [PSCustomObject]@{ Code = -1; Stderr = "timeout" } }
    $p.WaitForExit()
    return [PSCustomObject]@{ Code = $p.ExitCode; Stderr = $errTask.Result }
}

$fetchJson = '{"hook_event_name":"PreToolUse","tool_name":"WebFetch","cwd":"' + ($tmp -replace '\\', '\\\\') + '","tool_input":{"url":"https://github.com/ryuichiyamaguchi/claude-code-hud","prompt":"summarize"}}'
$guardLogDir = Join-Path $tmp "logs-guard"
New-Item -ItemType Directory -Force -Path $guardLogDir | Out-Null
$rounds = 5; $results = @()
for ($round = 1; $round -le $rounds; $round++) {
    $ps = @()
    for ($k = 0; $k -lt 3; $k++) { $ps += Start-Guard $fetchJson $guardLogDir $wsRoot }
    foreach ($p in $ps) { $results += Wait-Guard $p }
}
$failed = @($results | Where-Object { $_.Code -ne 0 })
if ($failed.Count -eq 0) { Ok ("guard-webfetch を 3 本同時に " + $rounds + " 回動かして、すべて許可（exit 0）") }
else { Ng ("guard-webfetch が止まった: " + $failed.Count + " / " + $results.Count + " 本。例: " + ($failed[0].Stderr -replace "\s+", " ")) }
$closed = @($results | Where-Object { $_.Stderr -match "FAILED CLOSED" })
if ($closed.Count -eq 0) { Ok "FAILED CLOSED が 1 度も出ない" } else { Ng ("FAILED CLOSED が出た: " + ($closed[0].Stderr -replace "\s+", " ")) }

# --- 3) 安全ルールの警告 -------------------------------------------------------------
$warned = @($results | Where-Object { $_.Stderr -match "AI Safety Guard: " })
if ($warned.Count -eq 0) { Ok "中身が同じ安全ルールを環境変数で指しても警告しない" }
else { Ng ("中身が同じなのに警告した: " + ($warned[0].Stderr -replace "\s+", " ")) }

$otherRoot = Join-Path $tmp "other\.ai-safety"
New-Item -ItemType Directory -Force -Path (Join-Path $otherRoot "policy") | Out-Null
$otherPolicy = Join-Path $otherRoot "policy\safety-policy.json"
[System.IO.File]::WriteAllText($otherPolicy, ([System.IO.File]::ReadAllText($policy) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
$d = Wait-Guard (Start-Guard $fetchJson $guardLogDir $otherRoot)
if ($d.Stderr -match "AI Safety Guard: ") { Ok "中身が違う安全ルールを指したときは今までどおり警告する" }
else { Ng ("中身が違うのに警告しなかった（stderr: " + $d.Stderr + "）") }
if ($d.Code -eq 0) { Ok "中身が違う安全ルールは無視して、同梱のルールで判定を続ける" }
else { Ng ("中身が違う安全ルールのときに止まった: " + $d.Code + " " + $d.Stderr) }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host ("audit-log-concurrency: " + $pass + " passed, " + $fail + " failed")
if ($fail -gt 0) { exit 1 }
exit 0
