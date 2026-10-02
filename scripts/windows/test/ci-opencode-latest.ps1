# ci-opencode-latest.ps1 — 最新の OpenCode で、OpenCode ランチャーの起動前点検を本当に通す（Windows PowerShell 5.1）
#
# なぜ要るか: パッケージは OpenCode を「常に最新版」で入れる。OpenCode 側の変更で起動前点検が
# 止まると（v1.19.2: 1.18.26 から設定の一部が *** で伏せて表示されるようになり、受講者の PC で
# OpenCode が起動しなくなった）、受講者のほうが先に気づくことになる。週 1 回、最新の OpenCode で
# ランチャーを最後まで流して、受講者より先に見つける（.github/workflows/latest-tools.yml）。
#
# やり方: OPENCODE_BIN を代役（.cmd）に差し替える。代役は「版の確認」と「設定の出力（debug config）」を
# 本物の OpenCode に渡し、画面（TUI）の起動の代わりに印を残して終わる。ランチャーは
#   1) 解決済み設定で deny 床が生きているか（opencode-config.js --verify-resolved）
#   2) 安全プラグインが実際に読み込まれたか（BOUNCER_READY_OK）
# を確かめてから起動するので、印が残れば「最新の OpenCode でも点検を通った」ことになる。
# 無料モデルのモード（-Free）で流すので、DeepSeek のキーは要らない。
#
# 使い方（CI の Windows 上で）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\ci-opencode-latest.ps1
param(
    [string]$Workspace = '',
    [string]$RealOpenCode = ''
)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..\..')).Path
$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = 'powershell.exe' }

if (-not $RealOpenCode) {
    foreach ($name in @('opencode.cmd', 'opencode.exe', 'opencode')) {
        $c = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { $RealOpenCode = $c.Source; break }
    }
}
if (-not $RealOpenCode -or -not (Test-Path -LiteralPath $RealOpenCode)) {
    Write-Host 'FAIL 本物の opencode が見つかりません（-RealOpenCode か PATH で渡してください）'
    exit 1
}
$ver = (& $RealOpenCode --version 2>$null | Select-Object -First 1)
Write-Host ('PowerShell ' + $PSVersionTable.PSVersion + ' / OpenCode: ' + $RealOpenCode + ' (' + $ver + ')')

$base = $env:RUNNER_TEMP
if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
$td = Join-Path $base ('asp-oc-latest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $td | Out-Null
if (-not $Workspace) { $Workspace = Join-Path $env:USERPROFILE 'Documents\AI作業フォルダ-OpenCode最新' }

Write-Host '===== 1/2 導入（install.ps1） ====='
& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\windows\install.ps1') -Workspace $Workspace *> (Join-Path $td 'install.log')
$rcInstall = $LASTEXITCODE
if ($rcInstall -ne 0) {
    Get-Content -LiteralPath (Join-Path $td 'install.log') -Tail 30 -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host ('FAIL 導入に失敗しました（exit=' + $rcInstall + '）')
    exit 1
}
$launcher = Join-Path $Workspace '.ai-safety\hooks\windows\opencode\launch-opencode-deepseek.ps1'
if (-not (Test-Path -LiteralPath $launcher)) {
    Write-Host ('FAIL 導入後にランチャーが見つかりません: ' + $launcher)
    exit 1
}

# 代役。ASCII だけで書く（cmd.exe は CP932 / ANSI で読む）。
$marker = Join-Path $td 'tui-started.txt'
$wrapper = Join-Path $td 'opencode-wrapper.cmd'
$cmdLines = @(
    '@echo off',
    'if /I "%~1"=="--version" goto real',
    'if /I "%~1"=="-v" goto real',
    'if /I "%~1"=="debug" goto real',
    'echo started> "%OC_TUI_MARKER%"',
    'exit /b 0',
    ':real',
    'call "%OC_REAL%" %*',
    'exit /b %ERRORLEVEL%'
)
[System.IO.File]::WriteAllText($wrapper, (($cmdLines -join "`r`n") + "`r`n"), (New-Object System.Text.ASCIIEncoding))

Write-Host '===== 2/2 ランチャーを最新の OpenCode で流す（-Free） ====='
$env:OPENCODE_BIN = $wrapper
$env:OC_REAL = $RealOpenCode
$env:OC_TUI_MARKER = $marker
$emptyIn = Join-Path $td 'empty-stdin.txt'
[System.IO.File]::WriteAllText($emptyIn, '')
$outLog = Join-Path $td 'launch.out.log'
$errLog = Join-Path $td 'launch.err.log'
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $launcher + '"'), '-Workspace', ('"' + $Workspace + '"'), '-Free')
$p = Start-Process -FilePath $psExe -ArgumentList $argList -NoNewWindow -PassThru -Wait -RedirectStandardInput $emptyIn -RedirectStandardOutput $outLog -RedirectStandardError $errLog
$rc = $p.ExitCode
if ($rc -eq 0 -and (Test-Path -LiteralPath $marker)) {
    Write-Host ('PASS 最新の OpenCode でも起動前点検を通り、起動まで進んだ（rc=' + $rc + '）')
    exit 0
}
Write-Host '--- ランチャーの出力（末尾） ---'
foreach ($f in @($outLog, $errLog)) {
    if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Tail 30 -Encoding UTF8 -ErrorAction SilentlyContinue }
}
foreach ($dir in @((Join-Path $Workspace '.ai-safety\logs'), (Join-Path $env:USERPROFILE '.ai-safety\logs'))) {
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'opencode-resolved-failed*.json' -ErrorAction SilentlyContinue)) {
        Write-Host ('--- 点検で不一致だった設定（' + $f.FullName + ' の先頭） ---')
        $text = [System.IO.File]::ReadAllText($f.FullName)
        if ($text.Length -gt 3000) { $text = $text.Substring(0, 3000) }
        Write-Host $text
    }
}
$markerState = if (Test-Path -LiteralPath $marker) { 'あり' } else { 'なし' }
Write-Host ('FAIL 最新の OpenCode で起動前点検を通らなかった（rc=' + $rc + '、起動の印: ' + $markerState + '）')
exit 1
