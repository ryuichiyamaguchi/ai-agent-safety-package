# auto-mode.test.ps1 — Safe Auto Mode の Windows テストハーネス。
# mac の scripts/macos/test/auto-mode.test.sh に対応。
# 実行: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\auto-mode.test.ps1
#
# 注意: pwsh/powershell が無い macOS では実行できない。Windows 実機で検証すること。

$ErrorActionPreference = 'Continue'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib    = Join-Path $here '..\lib\IsolationDrills.ps1'
$doctor = Join-Path $here '..\doctor.ps1'
$script:pass = 0
$script:fail = 0

function Ok([string]$m) { Write-Host "PASS $m"; $script:pass++ }
function Ng([string]$m) { Write-Host "FAIL $m"; $script:fail++ }

# ---- Task 7: IsolationDrills.ps1 の関数定義チェック + 分類ロジック ----

. $lib

if (Get-Command Test-WriteOutside -ErrorAction SilentlyContinue) {
    Ok 'Test-WriteOutside defined'
} else {
    Ng 'Test-WriteOutside defined'
}
if (Get-Command Test-NetworkEgress -ErrorAction SilentlyContinue) {
    Ok 'Test-NetworkEgress defined'
} else {
    Ng 'Test-NetworkEgress defined'
}
if (Get-Command Get-NetResultClass -ErrorAction SilentlyContinue) {
    Ok 'Get-NetResultClass defined'
} else {
    Ng 'Get-NetResultClass defined'
}
if (Get-Command Test-AgyDeclaration -ErrorAction SilentlyContinue) {
    Ok 'Test-AgyDeclaration defined'
} else {
    Ng 'Test-AgyDeclaration defined'
}

# 分類ロジックの単体検証: refused=0(PASS) / connected=10(FAIL) / timeout=20(HOLD)
$r1 = [int](Get-NetResultClass 'refused')
if ($r1 -eq 0)  { Ok 'classify refused=PASS' }   else { Ng "classify refused=PASS (got $r1)" }

$r2 = [int](Get-NetResultClass 'connected')
if ($r2 -eq 10) { Ok 'classify connected=FAIL' } else { Ng "classify connected=FAIL (got $r2)" }

$r3 = [int](Get-NetResultClass 'timeout')
if ($r3 -eq 20) { Ok 'classify timeout=HOLD' }   else { Ng "classify timeout=HOLD (got $r3)" }

# ---- Task 8: doctor.ps1 -IsolationCheck ----

# 未知 engine は必ず非0(フェイルクローズ)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $doctor -IsolationCheck bogus *> $null
if ($LASTEXITCODE -ne 0) {
    Ok 'isolation-check unknown engine non-zero'
} else {
    Ng 'isolation-check unknown engine non-zero'
}

# codex 未導入環境でも「実行できる」ことを確認(0 or 非0 どちらでも可。127=not found は除く)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $doctor -IsolationCheck codex *> $null
$rcCodex = $LASTEXITCODE
if ($rcCodex -ne 127) {
    Ok "doctor -IsolationCheck codex runs (rc=$rcCodex)"
} else {
    Ng 'doctor -IsolationCheck codex not found'
}

# ---- Task 9: launch-codex-safe.ps1 --auto 分岐 ----

$launchC = Join-Path $here '..\launch-codex-safe.ps1'

# テスト用ワークスペース + policy ファイルを作成
$ws = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("ws-" + [guid]::NewGuid().ToString("N"))) -Force
New-Item -ItemType Directory -Path (Join-Path $ws '.ai-safety\policy') -Force | Out-Null
'{}' | Set-Content (Join-Path $ws '.ai-safety\policy\safety-policy.json')

# doctor スタブ: exit 0(green) / exit 1(red) を返す cmd ファイル
$stubOk = Join-Path ([System.IO.Path]::GetTempPath()) ('stub-ok-' + [guid]::NewGuid().ToString("N") + '.cmd')
$stubNg = Join-Path ([System.IO.Path]::GetTempPath()) ('stub-ng-' + [guid]::NewGuid().ToString("N") + '.cmd')
'@exit /b 0' | Set-Content $stubOk
'@echo FAIL egress indeterminate' | Out-File $stubNg -Encoding ASCII -Append
'@exit /b 1'  | Out-File $stubNg -Encoding ASCII -Append

# green: doctor が exit 0 → on-failure に解放
$env:AI_SAFE_DRY_RUN = '1'; $env:AI_SAFE_DOCTOR = $stubOk
$outOk = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchC $ws.FullName '' '--auto' 2>$null
if ($outOk -match 'on-failure') {
    Ok 'win codex green -> on-failure'
} else {
    Ng "win codex green -> on-failure (got: $outOk)"
}

# 赤: doctor が exit 1 → untrusted にフォールバック
$env:AI_SAFE_DOCTOR = $stubNg
$outNg = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchC $ws.FullName '' '--auto' 2>$null
if ($outNg -match 'untrusted') {
    Ok 'win codex red -> untrusted'
} else {
    Ng "win codex red -> untrusted (got: $outNg)"
}

# 赤のとき stderr に理由が出る
$errNg = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchC $ws.FullName '' '--auto' 2>&1
$errNgText = ($errNg -join ' ')
if ($errNgText -match 'オートを有効にできません') {
    Ok 'win codex red shows reason'
} else {
    Ng "win codex red shows reason (got: $errNgText)"
}

# --auto 無し: 従来どおり untrusted(回帰)
Remove-Item Env:\AI_SAFE_DOCTOR -ErrorAction SilentlyContinue
$env:AI_SAFE_DRY_RUN = '1'
$outDef = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchC $ws.FullName '' 2>$null
if ($outDef -match 'untrusted') {
    Ok 'win codex no-auto stays untrusted'
} else {
    Ng "win codex no-auto stays untrusted (got: $outDef)"
}

# doctor 不在 → フェイルクローズ(untrusted)
$env:AI_SAFE_DOCTOR = 'C:\nonexistent\doctor.ps1'
$outMiss = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchC $ws.FullName '' '--auto' 2>$null
if ($outMiss -match 'untrusted') {
    Ok 'win codex missing-doctor -> untrusted (fail-closed)'
} else {
    Ng "win codex missing-doctor LEAKS to on-failure (got: $outMiss)"
}

# doctor が cmd だが存在しない → フェイルクローズ
$env:AI_SAFE_DOCTOR = 'C:\nonexistent\doctor.cmd'
$outMissCmd = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchC $ws.FullName '' '--auto' 2>$null
if ($outMissCmd -match 'untrusted') {
    Ok 'win codex missing-doctor-cmd -> untrusted (fail-closed)'
} else {
    Ng "win codex missing-doctor-cmd LEAKS to on-failure (got: $outMissCmd)"
}

Remove-Item Env:\AI_SAFE_DRY_RUN, Env:\AI_SAFE_DOCTOR -ErrorAction SilentlyContinue

# ---- Task 10: launch-agy-safe.ps1 --auto 分岐 ----

$launchA = Join-Path $here '..\launch-agy-safe.ps1'

# green: doctor 0 → --dangerously-skip-permissions が付く(--sandbox は維持)
$env:AGY = $stubOk; $env:AI_SAFE_DRY_RUN = '1'; $env:AI_SAFE_DOCTOR = $stubOk
$outAOk = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchA $ws.FullName '' '--auto' 2>$null
if ($outAOk -match '--sandbox') {
    Ok 'win agy --auto green keeps --sandbox'
} else {
    Ng "win agy --auto green keeps --sandbox (got: $outAOk)"
}
if ($outAOk -match '--dangerously-skip-permissions') {
    Ok 'win agy green -> skip-permissions'
} else {
    Ng "win agy green -> skip-permissions (got: $outAOk)"
}

# green でも未実証の caveat が stderr に出る
$errAOk = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchA $ws.FullName '' '--auto' 2>&1
$errAOkText = ($errAOk -join ' ')
if ($errAOkText -match '未検証|未実証|verified') {
    Ok 'win agy green shows unverified caveat'
} else {
    Ng "win agy green shows unverified caveat (got: $errAOkText)"
}

# 赤(doctor 非0): --dangerously-skip-permissions を付けずフォールバック + 理由表示
$env:AI_SAFE_DOCTOR = $stubNg
$errANg = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchA $ws.FullName '' '--auto' 2>&1
$errANgText = ($errANg -join ' ')
if ($errANgText -match 'オートを有効にできません') {
    Ok 'win agy red shows reason'
} else {
    Ng "win agy red shows reason (got: $errANgText)"
}

$outANg = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchA $ws.FullName '' '--auto' 2>$null
if ($outANg -match '--sandbox') {
    Ok 'win agy red still launches with --sandbox'
} else {
    Ng "win agy red launch broken (got: $outANg)"
}
if ($outANg -match '--dangerously-skip-permissions') {
    Ng 'win agy red must NOT have skip-permissions'
} else {
    Ok 'win agy red stays safe (no skip-permissions)'
}

# --auto 無し: 従来どおり --sandbox のみ
Remove-Item Env:\AI_SAFE_DOCTOR -ErrorAction SilentlyContinue
$outADef = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchA $ws.FullName '' 2>$null
if ($outADef -match '--sandbox') {
    Ok 'win agy no-auto launches (--sandbox only)'
} else {
    Ng "win agy no-auto launches broken (got: $outADef)"
}
if ($outADef -match '--dangerously-skip-permissions') {
    Ng 'win agy no-auto must NOT have skip-permissions'
} else {
    Ok 'win agy no-auto has no skip-permissions'
}

# doctor 不在 → フェイルクローズ(skip-permissions 無し)
$env:AI_SAFE_DOCTOR = 'C:\nonexistent\doctor.ps1'
$outMissA = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchA $ws.FullName '' '--auto' 2>$null
if ($outMissA -match '--dangerously-skip-permissions') {
    Ng 'win agy missing-doctor LEAKS skip-permissions'
} else {
    Ok 'win agy missing-doctor -> no skip-permissions (fail-closed)'
}

Remove-Item Env:\AGY, Env:\AI_SAFE_DRY_RUN, Env:\AI_SAFE_DOCTOR -ErrorAction SilentlyContinue

# ---- Task 10 (フル doctor): 隔離ドリル行を出力するか ----

$fullOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $doctor $ws.FullName 2>$null
$fullOutText = ($fullOut -join ' ')
if ($fullOutText -match 'isolation|egress|workspace-outside') {
    Ok 'win full doctor reports isolation'
} else {
    Ng 'win full doctor reports isolation'
}

# ---- クリーンアップ ----

Remove-Item -LiteralPath $stubOk, $stubNg -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force -LiteralPath $ws.FullName -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "auto-mode.test summary: pass=$($script:pass) fail=$($script:fail)"
if ($script:fail -ne 0) { exit 1 } else { exit 0 }
