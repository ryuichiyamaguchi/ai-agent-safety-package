# run-all.ps1 — scripts\windows\test の *.test.ps1 を 1 本ずつ別プロセスで流し、結果を表にまとめる。
#
# 使い方（Windows の PowerShell 画面で、パッケージのフォルダから）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\run-all.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\run-all.ps1 -Exclude auto-mode.test.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\run-all.ps1 -Only auto-mode.test.ps1
#
# 子プロセスは「このスクリプトを動かしている PowerShell と同じもの」で起動する。
# powershell.exe（5.1）で呼べば 5.1 で、pwsh（7）で呼べば 7 でテストが走る。
# GitHub Actions（.github/workflows/windows-tests.yml）はこれを Windows PowerShell 5.1 で呼ぶ。
# 1 本でも失敗したら exit 1。
param(
    [string[]]$Exclude = @(),
    [string[]]$Only = @()
)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = 'powershell.exe' }

Write-Host ('PowerShell ' + $PSVersionTable.PSVersion + ' : ' + $psExe)

$tests = @(Get-ChildItem -LiteralPath $here -Filter '*.test.ps1' | Sort-Object Name)
if ($Only.Count -gt 0) { $tests = @($tests | Where-Object { $Only -contains $_.Name }) }
if ($Exclude.Count -gt 0) { $tests = @($tests | Where-Object { $Exclude -notcontains $_.Name }) }
if ($tests.Count -eq 0) {
    Write-Host 'FAIL 対象のテストがありません（-Only / -Exclude の指定を確認してください）'
    exit 1
}

$rows = @()
foreach ($t in $tests) {
    Write-Host ''
    Write-Host ('===== ' + $t.Name + ' =====')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $t.FullName
    $rc = $LASTEXITCODE
    $sw.Stop()
    $result = 'FAIL'
    if ($rc -eq 0) { $result = 'PASS' }
    $rows += [PSCustomObject]@{ Test = $t.Name; Result = $result; ExitCode = $rc; Seconds = [int]$sw.Elapsed.TotalSeconds }
}

Write-Host ''
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$failed = @($rows | Where-Object { $_.Result -ne 'PASS' })
Write-Host ('run-all: ' + ($rows.Count - $failed.Count) + ' / ' + $rows.Count + ' 本が成功')
if ($failed.Count -gt 0) { exit 1 }
exit 0
