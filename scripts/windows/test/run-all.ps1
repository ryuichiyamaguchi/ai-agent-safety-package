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
# 1 本でも失敗・時間切れ（既定 300 秒、-TimeoutSec で変更）があれば exit 1。
param(
    [string[]]$Exclude = @(),
    [string[]]$Only = @(),
    [int]$TimeoutSec = 300
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
    # 1 本ごとに制限時間を設ける（入力待ちなどで止まったテストが全体を止めないように）。
    # 出力はそのまま画面へ流す（取り込まない）。
    $p = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $t.FullName + '"')) -NoNewWindow -PassThru
    $null = $p.Handle   # これを先に読まないと、終了後に ExitCode が取れないことがある（Windows PowerShell の癖）
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) {
        try { $p.Kill($true) } catch {
            try { & taskkill.exe /T /F /PID $p.Id *> $null } catch { }
            try { $p.Kill() } catch { }
        }
        $rc = -1
    } else {
        $p.WaitForExit()
        $rc = $p.ExitCode
    }
    $sw.Stop()
    $result = 'FAIL'
    if ($timedOut) { $result = 'TIMEOUT' } elseif ($rc -eq 0) { $result = 'PASS' }
    $rows += [PSCustomObject]@{ Test = $t.Name; Result = $result; ExitCode = $rc; Seconds = [int]$sw.Elapsed.TotalSeconds }
}

Write-Host ''
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$failed = @($rows | Where-Object { $_.Result -ne 'PASS' })
Write-Host ('run-all: ' + ($rows.Count - $failed.Count) + ' / ' + $rows.Count + ' 本が成功')
if ($failed.Count -gt 0) { exit 1 }
exit 0
