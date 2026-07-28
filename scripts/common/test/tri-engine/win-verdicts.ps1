# win-verdicts.ps1 — 3 エンジン横断テストの Windows 側ランナー
#
# cases.json の command を 1 件ずつ本物の guard-bash.ps1 に流し、
#   <id><TAB>block|ask|pass
# を 1 行ずつ標準出力に出す。判定ロジックはここには一切書かない
# （書くと「ガードを直したのにテストが古い判定を見ている」事故になる）。
#
# pwsh の起動は 1 件あたり 1 秒近くかかるので、-Parallel 件ずつ同時に走らせる。
# 判定は id をキーに突き合わせるので、返る順番は問わない。
# 同時に走る子プロセスが同じ now.html を書くと紛れるため、ログ置き場は子ごとに分ける
# （ログは best-effort で判定には影響しないが、切り分けの邪魔になるので避ける）。
#
# 使い方: pwsh -NoProfile -File win-verdicts.ps1 [-Cases <cases.json>] [-Parallel 4]
param([string]$Cases = "", [int]$Parallel = 4)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here "../../../..")).Path
$guard = Join-Path $repo "scripts/windows/guard-bash.ps1"
if (-not $Cases) { $Cases = Join-Path $here "cases.json" }

if (-not (Test-Path -LiteralPath $Cases)) { Write-Error "cases.json がありません: $Cases"; exit 1 }
if (-not (Test-Path -LiteralPath $guard)) { Write-Error "guard-bash.ps1 がありません: $guard"; exit 1 }
if ($Parallel -lt 1) { $Parallel = 1 }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tri-win-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = "pwsh" }

# ⚠️ 変数名は $Cases（パラメータ）と別にすること。PowerShell の変数名は大文字小文字を
# 区別しないため $cases と書くと [string] 型のパラメータへ代入され、配列が文字列 1 個に
# つぶれて 1 件しか回らない（実際にここで踏んだ）。
$caseList = @((Get-Content -Raw -Encoding UTF8 $Cases | ConvertFrom-Json).cases)

function Start-GuardProcess([object]$Case, [int]$Slot) {
    $logDir = Join-Path $tmp ("logs-" + $Slot)
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $payload = [PSCustomObject]@{
        hook_event_name = "PreToolUse"
        tool_name       = "Bash"
        cwd             = $tmp
        tool_input      = [PSCustomObject]@{ command = $Case.command }
    } | ConvertTo-Json -Depth 6 -Compress

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = "-NoProfile -File `"$guard`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardInputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables["AI_SAFE_LOG_DIR"] = $logDir
    # 2 鍵 assisted approval はグレー確定後の層。床の判定には関係しないが、
    # 呼び出し元の環境変数で ask に化けると判定が揺れるので明示的に切る。
    foreach ($k in @("AI_SAFE_ASSISTED_APPROVAL", "DS_CLAUDE_MODE", "AI_SAFE_POLICY", "AI_SAFE_ROOT")) {
        if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) | Out-Null }
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($payload)
    $proc.StandardInput.Close()
    return [PSCustomObject]@{ Id = $Case.id; Proc = $proc }
}

function Complete-GuardProcess([object]$Job) {
    $proc = $Job.Proc
    # 出力は数十バイトなので、先に読み切ってから待っても詰まらない。
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    if (-not $proc.WaitForExit(600000)) {
        try { $proc.Kill() } catch { }
        return ($Job.Id + "`ttimeout")
    }
    $verdict = "pass"
    if ($proc.ExitCode -eq 2) {
        # 床が壊れているときの FATAL も exit 2 なので、block と取り違えないよう分ける。
        if ($err -match "安全ルールが壊れています|FATAL") { $verdict = "fatal" } else { $verdict = "block" }
    } elseif ($proc.ExitCode -ne 0) {
        $verdict = "error(rc=" + $proc.ExitCode + ")"
    } elseif ($out -match '"permissionDecision"\s*:\s*"ask"') {
        $verdict = "ask"
    }
    return ($Job.Id + "`t" + $verdict)
}

try {
    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $caseList.Count; $i += $Parallel) {
        $batch = @()
        for ($j = 0; $j -lt $Parallel -and ($i + $j) -lt $caseList.Count; $j++) {
            $batch += Start-GuardProcess $caseList[$i + $j] $j
        }
        foreach ($job in $batch) { $lines.Add((Complete-GuardProcess $job)) }
    }
    foreach ($line in $lines) { Write-Output $line }
} finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
