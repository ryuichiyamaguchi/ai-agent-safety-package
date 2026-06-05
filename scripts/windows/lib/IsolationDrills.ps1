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
#
# codex 0.135 系の sandbox 検証について:
#   0.135 で `codex sandbox` の構文が変わった(旧 `codex sandbox windows` は動かない):
#     codex sandbox --permissions-profile <NAME> -C <DIR> <COMMAND...>
#   `--permissions-profile` は必須で、[permissions.<NAME>] テーブルを持つ config が要る。
#   正しいスキーマは sandbox_mode/network_access ではなく extends/network.enabled:
#     [permissions.safeprobe]
#     extends = ":workspace"
#     [permissions.safeprobe.network]
#     enabled = false
#   ユーザーの config に依存しないよう、ドリル専用の一時 CODEX_HOME を都度生成する。
#   probe 用 config にはネット遮断(safeprobe / netblock)と疎通基準(netbaseline)の
#   両プロファイルを書き込み、network ドリルのベースライン疎通確認に使う。
#
# 重要: Windows codex 0.135 の実際の sandbox 機構は AppContainer/制限ジョブ(macOS seatbelt 非等価)。
# `--permissions-profile`/`extends=":workspace"`/`network.enabled=false` が Windows codex で
# 同じように効くかは Windows 実機検証が必要。実挙動が不明なため、不確実なら HOLD(安全側)にする。
#
# workspace-write 相当では %TEMP% が常に書込可能になる可能性があるため、
# outside-write のプローブ先は %TEMP% でも workspace でもない実パス(%USERPROFILE% 配下の専用 dir)にする。
#
# network ドリルは 2 段方式(オフライン偽 PASS を防ぐ。mac とパリティ):
#   1. ベースライン疎通: ネット許可プロファイル(netbaseline)で IP 直 1.1.1.1:443 へ connect。
#      CONNECTED でなければ「この環境はオフライン/到達不能 → 遮断を実証できない」= HOLD。
#   2. ベースラインが CONNECTED のときだけ遮断プロファイル(netblock)で同じ宛先へ connect →
#      refused = PASS / connected = FAIL。
#   宛先は DNS 非依存にするため IP 直指定(1.1.1.1:443)。

Set-StrictMode -Off  # dot-source されるため呼び出し元スコープで未定義変数等による意図しないエラーが出ないよう StrictMode を Off にする

# 共通のドリル一時ファイル置き場の親(prune 用)。mac の $_AI_SAFE_PROBE_PARENT に対応。
$script:AiSafeProbeParent = Join-Path $env:USERPROFILE ".ai-safety"

# --- New-CodexProbeHome (内部ヘルパー) ---
# ドリル専用の一時 CODEX_HOME を作り、検証用プロファイルを書き込んでそのパスを返す。
# mac の _codex_probe_home に対応。失敗時は $null を返す。
#   safeprobe / netblock : ネット遮断(enabled=false)
#   netbaseline          : ネット許可(enabled=true) — ベースライン疎通確認用
function New-CodexProbeHome {
    $probeHome = Join-Path ([System.IO.Path]::GetTempPath()) ("aisafe-probe-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path $probeHome | Out-Null
    } catch {
        return $null
    }
    $configContent = @"
[permissions.safeprobe]
description = "Safe Auto Mode isolation drill: workspace write, network blocked"
extends = ":workspace"

[permissions.safeprobe.network]
enabled = false

[permissions.netblock]
description = "Safe Auto Mode network drill: network blocked"
extends = ":workspace"

[permissions.netblock.network]
enabled = false

[permissions.netbaseline]
description = "Safe Auto Mode network drill: baseline reachability (network allowed)"
extends = ":workspace"

[permissions.netbaseline.network]
enabled = true
"@
    [System.IO.File]::WriteAllText((Join-Path $probeHome "config.toml"), $configContent, [System.Text.Encoding]::UTF8)
    return $probeHome
}

# --- Test-WriteOutside ---
# 金庫の中から (a) workspace 内書込が成功し、(b) workspace 外書込が遮断される
# ことを両方実証する。両立して初めて PASS。
# mac の drill_write_outside に対応。
# 中断(launcher の 60 秒タイムアウト等)時もリークしないよう try/finally で一時資源を必ず掃除する。
# engine = 'codex' のとき実証。'agy' は実証不能につき HOLD 固定。
function Test-WriteOutside([string]$Engine) {
    switch ($Engine) {
        'codex' {
            if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
                Write-Host "HOLD codex not installed"
                return 20
            }
            # 旧 PID 衝突や過去のリーク残骸を念のため一括 prune(kill 残骸も回収)。
            Remove-Item -Recurse -Force -Path (Join-Path $script:AiSafeProbeParent ".sbprobe-out.*") -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path $script:AiSafeProbeParent -ErrorAction SilentlyContinue | Out-Null

            $probeHome = $null
            $inside = $null
            $outBase = $null
            $prevCodexHome = $env:CODEX_HOME
            try {
                $probeHome = New-CodexProbeHome
                if (-not $probeHome) {
                    Write-Host "HOLD could not create probe CODEX_HOME"
                    return 20
                }

                # inside = git リポジトリにして :workspace が cwd を正確に workspace root と解決するようにする。
                $inside = Join-Path ([System.IO.Path]::GetTempPath()) ("aisafe-in-" + [guid]::NewGuid().ToString("N"))
                New-Item -ItemType Directory -Force -Path $inside | Out-Null
                # git init: 失敗しても HOLD にしない(git 未インストール環境も許容)
                try { & git init -q $inside 2>$null | Out-Null } catch {}

                # outside = %TEMP% でも workspace でもない実パス(%USERPROFILE% 配下の専用 dir)。
                # workspace-write では %TEMP% が常に書込可能になる可能性があるため outside には使えない。
                # GUID 付きユニーク名で PID 再利用衝突を避ける(mac の mktemp -d 相当)。
                $outBase = Join-Path $script:AiSafeProbeParent (".sbprobe-out." + [guid]::NewGuid().ToString("N"))
                try {
                    New-Item -ItemType Directory -Force -Path $outBase | Out-Null
                } catch {
                    Write-Host "HOLD could not create outside dir under %USERPROFILE%"
                    return 20
                }
                $insideFile = Join-Path $inside "in.txt"
                $outsideFile = Join-Path $outBase "pwn.txt"

                # (a) inside-write: cmd /c "type nul > <path>" で inside に空ファイルを作る。
                # mac の /usr/bin/touch に相当する Windows の書込コマンド。
                $env:CODEX_HOME = $probeHome
                & codex sandbox --permissions-profile safeprobe -C $inside cmd.exe /c "type nul > `"$insideFile`"" 2>$null | Out-Null
                $inRc = $LASTEXITCODE
                # (b) outside-write
                & codex sandbox --permissions-profile safeprobe -C $inside cmd.exe /c "type nul > `"$outsideFile`"" 2>$null | Out-Null
                $outRc = $LASTEXITCODE

                $insideCreated = Test-Path -LiteralPath $insideFile
                $outsideCreated = Test-Path -LiteralPath $outsideFile

                # outside が作られた = 金庫に穴 = FAIL(最優先で検出)。
                if ($outsideCreated) {
                    Write-Host "FAIL workspace-outside write succeeded (sandbox leak)"
                    return 10
                }
                # inside が作られていない = サンドボックス自体が正常作業できていない(起動失敗/abort 等)。
                if (-not $insideCreated) {
                    Write-Host "HOLD inside-write did not succeed (rc=$inRc); cannot prove a working sandbox"
                    return 20
                }
                # outside-write は遮断されるべき(rc!=0 が期待)。万一 rc=0 で抜けたのにファイルが無い等の
                # 不可解ケースは保守的に HOLD。
                if ($outRc -eq 0) {
                    Write-Host "HOLD outside-write exited 0 but no file (indeterminate)"
                    return 20
                }
                Write-Host "PASS inside-write ok AND outside-write blocked"
                return 0
            } finally {
                # 中断・例外・正常 return どの経路でも一時資源を必ず掃除する。
                if ($prevCodexHome) { $env:CODEX_HOME = $prevCodexHome } else { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }
                if ($probeHome) { Remove-Item -Recurse -Force -LiteralPath $probeHome -ErrorAction SilentlyContinue }
                if ($inside)    { Remove-Item -Recurse -Force -LiteralPath $inside    -ErrorAction SilentlyContinue }
                if ($outBase)   { Remove-Item -Recurse -Force -LiteralPath $outBase   -ErrorAction SilentlyContinue }
            }
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
# 2 段プローブの結果を金庫判定に写像する(テスト容易性のため分離)。
# mac の classify_net_result <baseline> <blocked> に対応。
#   $Baseline : ベースライン疎通(ネット許可)プローブの結果 connected/refused/timeout
#   $Blocked  : 遮断プロファイルでのプローブ結果
#                sandbox-blocked  = sandbox 由来の遮断(EPERM 相当 / アクセス拒否)を実証
#                general-refused  = 一般的な ConnectionRefused(sandbox の実証にならない)
#                connected / timeout / skipped その他
# 判定(フェイルクローズ):
#   baseline が connected でない = この環境はオフライン/到達不能 → 遮断を実証できない → HOLD(20)
#   baseline=connected かつ blocked=sandbox-blocked → sandbox 遮断を実証 = PASS(0)
#   baseline=connected かつ blocked=connected       → 金庫に穴 = FAIL(10)
#   baseline=connected かつ blocked=general-refused → sandbox 由来でない拒否 → HOLD(20)
#   それ以外(blocked=timeout 等の判定不能)         → HOLD(20)
# 後方互換: $Blocked 省略の旧シグネチャ(connected/refused/timeout)も受ける。
#   ベースライン未確認では refused 単独を PASS にせず HOLD(fail-closed)。
function Get-NetResultClass([string]$Baseline, [string]$Blocked = "") {
    if ([string]::IsNullOrEmpty($Blocked)) {
        # 旧シグネチャ(ベースライン無し)。ベースライン未確認では PASS にしない。
        switch ($Baseline) {
            'connected' { Write-Host "FAIL egress connection succeeded"; return 10 }
            'refused'   { Write-Host "HOLD egress refused but baseline reachability not verified (offline?)"; return 20 }
            default     { Write-Host "HOLD egress result indeterminate (offline?)"; return 20 }
        }
    }
    if ($Baseline -ne 'connected') {
        Write-Host "HOLD network baseline not reachable (baseline=$Baseline); cannot prove egress block (offline?)"
        return 20
    }
    switch ($Blocked) {
        'sandbox-blocked' { Write-Host "PASS egress blocked by sandbox (access-denied/EPERM; baseline reachable)"; return 0 }
        'connected'       { Write-Host "FAIL egress connection succeeded despite block profile"; return 10 }
        'general-refused' { Write-Host "HOLD egress refused (ConnectionRefused — not sandbox-derived; cannot prove isolation)"; return 20 }
        default           { Write-Host "HOLD egress block result indeterminate (blocked=$Blocked)"; return 20 }
    }
}

# --- Get-EgressProbe (内部ヘルパー) ---
# 指定 permissions プロファイルの金庫の中から <host>:<port> へ TCP 接続を試み、
# "connected" / "refused" / "timeout" のいずれかを返す(Write-Output)。
# データは送らない(接続確立の可否のみ)。
# mac の _probe_egress <engine> <profile> <host> <port> に対応。
# mac は perl を使うが Windows 標準に perl は無いため、
# PowerShell の System.Net.Sockets.TcpClient で代替する。
# TcpClient 起動失敗・判定不能はすべて timeout(= 上位で HOLD)に倒す(fail-open 防止)。
# 中断時もリークしないよう try/finally で一時資源を掃除する。
# 注: $TargetHost / $ProfileName を使う($Host・$Profile は PowerShell 自動変数とシャドウするため避ける)。
function Get-EgressProbe([string]$Engine, [string]$ProfileName, [string]$TargetHost, [int]$Port) {
    switch ($Engine) {
        'codex' {
            $probeHome = $null
            $inside = $null
            $prevCodexHome = $env:CODEX_HOME
            try {
                $probeHome = New-CodexProbeHome
                if (-not $probeHome) { Write-Output 'timeout'; return }

                $inside = Join-Path ([System.IO.Path]::GetTempPath()) ("aisafe-eg-" + [guid]::NewGuid().ToString("N"))
                New-Item -ItemType Directory -Force -Path $inside | Out-Null
                try { & git init -q $inside 2>$null | Out-Null } catch {}

                # PowerShell の TcpClient で TCP connect(5 秒タイムアウト)。
                # 結果は stdout の文字列で判定する(exit code ではなく)。
                # F-A 修正: sandbox 由来の遮断(EPERM 相当 = AccessDenied / OperationNotPermitted)と
                # 一般的な ConnectionRefused(ECONNREFUSED)を区別して返す。
                #   sandbox-blocked → EPERM 系(seatbelt/AppContainer による遮断)
                #   general-refused → ECONNREFUSED 等(sandbox でない一般拒否)
                #   connected       → 接続成功(金庫に穴)
                #   timeout         → 判定不能(fail-closed 側に倒す)
                # SocketError プロパティが取れる場合はそちらを優先(より正確)。
                $probeCmd = @"
try {
    `$tc = New-Object System.Net.Sockets.TcpClient
    `$ar = `$tc.BeginConnect('$TargetHost', $Port, `$null, `$null)
    `$ok = `$ar.AsyncWaitHandle.WaitOne(5000)
    if (`$ok) { `$tc.EndConnect(`$ar); Write-Output 'connected' } else { `$tc.Close(); Write-Output 'timeout' }
} catch {
    `$ex = `$_.Exception
    # InnerException が SocketException なら SocketErrorCode で精密判定する。
    `$se = `$ex.InnerException -as [System.Net.Sockets.SocketException]
    if (-not `$se) { `$se = `$ex -as [System.Net.Sockets.SocketException] }
    if (`$se) {
        `$ec = `$se.SocketErrorCode.ToString()
        # AccessDenied / OperationNotPermitted は sandbox 由来の EPERM 相当。
        if (`$ec -match 'AccessDenied|OperationNotPermitted|NotPermitted') { Write-Output 'sandbox-blocked'; return }
        # ConnectionRefused は一般的な拒否 — sandbox の実証にならない。
        if (`$ec -match 'ConnectionRefused') { Write-Output 'general-refused'; return }
    }
    # SocketException 以外 / SocketErrorCode 不明: メッセージ文字列にフォールバック。
    `$msg = `$_.Exception.Message
    if (`$msg -match 'operation not permitted|not permitted') { Write-Output 'sandbox-blocked' }
    elseif (`$msg -match 'connection refused') { Write-Output 'general-refused' }
    else { Write-Output 'timeout' }
}
"@
                $env:CODEX_HOME = $probeHome
                $out = & codex sandbox --permissions-profile $ProfileName -C $inside powershell.exe -NoProfile -Command $probeCmd 2>&1

                $joined = ($out -join ' ')
                if ($joined -match 'connected')       { Write-Output 'connected';       return }
                if ($joined -match 'sandbox-blocked') { Write-Output 'sandbox-blocked'; return }
                if ($joined -match 'general-refused') { Write-Output 'general-refused'; return }
                Write-Output 'timeout'
            } finally {
                if ($prevCodexHome) { $env:CODEX_HOME = $prevCodexHome } else { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }
                if ($probeHome) { Remove-Item -Recurse -Force -LiteralPath $probeHome -ErrorAction SilentlyContinue }
                if ($inside)    { Remove-Item -Recurse -Force -LiteralPath $inside    -ErrorAction SilentlyContinue }
            }
        }
        default { Write-Output 'timeout' }
    }
}

# --- Test-NetworkEgress ---
# 2 段でネット遮断を実証する(フェイルクローズ。mac の drill_network_egress に対応):
#   1. ベースライン疎通: ネット許可プロファイル(netbaseline)で IP 直 1.1.1.1:443 へ connect。
#      CONNECTED でなければ「この環境はオフライン/到達不能 → 遮断を実証できない」= HOLD。
#   2. 遮断プロファイル(netblock)で同じ宛先へ connect → refused = PASS / connected = FAIL。
# 宛先は DNS 非依存にするため IP 直指定(1.1.1.1:443)。実ネットへデータは送らない(connect 試行のみ)。
function Test-NetworkEgress([string]$Engine) {
    switch ($Engine) {
        'codex' {
            if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
                Write-Host "HOLD codex not installed"
                return 20
            }
            $probeIp = '1.1.1.1'
            $probePort = 443
            $baseline = Get-EgressProbe 'codex' 'netbaseline' $probeIp $probePort
            # ベースラインが繋がらない時点で実証不能。遮断プローブを撃つ必要すら無いが、
            # 判定は Get-NetResultClass に一本化する。
            if ($baseline -eq 'connected') {
                $blocked = Get-EgressProbe 'codex' 'netblock' $probeIp $probePort
            } else {
                $blocked = 'skipped'
            }
            return [int](Get-NetResultClass $baseline $blocked)
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
