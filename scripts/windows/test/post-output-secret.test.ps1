# post-output-secret.test.ps1 — output over-block fix の回帰テスト (Windows)。
# 検証:
#   - guard-post-output は Find-OutputSecretMatch（outputSecretRegex = Generic sensitive
#     assignment 除外）で走査する。real-format に当たらない汎用代入 placeholder は ALLOW(0)。
#   - 本物のキー書式（秘密鍵ブロック / sk-ant-…）は引き続き BLOCK(2)。
#   - 入力側 guard-bash は secretRegex 全体のまま。.env 読み出し / password=longvalue… は BLOCK(2)。
# 実行: pwsh -NoProfile -File scripts/windows/test/post-output-secret.test.ps1
#       (pwsh が無い環境ではスキップ。配布前の仮想Windows実機QAで必ず実行する)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here "..\..\..")).Path
$guardPost = Join-Path $repo "scripts\windows\guard-post-output.ps1"
$guardBash = Join-Path $repo "scripts\windows\guard-bash.ps1"

$pass = 0; $fail = 0
function Ok($m)  { Write-Host "PASS $m"; $script:pass++ }
function Ng($m)  { Write-Host "FAIL $m"; $script:fail++ }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("postsecret-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$logDir = Join-Path $tmp "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$env:AI_SAFE_LOG_DIR = $logDir
$env:AI_SAFE_POLICY = Join-Path $repo "policy\safety-policy.json"

$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = "pwsh" }

# Invoke-Guard <scriptPath> <json> -> [PSCustomObject]@{ Code=...; Stdout=... }
function Invoke-Guard([string]$ScriptPath, [string]$Json) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = "-NoProfile -File `"$ScriptPath`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardInputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables["AI_SAFE_LOG_DIR"] = $logDir
    $psi.EnvironmentVariables["AI_SAFE_POLICY"] = $env:AI_SAFE_POLICY
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($Json)
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd()
    $null = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(20000) | Out-Null
    return [PSCustomObject]@{ Code = $proc.ExitCode; Stdout = $out }
}

# Build real-looking secrets via concatenation so they are not literal in source.
$sk = "sk"; $ant = "-ant-"; $antKey = $sk + $ant + ("A" * 24)
$beginPk = "-----BEGIN OPENSSH PRIVATE KEY-----"
# Generic assignment value that is NOT a real key format (placeholder).
# 注意: `sk-...` 始まりの例は OpenAI 書式に一致し正しく BLOCK されるため使わない。
$genericVal = 'api_key: "your-placeholder-value-here"'
$pwVal = "password=longvalue123456"

try {
    # --- T1: generic assignment in AI output → ALLOW (regression for the over-block bug) ---
    $r = Invoke-Guard $guardPost ('{"hook_event_name":"Stop","content":"' + $genericVal.Replace('"','\"') + '"}')
    if ($r.Code -eq 0) { Ok "T1: generic api_key placeholder in output -> ALLOW (exit 0)" }
    else { Ng "T1: generic placeholder still blocked (code=$($r.Code)) — over-block NOT fixed" }
    $snap = Join-Path $logDir "latest-answer.json"
    if ((Test-Path -LiteralPath $snap) -and ((Get-Content -LiteralPath $snap -Raw -Encoding UTF8) -match 'REDACTED:Generic sensitive assignment')) {
        Ok "T1b: allowed Stop output writes redacted latest-answer.json"
    } else {
        Ng "T1b: allowed Stop output did not write redacted latest-answer.json"
    }

    # --- T2: private key block in AI output → still BLOCK ---
    $r = Invoke-Guard $guardPost ('{"hook_event_name":"Stop","content":"' + $beginPk + '\nMIIxxxx"}')
    if ($r.Code -eq 2) { Ok "T2: private key block in output -> BLOCK (exit 2)" }
    else { Ng "T2: private key block not blocked (code=$($r.Code))" }

    # --- T3: real-format Anthropic token in AI output → still BLOCK ---
    $r = Invoke-Guard $guardPost ('{"hook_event_name":"Stop","content":"here is the key ' + $antKey + '"}')
    if ($r.Code -eq 2) { Ok "T3: real sk-ant- token in output -> BLOCK (exit 2)" }
    else { Ng "T3: real sk-ant- token not blocked (code=$($r.Code))" }

    # --- T4 (input sanity): guard-bash reading .env → still BLOCK (input side unchanged) ---
    $r = Invoke-Guard $guardBash '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat .env"}}'
    if ($r.Code -eq 2) { Ok "T4: input guard-bash .env read -> BLOCK (exit 2)" }
    else { Ng "T4: input guard-bash .env read NOT blocked (code=$($r.Code)) — input side changed!" }

    # --- T5 (input sanity): guard-bash with password=longvalue → still BLOCK on Generic sensitive assignment ---
    $r = Invoke-Guard $guardBash ('{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"export ' + $pwVal + '"}}')
    if ($r.Code -eq 2) { Ok "T5: input guard-bash password=longvalue -> BLOCK (exit 2)" }
    else { Ng "T5: input guard-bash generic assignment NOT blocked (code=$($r.Code)) — input side weakened!" }

    Write-Host "----"
    Write-Host "post-output-secret: $pass passed, $fail failed"
    if ($fail -ne 0) { exit 1 }
    exit 0
} catch {
    Write-Host "FATAL: $($_.Exception.Message)"
    exit 1
}
