# IsolationDrills.ps1 — OS 金庫(サンドボックス)が実際に効いているかを
# 実証検証するドリル群(mac isolation_drills.sh の PowerShell 版)。
# doctor.ps1 と test から dot-source される。
#
# 戻り値の約束(PowerShell 関数のパイプライン出力として返す int):
#   0   = PASS (金庫が効いている = 該当の遮断が実証できた)
#   10  = FAIL (金庫に穴 = 遮断できなかった)
#   20  = 保留 (効力を実証できない。安全側で「赤」扱いにすること)
#
# 設計: 関数は戻り値(int)をパイプラインに返す。表示は Write-Host でパイプラインを汚染しない。
# 呼び出し側: $rc = [int](Get-SomeDrill 'codex')  で確実に整数として取得する。
#
# SKIP は表示専用(フル doctor 向け)。
# launcher の自動承認判定は -IsolationCheck(strict: HOLD=非0)を使うため、
# ここの HOLD が自動承認解放に影響することはない。

Set-StrictMode -Off  # dot-source されるため呼び出し元スコープで未定義変数等による意図しないエラーが出ないよう StrictMode を Off にする

# --- Test-WriteOutside ---
# 金庫の中から workspace 外への書き込みを試み、作られないことを確認する。
# engine = 'codex' のとき実証。'agy' は実証不能につき HOLD 固定。
function Test-WriteOutside([string]$Engine) {
    switch ($Engine) {
        'codex' {
            if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
                Write-Host "HOLD codex not installed"
                return 20
            }
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("aisafe-wo-" + [guid]::NewGuid().ToString("N"))
            $inside = Join-Path $root 'ws'
            $outside = Join-Path $root 'out'
            New-Item -ItemType Directory -Path $inside -Force | Out-Null
            New-Item -ItemType Directory -Path $outside -Force | Out-Null
            $target = Join-Path $outside 'pwn.txt'
            # codex sandbox windows でワークスペース外への書き込みを試みる。
            # $LASTEXITCODE を使って「サンドボックスが起動できたか」を区別する。
            & codex sandbox windows -C $inside powershell.exe -NoProfile -Command "Set-Content -Path '$target' -Value pwn" 2>$null | Out-Null
            $codexRc = $LASTEXITCODE
            if (Test-Path -LiteralPath $target) {
                # target が作られた = 金庫に穴 = FAIL
                Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
                Write-Host "FAIL workspace-outside write succeeded"
                return 10
            }
            if ($codexRc -ne 0) {
                # target 未作成 かつ codex 非0終了 = sandbox 自体が起動できなかった可能性。
                # 書込ブロックを実証できていないので保守的に HOLD。
                Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
                Write-Host "HOLD codex sandbox did not run cleanly (rc=$codexRc); write block not proven"
                return 20
            }
            # target 未作成 かつ codex 正常終了 = 遮断された = PASS
            Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
            Write-Host "PASS workspace-outside write blocked"
            return 0
        }
        'agy' {
            # agy は codex sandbox 相当の外部実行手段が無く実証不能(実機確認 2026-06-01)。
            # agy の隔離チェックは Test-AgyDeclaration を使う。
            Write-Host "HOLD agy write drill not supported (declaration-based; see Test-AgyDeclaration)"
            return 20
        }
        default {
            Write-Host "HOLD unknown engine: $Engine"
            return 20
        }
    }
}

# --- Get-NetResultClass ---
# 接続試行の結果文字列を金庫判定に写像する(テスト容易性のため分離)。
# mac の classify_net_result に対応。
function Get-NetResultClass([string]$Result) {
    switch ($Result) {
        'refused'   { Write-Host "PASS egress blocked by sandbox"; return 0 }
        'connected' { Write-Host "FAIL egress connection succeeded"; return 10 }
        default     { Write-Host "HOLD egress result indeterminate (offline?)"; return 20 }
    }
}

# --- Get-EgressProbe (内部ヘルパー) ---
# 金庫の中から <host>:<port> へ TCP 接続を試み、
# "refused" / "connected" / "timeout" のいずれかを返す(Write-Output)。
# データは送らない(接続確立の可否のみ)。
# 注: $TargetHost を使う($Host は PowerShell 自動変数とシャドウするため避ける)。
function Get-EgressProbe([string]$Engine, [string]$TargetHost, [int]$Port) {
    switch ($Engine) {
        'codex' {
            # powershell -Command でサンドボックス内から TCP 接続を試みる。
            # exit code ではなく stdout の文字列で結果を判定する。
            $probeCmd = @"
try {
    `$tc = New-Object Net.Sockets.TcpClient
    `$ar = `$tc.BeginConnect('$TargetHost', $Port, `$null, `$null)
    `$ok = `$ar.AsyncWaitHandle.WaitOne(5000)
    if (`$ok) { `$tc.EndConnect(`$ar); 'connected' } else { `$tc.Close(); 'timeout' }
} catch {
    if (`$_.Exception.Message -match 'denied|permitted|refused|blocked|firewall|access') { 'refused' } else { 'timeout' }
}
"@
            $out = & codex sandbox windows -C $env:TEMP powershell.exe -NoProfile -Command $probeCmd 2>&1
            $joined = ($out -join ' ')
            if ($joined -match 'connected') { Write-Output 'connected'; return }
            if ($joined -match 'refused') { Write-Output 'refused'; return }
            Write-Output 'timeout'
        }
        default { Write-Output 'timeout' }
    }
}

# --- Test-NetworkEgress ---
# 許可リストに無い実在ドメインへの送信が遮断されるかを実証する。
function Test-NetworkEgress([string]$Engine) {
    switch ($Engine) {
        'codex' {
            if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
                Write-Host "HOLD codex not installed"
                return 20
            }
            $result = Get-EgressProbe 'codex' 'example.com' 443
            return [int](Get-NetResultClass $result)
        }
        'agy' {
            Write-Host "HOLD agy network drill not supported (declaration-based)"
            return 20
        }
        default {
            Write-Host "HOLD unknown engine: $Engine"
            return 20
        }
    }
}

# --- Test-AgyDeclaration ---
# agy 専用の「宣言チェック」。金庫の効力は実証しない(spec §4 ④, option B)。
# agy バイナリが存在することだけを green の条件にする。
# launcher 側が --sandbox を強制適用する前提。
# 実証していないことは docs / 起動メッセージで明示する。
function Test-AgyDeclaration([string]$Engine) {
    # mac の drill_agy_declaration と同様、wrong-engine 呼び出しは HOLD(20)。
    if ($Engine -ne 'agy') {
        Write-Host "HOLD Test-AgyDeclaration called for wrong engine: $Engine"
        return 20
    }
    $agy = $env:AGY
    if (-not $agy) {
        $candidates = @(
            (Join-Path $env:LOCALAPPDATA 'Antigravity\agy.exe'),
            (Join-Path $env:USERPROFILE '.local\bin\agy.exe'),
            (Join-Path $env:USERPROFILE '.local\bin\agy')
        )
        foreach ($c in $candidates) {
            if (Test-Path -LiteralPath $c) { $agy = $c; break }
        }
        if (-not $agy) {
            $cmd = Get-Command agy -ErrorAction SilentlyContinue
            if ($cmd) { $agy = $cmd.Source }
        }
    }
    if (-not $agy -or -not (Test-Path -LiteralPath $agy -ErrorAction SilentlyContinue)) {
        Write-Host "FAIL agy not found (cannot enable auto)"
        return 10
    }
    Write-Host "PASS agy present (declaration-based, sandbox NOT independently verified)"
    return 0
}
