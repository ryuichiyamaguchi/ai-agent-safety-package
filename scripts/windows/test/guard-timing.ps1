# guard-timing.ps1 — Windows のガード 1 回にかかる時間の内訳を測る（計測専用・合否なし）
#
# 受講者の PC で動くのは Windows PowerShell 5.1。mac の pwsh では比率が違いうるので、本物の
# Windows（.github/workflows/guard-timing.yml・手動実行）で測ってから速くする場所を決める。
#   1) powershell.exe の起動だけ
#   2) guard-bash.ps1 を 1 回（ふつうのコマンド。作業フォルダの実際の呼び方と同じ -File）
#   3) 作業フォルダで 1 回の操作に動く 3 本（observe・bash・PC 全体の bash 相当）を同時に
#   4) 1 つのプロセスの中での内訳（命令の初回準備・共通部品・安全ルール・解説カード・記録）
param([int]$Repeat = 5)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..\..')).Path
$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = 'powershell.exe' }
$logDir = Join-Path ([System.IO.Path]::GetTempPath()) ('asp-timing-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$json = '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"C:\\work","tool_input":{"command":"npm test"}}'
$inFile = Join-Path $logDir 'in.json'
[System.IO.File]::WriteAllText($inFile, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('PowerShell ' + $PSVersionTable.PSVersion + ' / CPU ' + $env:NUMBER_OF_PROCESSORS + ' cores')

function Measure-Ms([scriptblock]$Block) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew(); & $Block | Out-Null; $sw.Stop(); return [int]$sw.Elapsed.TotalMilliseconds
}
function Median([int[]]$xs) { $s = @($xs | Sort-Object); return $s[[int][Math]::Floor($s.Count / 2)] }
function Start-Guard([string]$Script) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['AI_SAFE_LOG_DIR'] = $logDir
    $p = [System.Diagnostics.Process]::Start($psi)
    $b = [System.IO.File]::ReadAllBytes($inFile)
    $p.StandardInput.BaseStream.Write($b, 0, $b.Length); $p.StandardInput.Close()
    return $p
}
function Wait-All($procs) { foreach ($p in $procs) { $null = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd(); $p.WaitForExit() } }

$guardBash = Join-Path $repo 'scripts\windows\guard-bash.ps1'
$guardObserve = Join-Path $repo 'scripts\windows\guard-observe.ps1'

$t1 = @(); for ($i = 0; $i -lt $Repeat; $i++) { $t1 += Measure-Ms { & $psExe -NoProfile -Command 'exit 0' } }
$t2 = @(); for ($i = 0; $i -lt $Repeat; $i++) { $t2 += Measure-Ms { Wait-All @(Start-Guard $guardBash) } }
$t3 = @(); for ($i = 0; $i -lt $Repeat; $i++) { $t3 += Measure-Ms { Wait-All @((Start-Guard $guardObserve), (Start-Guard $guardBash), (Start-Guard $guardBash)) } }
Write-Host ('1) powershell.exe の起動だけ          : 中央値 ' + (Median $t1) + ' ms  (' + ($t1 -join ', ') + ')')
Write-Host ('2) guard-bash.ps1 を 1 回              : 中央値 ' + (Median $t2) + ' ms  (' + ($t2 -join ', ') + ')')
Write-Host ('3) 3 本を同時に（1 回の操作の実際）    : 中央値 ' + (Median $t3) + ' ms  (' + ($t3 -join ', ') + ')')

$inner = @'
param($Repo, $LogDir, $InFile)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
. ([System.IO.Path]::Combine($Repo, 'scripts', 'windows', 'lib', 'SafetyPolicy.ps1')); $b = $sw.ElapsedMilliseconds
$sw.Restart(); $pol = Get-SafetyPolicy; $c = $sw.ElapsedMilliseconds
$sw.Restart(); . ([System.IO.Path]::Combine($Repo, 'scripts', 'windows', 'lib', 'Explainer.ps1')); $d = $sw.ElapsedMilliseconds
$env:AI_SAFE_LOG_DIR = $LogDir
$hi = [System.IO.File]::ReadAllText($InFile) | ConvertFrom-Json
$sw.Restart(); Invoke-AiSafeExplain $hi 'bash' $pol; $e = $sw.ElapsedMilliseconds
$sw.Restart(); Write-AuditLog $hi 'bash' 'allow' 'timing' 'npm test' $pol; $f = $sw.ElapsedMilliseconds
$mods = (@(Get-Module | ForEach-Object { $_.Name }) -join ',')
'4) 内訳: 共通部品の読み込み ' + $b + ' ms / 安全ルール ' + $c + ' ms / 解説の部品 ' + $d + ' ms / 解説カード（待たない） ' + $e + ' ms / 記録 ' + $f + ' ms / 読み込まれた部品: ' + $mods
'@
$innerFile = Join-Path $logDir 'inner.ps1'
[System.IO.File]::WriteAllText($innerFile, $inner, (New-Object System.Text.UTF8Encoding($true)))
for ($i = 0; $i -lt 3; $i++) { & $psExe -NoProfile -ExecutionPolicy Bypass -File $innerFile -Repo $repo -LogDir $logDir -InFile $inFile }
Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
exit 0
