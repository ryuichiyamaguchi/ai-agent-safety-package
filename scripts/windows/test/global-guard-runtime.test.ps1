# global-guard-runtime.test.ps1 — 「PC 全体の安全設定」(Windows) の回帰テスト。
#
# 固定したいこと:
#   (1) stage-global-runtime.js が guard 一式を固定の置き場（%USERPROFILE%\.ai-safety\global\）へ
#       作業フォルダと同じ並びで複製する（guard-*.ps1 / lib / common / policy / cards）
#   (2) 作業フォルダを移動・名前変更しても、置き場の guard-bash.ps1 は再帰削除を止め、通常のコマンドは通す
#   (3) apply-global-guard.ps1 -Auto が hook を固定の置き場へ向ける／解除記録と
#       AI_SAFE_NO_GLOBAL_GUARD=1 を守る／12（-Auto なし）で解除記録が消える
# ホームフォルダは一時フォルダに差し替える。子プロセスの $HOME が差し替わらない環境（Windows で
# 環境変数が $HOME に反映されない等）では (3) を実行せずに SKIP する（実機の設定を触らないため）。
# 実行: pwsh -NoProfile -File scripts/windows/test/global-guard-runtime.test.ps1
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..\..')).Path
$winDir = Join-Path $repo 'scripts\windows'
$commonDir = Join-Path $repo 'scripts\common'
$stageJs = Join-Path $commonDir 'stage-global-runtime.js'
$applyPs1 = Join-Path $winDir 'apply-global-guard.ps1'
$uninstallPs1 = Join-Path $winDir 'uninstall-global-guard.ps1'

$script:pass = 0; $script:fail = 0
function Ok($m) { Write-Host "PASS $m"; $script:pass++ }
function Ng($m) { Write-Host "FAIL $m"; $script:fail++ }

$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = 'powershell.exe' }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host 'SKIP node が見つからないため実行しません'
    exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gg-runtime-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$logDir = Join-Path $tmp 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# 標準入力へ UTF-8 のバイト列を直接書く（ProcessStartInfo.StandardInputEncoding は 5.1 に無い）。
function Invoke-Guard([string]$ScriptPath, [string]$Json) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['AI_SAFE_LOG_DIR'] = $logDir
    $proc = [System.Diagnostics.Process]::Start($psi)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Json)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(30000) | Out-Null
    return [PSCustomObject]@{ Code = $proc.ExitCode; Stdout = $out; Stderr = $err }
}

function BashJson([string]$Command, [string]$Cwd) {
    return '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"' + ($Cwd -replace '\\', '\\\\') + '","tool_input":{"command":"' + $Command + '"}}'
}

# ---- (1) 固定の置き場への複製 ----------------------------------------------
# 作業フォルダと同じ並び（<ws>\.ai-safety\hooks\windows 等）を配布物から組み立てる。
$ws = Join-Path $tmp 'AI作業フォルダ'
$wsAi = Join-Path $ws '.ai-safety'
New-Item -ItemType Directory -Force -Path (Join-Path $wsAi 'hooks') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $wsAi 'policy') | Out-Null
Copy-Item -LiteralPath $winDir -Destination (Join-Path $wsAi 'hooks\windows') -Recurse -Force
Copy-Item -LiteralPath $commonDir -Destination (Join-Path $wsAi 'hooks\common') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repo 'policy\safety-policy.json') -Destination (Join-Path $wsAi 'policy\safety-policy.json') -Force
Copy-Item -LiteralPath (Join-Path $repo 'configs\safety\cards') -Destination (Join-Path $wsAi 'cards') -Recurse -Force

$rt = Join-Path $tmp 'rt'
$global:LASTEXITCODE = 0
& node $stageJs --os windows --guard-src (Join-Path $wsAi 'hooks\windows') --dest $rt | Out-Null
if ($LASTEXITCODE -eq 0) { Ok 'stage-global-runtime が終了コード 0' } else { Ng ('stage-global-runtime rc=' + $LASTEXITCODE) }
foreach ($rel in @('hooks\windows\guard-bash.ps1', 'hooks\windows\guard-prompt.ps1', 'hooks\windows\guard-write.ps1',
                   'hooks\windows\guard-webfetch.ps1', 'hooks\windows\guard-post-output.ps1',
                   'hooks\windows\lib\SafetyPolicy.ps1', 'hooks\windows\lib\Explainer.ps1',
                   'hooks\common\command-judge.js', 'hooks\common\answer-snapshot.js',
                   'policy\safety-policy.json', 'cards\index.tsv')) {
    if (Test-Path -LiteralPath (Join-Path $rt $rel)) { Ok ('置き場にある: ' + $rel) } else { Ng ('置き場に無い: ' + $rel) }
}
foreach ($rel in @('hooks\windows\install.ps1', 'hooks\windows\apply-global-guard.ps1', 'hooks\windows\test', 'hooks\common\test', 'hooks\common\assets')) {
    if (-not (Test-Path -LiteralPath (Join-Path $rt $rel))) { Ok ('持ち込んでいない: ' + $rel) } else { Ng ('持ち込んでいる: ' + $rel) }
}

# ---- (2) 作業フォルダを動かしても止め続ける ------------------------------------
Rename-Item -LiteralPath $ws -NewName 'renamed-workspace'
$proj = Join-Path $tmp 'proj'
New-Item -ItemType Directory -Force -Path (Join-Path $proj 'somedir') | Out-Null
$guard = Join-Path $rt 'hooks\windows\guard-bash.ps1'
$r = Invoke-Guard $guard (BashJson 'rm -rf somedir' $proj)
if ($r.Code -eq 2) { Ok '作業フォルダを移動したあとも、置き場の guard が rm -rf を止める' } else { Ng ('rm -rf が止まらない rc=' + $r.Code + ' ' + $r.Stderr) }
$r = Invoke-Guard $guard (BashJson 'Remove-Item -Recurse -Force somedir' $proj)
if ($r.Code -eq 2) { Ok '置き場の guard が Remove-Item -Recurse を止める' } else { Ng ('Remove-Item -Recurse が止まらない rc=' + $r.Code) }
$r = Invoke-Guard $guard (BashJson 'npm test' $proj)
if ($r.Code -eq 0 -and $r.Stdout -notmatch 'permissionDecision') { Ok '通常のコマンドは通す' } else { Ng ('通常のコマンドまで止めた rc=' + $r.Code + ' ' + $r.Stdout) }

# ---- (3) apply-global-guard.ps1 -Auto / 解除記録 ------------------------------
$envKeys = @('HOME', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'XDG_CONFIG_HOME', 'AI_SAFE_DENY_SRC', 'AI_SAFE_NO_GLOBAL_GUARD',
             'AI_SAFE_ASSUME_YES', 'AI_SAFE_GLOBAL_STATE', 'AI_SAFE_GLOBAL_CLAUDE', 'AI_SAFE_GLOBAL_CODEX',
             'AI_SAFE_GLOBAL_CODEX_HOOKS', 'AI_SAFE_GLOBAL_AGY', 'AI_SAFE_GLOBAL_OPENCODE_DIR')
$saved = @{}
foreach ($k in $envKeys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
function Set-FakeHome([string]$Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    foreach ($k in $envKeys) { [Environment]::SetEnvironmentVariable($k, $null) }
    [Environment]::SetEnvironmentVariable('HOME', $Dir)
    [Environment]::SetEnvironmentVariable('USERPROFILE', $Dir)
    if ($Dir -match '^([A-Za-z]:)(\\.*)$') {
        [Environment]::SetEnvironmentVariable('HOMEDRIVE', $Matches[1])
        [Environment]::SetEnvironmentVariable('HOMEPATH', $Matches[2])
    }
    [Environment]::SetEnvironmentVariable('AI_SAFE_DENY_SRC', (Join-Path $repo 'configs\claude\settings.windows.json'))
}
function Restore-Env {
    foreach ($k in $envKeys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
}
function Invoke-Ps([string]$File, [string[]]$Arguments) {
    $global:LASTEXITCODE = 0
    $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $File @Arguments | Out-String
    return [PSCustomObject]@{ Code = $LASTEXITCODE; Out = $out }
}
# settings.json の Bash 用 hook が呼ぶ guard のパス（'/' にそろえて返す）
function Get-HookGuardPath([string]$SettingsPath) {
    $s = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $group = @($s.hooks.PreToolUse | Where-Object { $_.matcher -eq 'Bash|PowerShell' })[0]
    $cmd = @($group.hooks[0].args)[-1]
    if ($cmd -match "\`$p = '([^']+)'") { return ($Matches[1] -replace '\\', '/') }
    return ''
}

$fakeHome = Join-Path $tmp 'home'
Set-FakeHome $fakeHome
$probe = (& $psExe -NoProfile -Command '$HOME' | Out-String).Trim()
if ($probe -ne $fakeHome) {
    Restore-Env
    Write-Host ('SKIP (3): 子プロセスの $HOME が一時フォルダに差し替わらないため、全体設定の書き込みは試しません（' + $probe + '）')
} else {
    $settings = Join-Path $fakeHome '.claude\settings.json'
    $optout = Join-Path $fakeHome '.ai-safety\global-guard-optout'
    $rtGuard = (Join-Path $fakeHome '.ai-safety\global\hooks\windows\guard-bash.ps1') -replace '\\', '/'

    $r = Invoke-Ps $applyPs1 @('-Auto')
    if ($r.Code -eq 0) { Ok '-Auto が終了コード 0' } else { Ng ('-Auto rc=' + $r.Code + ' ' + $r.Out) }
    if ($r.Out -match '最初から入っています') { Ok '-Auto が短い案内を出す' } else { Ng ('-Auto の案内が無い: ' + $r.Out) }
    if (Test-Path -LiteralPath (Join-Path $fakeHome '.ai-safety\global\hooks\windows\guard-bash.ps1')) { Ok '固定の置き場ができた' } else { Ng '固定の置き場が無い' }
    if ((Test-Path -LiteralPath $settings) -and ((Get-HookGuardPath $settings) -like ('*' + ($rtGuard -replace '^[A-Za-z]:', '')))) {
        Ok 'Claude の hook が固定の置き場の guard-bash.ps1 を指す'
    } else { Ng ('Claude の hook の向き先が違う: ' + $(if (Test-Path -LiteralPath $settings) { Get-HookGuardPath $settings } else { '(settings.json なし)' })) }
    $codexCfg = Join-Path $fakeHome '.codex\config.toml'
    if ((Test-Path -LiteralPath $codexCfg) -and ((Get-Content -LiteralPath $codexCfg -Raw) -match 'sandbox_mode = "workspace-write"')) { Ok 'Codex の全体設定が入った' } else { Ng 'Codex の全体設定が無い' }

    $r = Invoke-Ps $uninstallPs1 @()
    if ($r.Code -eq 0 -and (Test-Path -LiteralPath $optout)) { Ok '13（解除）で解除記録が作られる' } else { Ng ('解除記録が無い rc=' + $r.Code) }
    if (-not (Test-Path -LiteralPath $settings)) { Ok '解除で Claude の全体設定が元（無し）に戻る' } else { Ng '解除後も settings.json が残った' }

    $r = Invoke-Ps $applyPs1 @('-Auto')
    if ($r.Code -eq 0 -and $r.Out -match '入れ直していません' -and -not (Test-Path -LiteralPath $settings)) { Ok '解除記録があると -Auto は何もしない' } else { Ng ('解除記録を無視した rc=' + $r.Code) }

    [Environment]::SetEnvironmentVariable('AI_SAFE_ASSUME_YES', '1')
    $r = Invoke-Ps $applyPs1 @()
    [Environment]::SetEnvironmentVariable('AI_SAFE_ASSUME_YES', $null)
    if ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $optout) -and (Test-Path -LiteralPath $settings)) { Ok '12（-Auto なし）で解除記録が消えて入る' } else { Ng ('12 の後も解除記録が残る/入らない rc=' + $r.Code) }

    $fakeHome2 = Join-Path $tmp 'home2'
    Set-FakeHome $fakeHome2
    [Environment]::SetEnvironmentVariable('AI_SAFE_NO_GLOBAL_GUARD', '1')
    $r = Invoke-Ps $applyPs1 @('-Auto')
    if ($r.Code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $fakeHome2 '.claude')) -and -not (Test-Path -LiteralPath (Join-Path $fakeHome2 '.ai-safety\global'))) {
        Ok 'AI_SAFE_NO_GLOBAL_GUARD=1 なら何も書かない'
    } else { Ng ('AI_SAFE_NO_GLOBAL_GUARD=1 を無視した rc=' + $r.Code) }
    Restore-Env
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ('global-guard-runtime.test summary: pass=' + $script:pass + ' fail=' + $script:fail)
if ($script:fail -ne 0) { exit 1 } else { exit 0 }
