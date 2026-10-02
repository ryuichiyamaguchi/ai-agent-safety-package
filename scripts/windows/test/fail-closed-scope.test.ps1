# fail-closed-scope.test.ps1 — 「判定できないときだけ止める」範囲の回帰テスト（v1.19.7）
#
# Windows のガードは、判定と関係のない付随処理の失敗でも Fail-Closed（exit 2）して操作を止めていた。
#   ・記録ファイル（監査ログ）が書けない → 許可した操作まで止まる（v1.19.1・v1.19.7 の実害）
#   ・解説カードの部品（lib\Explainer.ps1）が読めない → すべての判定が止まる
#   ・古い安全ルールに無い項目（generatedCodeDenyRegex / packageVersion）を読む → StrictMode で例外
# mac のガードはどれも止めない。v1.19.7 で揃えた。このテストは
#   1) 付随処理が失敗しても、許可は許可（exit 0）、危険は今までどおりブロック（exit 2・理由つき）
#   2) 入力が上限（256KB）を超えたら、分かる文面で止める。水増しで危険な後半を押し出す攻撃も止まる
# を確かめる。止める規則（危険な操作）と「判定できないときは止める」は変えていないことも見る。
# 実行: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\fail-closed-scope.test.ps1

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here "..\..\..")).Path

$pass = 0; $fail = 0
function Ok($m) { Write-Host "PASS $m"; $script:pass++ }
function Ng($m) { Write-Host "FAIL $m"; $script:fail++ }

$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = "powershell.exe" }
Write-Host ("PowerShell " + $PSVersionTable.PSVersion + " (" + $PSVersionTable.PSEdition + ")")

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("failscope-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$goodLogs = Join-Path $tmp "logs"
New-Item -ItemType Directory -Force -Path $goodLogs | Out-Null
# 「フォルダのはずの場所がファイル」= 記録ファイルを作れない状態
$badLogs = Join-Path $tmp "logs-is-a-file"
Set-Content -LiteralPath $badLogs -Value "not a folder"

function Invoke-Guard([string]$ScriptPath, [string]$Json, [string]$LogDir) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables["AI_SAFE_LOG_DIR"] = $LogDir
    foreach ($name in @("AI_SAFE_POLICY", "AI_SAFE_ROOT", "AI_SAFE_ASSISTED_APPROVAL")) {
        if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) }
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($Json)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.BaseStream.Flush()
    $p.StandardInput.Close()
    if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { }; return [PSCustomObject]@{ Code = -1; Stdout = ""; Stderr = "timeout" } }
    $p.WaitForExit()
    return [PSCustomObject]@{ Code = $p.ExitCode; Stdout = $outTask.Result; Stderr = $errTask.Result }
}
function Esc([string]$s) { return ($s -replace '\\', '\\\\' -replace '"', '\"') }
function BashJson([string]$Command) { return '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"' + (Esc $tmp) + '","tool_input":{"command":"' + (Esc $Command) + '"}}' }
function WriteJson([string]$Path, [string]$Content) { return '{"hook_event_name":"PreToolUse","tool_name":"Write","cwd":"' + (Esc $tmp) + '","tool_input":{"file_path":"' + (Esc $Path) + '","content":"' + (Esc $Content) + '"}}' }
function FetchJson([string]$Url) { return '{"hook_event_name":"PreToolUse","tool_name":"WebFetch","cwd":"' + (Esc $tmp) + '","tool_input":{"url":"' + $Url + '","prompt":"summarize"}}' }
function OneLine([string]$s) { return ($s -replace "\s+", " ").Trim() }

function ExpectAllow([string]$Label, [string]$Script, [string]$Json, [string]$LogDir) {
    $r = Invoke-Guard $Script $Json $LogDir
    if ($r.Code -eq 0 -and $r.Stdout -notmatch 'permissionDecision' -and $r.Stderr -notmatch 'FAILED CLOSED') { Ok "$Label (allowed)" }
    else { Ng ("$Label — expected allow, got " + $r.Code + " " + (OneLine ($r.Stdout + " " + $r.Stderr))) }
    return $r
}
function ExpectBlock([string]$Label, [string]$Script, [string]$Json, [string]$LogDir, [string]$StderrPattern) {
    $r = Invoke-Guard $Script $Json $LogDir
    if ($r.Code -eq 2 -and $r.Stderr -match $StderrPattern) { Ok "$Label (blocked)" }
    else { Ng ("$Label — expected exit 2 matching '" + $StderrPattern + "', got " + $r.Code + " " + (OneLine $r.Stderr)) }
    return $r
}

$guardBash = Join-Path $repo "scripts\windows\guard-bash.ps1"
$guardWrite = Join-Path $repo "scripts\windows\guard-write.ps1"
$guardWebFetch = Join-Path $repo "scripts\windows\guard-webfetch.ps1"
$guardPost = Join-Path $repo "scripts\windows\guard-post-output.ps1"
$danger = 'rm -rf /Users/x/Documents'
$okFile = Join-Path $tmp "notes.txt"

# --- 1) 記録ファイルが書けない ----------------------------------------------------
$r = ExpectAllow "記録が書けなくても Web 取得の許可は許可のまま" $guardWebFetch (FetchJson "https://github.com/example/repo") $badLogs
if ($r.Stderr -match "warn: ") { Ok "記録が書けなかったことは警告として残る" } else { Ng ("警告が出ていない: " + (OneLine $r.Stderr)) }
$null = ExpectAllow "記録が書けなくてもふつうのコマンドは許可のまま" $guardBash (BashJson 'npm test') $badLogs
$null = ExpectAllow "記録が書けなくてもふつうの書き込みは許可のまま" $guardWrite (WriteJson $okFile 'hello') $badLogs
$null = ExpectAllow "記録が書けなくても出力の確認は通る" $guardPost '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_response":{"stdout":"hi"}}' $badLogs
$null = ExpectBlock "記録が書けなくても危険なコマンドは止まり、理由が出る" $guardBash (BashJson $danger) $badLogs "AI Safety Guard BLOCKED"
$null = ExpectBlock "記録が書けなくても禁止サイトは止まる" $guardWebFetch (FetchJson "https://pastebin.com/raw/x") $badLogs "AI Safety Guard BLOCKED"
$null = ExpectBlock "記録が書けなくても鍵ファイルへの書き込みは止まる" $guardWrite (WriteJson (Join-Path $tmp ".ssh\id_rsa") 'x') $badLogs "AI Safety Guard BLOCKED"

# --- 2) 解説カードの部品が無い・古い安全ルール --------------------------------------
# パッケージの必要な部分を一時フォルダへ写し、部品を消したり、ルールを古い形にしたりする。
function New-PackageCopy([string]$Name) {
    $root = Join-Path $tmp $Name
    foreach ($d in @("scripts\windows", "scripts\common", "policy", "configs")) {
        $dst = Join-Path $root $d
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo $d) -Destination $dst -Recurse -Force
    }
    return $root
}
$copy = New-PackageCopy "pkg-no-explainer"
Remove-Item -LiteralPath (Join-Path $copy "scripts\windows\lib\Explainer.ps1") -Force
$cBash = Join-Path $copy "scripts\windows\guard-bash.ps1"
$cWrite = Join-Path $copy "scripts\windows\guard-write.ps1"
$cFetch = Join-Path $copy "scripts\windows\guard-webfetch.ps1"
$null = ExpectAllow "解説カードの部品が無くても Web 取得の許可は許可のまま" $cFetch (FetchJson "https://github.com/example/repo") $goodLogs
$null = ExpectAllow "解説カードの部品が無くてもふつうのコマンドは許可のまま" $cBash (BashJson 'npm test') $goodLogs
$null = ExpectBlock "解説カードの部品が無くても危険なコマンドは止まる" $cBash (BashJson $danger) $goodLogs "AI Safety Guard BLOCKED"

# 古い安全ルールは、解説カードの部品がそろった別の写しで確かめる（原因を混ぜない）。
$old = New-PackageCopy "pkg-old-policy"
$cWrite = Join-Path $old "scripts\windows\guard-write.ps1"
$cBash = Join-Path $old "scripts\windows\guard-bash.ps1"
$cPolicy = Join-Path $old "policy\safety-policy.json"
$pol = [System.IO.File]::ReadAllText($cPolicy, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
foreach ($key in @("generatedCodeDenyRegex", "packageVersion")) {
    if ($pol.PSObject.Properties[$key]) { $pol.PSObject.Properties.Remove($key) }
}
[System.IO.File]::WriteAllText($cPolicy, ($pol | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
$null = ExpectAllow "古い安全ルール（項目が無い）でもふつうの書き込みは許可のまま" $cWrite (WriteJson $okFile 'hello') $goodLogs
$null = ExpectBlock "古い安全ルールでも鍵ファイルへの書き込みは止まる" $cWrite (WriteJson (Join-Path $tmp ".ssh\id_rsa") 'x') $goodLogs "AI Safety Guard BLOCKED"
$null = ExpectAllow "古い安全ルールでもふつうのコマンドは許可のまま（記録も書ける）" $cBash (BashJson 'npm test') $goodLogs

# --- 3) 判定できないときは今までどおり止める --------------------------------------
$null = ExpectBlock "壊れた入力は止める" $guardBash 'this is not json at all' $goodLogs "FAILED CLOSED"
$big = 'echo ' + ('a' * 300000)
$null = ExpectBlock "上限超えの入力は分かる文面で止める" $guardWrite (WriteJson $okFile ('a' * 300000)) $goodLogs "256KB"
$null = ExpectBlock "上限まで水増しして危険な後半を押し出しても止まる" $guardBash (BashJson ($big + '; ' + $danger)) $goodLogs "FAILED CLOSED"

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host ("fail-closed-scope: " + $pass + " passed, " + $fail + " failed")
if ($fail -gt 0) { exit 1 }
exit 0
