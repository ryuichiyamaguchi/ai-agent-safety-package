# d-claude-shadowing.test.ps1 — legacy PowerShell profile d-claude definitions
# should be reported as cleanup targets, and the cleanup tool should be able to
# disable them without touching the real user profile.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$winDir = Resolve-Path (Join-Path $here '..')
$diagnostic = Join-Path $winDir '診断.ps1'
$cleanup = Join-Path $winDir '野良d-claudeを退治.ps1'
$setupCommands = Join-Path $winDir 'setup-commands.ps1'
$installer = Join-Path $winDir 'install.ps1'
$script:pass = 0; $script:fail = 0
function Ok($m){ Write-Host "PASS $m"; $script:pass++ }
function Ng($m){ Write-Host "FAIL $m"; $script:fail++ }

$diagText = Get-Content -LiteralPath $diagnostic -Raw -Encoding UTF8
if ($diagText -match 'WARN\s+\("プロファイルに d-claude の記述あり' -and
    $diagText -notmatch 'BAD\s+\("プロファイルに d-claude の記述あり') {
    Ok 'diagnostic reports stale profile d-claude as warning, not problem'
} else {
    Ng 'diagnostic reports stale profile d-claude as warning, not problem'
}

$setupText = Get-Content -LiteralPath $setupCommands -Raw -Encoding UTF8
if ($setupText -match 'Get-DClaudeProfileDefinitionHits' -and
    $setupText -match '7_野良d-claudeを退治') {
    Ok 'setup command warning uses active d-claude definitions and points to cleanup tool'
} else {
    Ng 'setup command warning uses active d-claude definitions and points to cleanup tool'
}

$installerText = Get-Content -LiteralPath $installer -Raw -Encoding UTF8
if ($installerText -match '野良d-claudeを退治\.ps1' -and
    $installerText -match '-Workspace \$Workspace -Yes') {
    Ok 'installer runs d-claude cleanup automatically during update'
} else {
    Ng 'installer runs d-claude cleanup automatically during update'
}

$tmphome = Join-Path ([System.IO.Path]::GetTempPath()) ("home-" + [guid]::NewGuid().ToString("N"))
$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ("ws-" + [guid]::NewGuid().ToString("N"))
$marker = Join-Path $tmphome 'profile-path.txt'
New-Item -ItemType Directory -Force -Path $tmphome, $workspace | Out-Null

$child = @"
`$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent `$PROFILE.CurrentUserCurrentHost) | Out-Null
Set-Content -LiteralPath '$marker' -Encoding UTF8 -Value `$PROFILE.CurrentUserCurrentHost
@'
`$env:UNCHANGED = 'yes'
function d-claude {
  claude @args
}
function keep-me {
  'ok'
}
'@ | Set-Content -LiteralPath `$PROFILE.CurrentUserCurrentHost -Encoding UTF8
& '$cleanup' -Workspace '$workspace' -Yes
"@

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
if (-not $pwsh) {
    Ng 'PowerShell executable available'
} else {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-Command')
    $psi.ArgumentList.Add($child)
    $psi.RedirectStandardInput = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.Environment['HOME'] = $tmphome
    $psi.Environment['USERPROFILE'] = $tmphome
    $psi.Environment['APPDATA'] = (Join-Path $tmphome 'AppData\Roaming')
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    if ($p.ExitCode -eq 0) { Ok 'cleanup tool exits 0' } else { Ng "cleanup tool exits 0 (rc=$($p.ExitCode); stderr=$stderr; stdout=$stdout)" }

    if (Test-Path -LiteralPath $marker) {
        $profilePath = (Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim()
        $profileText = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8
        if ($profileText -match '# AI Safety disabled legacy d-claude:' -and
            $profileText -match '# AI Safety disabled legacy d-claude: function d-claude' -and
            $profileText -match 'function keep-me') {
            Ok 'cleanup tool comments legacy d-claude function and preserves unrelated profile content'
        } else {
            Ng 'cleanup tool comments legacy d-claude function and preserves unrelated profile content'
        }

        $backupDir = Join-Path $tmphome '.ai-safety\backups\rogue-d-claude'
        $backup = @(Get-ChildItem -LiteralPath $backupDir -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
        if ($backup.Count -ge 1) { Ok 'cleanup tool backs up profile before editing' } else { Ng 'cleanup tool backs up profile before editing' }
    } else {
        Ng 'profile marker created'
    }
}

Remove-Item $tmphome, $workspace -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "d-claude-shadowing.test summary: pass=$script:pass fail=$script:fail"
if ($script:fail -ne 0) { exit 1 } else { exit 0 }
