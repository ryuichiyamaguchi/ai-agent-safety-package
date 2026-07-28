# install-hash.test.ps1 — install.ps1 の配布ハッシュ検証まわりの回帰テスト。
#
# 出荷ファイル (scripts\windows\install.ps1) から AST で検証関数だけを取り出し、
# 使い捨ての fixture パッケージに対して実際に呼び出して挙動を確かめる。
#
# 守りたい退行は 3 つ:
#   (1) 文字コード (RED-3): docs\tested_versions.md は BOM なし UTF-8 で日本語ファイル名の
#       行を含む。-Encoding 未指定だと Windows PowerShell 5.1 が既定 ANSI (日本語環境では
#       CP932) として読み、日本語パスの行が拾えず「一覧に無い / ハッシュ行が無い」と誤判定して
#       改ざんが素通りする。-Encoding UTF8 で拾えること、ANSI 読みでは拾えないことの両方を見る。
#   (2) 指示書の登録漏れ (YELLOW-1): opencode-harness / dist-skills 配下にハッシュ行の無い
#       .md があれば中止すること。一般ファイルは警告のみで続行すること。
#   (3) 検証表そのものの欠落 (Y-6): docs\tested_versions.md が無ければ中止すること。
#
# 実行: pwsh -NoProfile -File scripts\windows\test\install-hash.test.ps1
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installPs1 = (Resolve-Path (Join-Path $here '..\install.ps1')).Path
$script:pass = 0; $script:fail = 0
function Ok($m){ Write-Host "PASS $m"; $script:pass++ }
function Ng($m){ Write-Host "FAIL $m"; $script:fail++ }
# 中止したことだけでなく「中止の理由」まで見る。無関係な例外（タイプミス・
# パス誤りなど）を「正しく中止した」と誤認すると、検査が常に合格になってしまう。
function Throws([scriptblock]$sb, [string]$Expect){
    try { & $sb | Out-Null; return $false }
    catch {
        if ($Expect -and ($_.Exception.Message -notlike ("*" + $Expect + "*"))) {
            Ng ("想定と違う理由で中止した: " + $_.Exception.Message)
            return $false
        }
        return $true
    }
}

# --- 出荷ファイルから検証関数と設定を取り出す -------------------------------
$errs = $null; $toks = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installPs1, [ref]$toks, [ref]$errs)
if ($errs) { Ng ("install.ps1 の構文解析に失敗: " + ($errs -join '; ')); exit 1 }

foreach ($name in @('Assert-VersionsTable','Test-DistributionHash','Test-DistributionHashListed')) {
    $fn = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    }, $true)
    if (-not $fn) { Ng "install.ps1 に関数 $name が無い"; exit 1 }
    Invoke-Expression $fn.Extent.Text
}
$prefixAssign = $ast.Find({
    param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$hashListingRequiredPrefixes'
}, $true)
if (-not $prefixAssign) { Ng 'install.ps1 に $hashListingRequiredPrefixes の定義が無い'; exit 1 }
Invoke-Expression $prefixAssign.Extent.Text

# 静的検査: 検証表を -Encoding 未指定で読む Get-Content が残っていないこと。
$installText = Get-Content -LiteralPath $installPs1 -Encoding UTF8 -Raw
$readCalls = [regex]::Matches($installText, 'Get-Content[^\r\n]*\$versionsFile[^\r\n]*')
if ($readCalls.Count -eq 0) {
    Ng '検証表を読む Get-Content が見つからない (検査が空振りしている)'
} else {
    $bad = @($readCalls | Where-Object { $_.Value -notmatch '-Encoding\s+UTF8' })
    if ($bad.Count -eq 0) { Ok ("検証表を読む Get-Content " + $readCalls.Count + " 箇所すべてに -Encoding UTF8 がある") }
    else { Ng ("-Encoding UTF8 の無い Get-Content: " + ($bad.Value -join ' / ')) }
}

# --- fixture パッケージを作る -----------------------------------------------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$fx = Join-Path ([System.IO.Path]::GetTempPath()) ("instfx-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $fx 'docs') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fx 'workspace-template\opencode-harness\commands') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fx 'configs') -Force | Out-Null

$jpRel  = 'workspace-template/opencode-harness/commands/そうだん.md'
$asciiRel = 'workspace-template/opencode-harness/AGENTS.md'
$jpAbs = Join-Path $fx ($jpRel -replace '/', '\')
$asciiAbs = Join-Path $fx ($asciiRel -replace '/', '\')
[System.IO.File]::WriteAllText($jpAbs, "そうだん の本文`n", $utf8NoBom)
[System.IO.File]::WriteAllText($asciiAbs, "harness body`n", $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $fx 'configs\general.md'), "general`n", $utf8NoBom)

$jpSha = (Get-FileHash -LiteralPath $jpAbs -Algorithm SHA256).Hash.ToLower()
$asciiSha = (Get-FileHash -LiteralPath $asciiAbs -Algorithm SHA256).Hash.ToLower()
$table = "# tested versions (fixture)`r`n`r`n| ファイル | SHA-256 |`r`n|---|---|`r`n| $jpRel | $jpSha |`r`n| $asciiRel | $asciiSha |`r`n"

# 配布物と同じ条件: BOM なし UTF-8
$packageRoot = $fx
$versionsFile = Join-Path $fx 'docs\tested_versions.md'
[System.IO.File]::WriteAllText($versionsFile, $table, $utf8NoBom)

$env:AI_SAFE_ALLOW_HASH_MISMATCH = $null
$env:AI_SAFE_ALLOW_UNLISTED_HARNESS = $null

# --- (1) 文字コード ----------------------------------------------------------
if (-not (Throws { Test-DistributionHash $jpRel })) { Ok '日本語名ファイル: ハッシュ一致なら通る' }
else { Ng '日本語名ファイル: 一致しているのに中止した' }

[System.IO.File]::WriteAllText($jpAbs, "書き換えられた本文`n", $utf8NoBom)
if (Throws { Test-DistributionHash $jpRel } 'ハッシュ不一致') { Ok '日本語名ファイル: 改ざんを検出して中止する (RED-3)' }
else { Ng '日本語名ファイル: 改ざんを検出できず素通りした (RED-3 の退行)' }
[System.IO.File]::WriteAllText($jpAbs, "そうだん の本文`n", $utf8NoBom)

# ANSI (日本語 Windows では CP932) で読むと日本語行が拾えないこと = -Encoding UTF8 が
# 効いていることの裏付け。PS 5.1 は数値コードページを受け付けないので 'Default'
# (= その PC の ANSI コードページ) を使う。
$ansiEnc = if ($PSVersionTable.PSVersion.Major -ge 6) { 932 } else { 'Default' }
$hitUtf8 = @(Get-Content -LiteralPath $versionsFile -Encoding UTF8 | Where-Object { $_.Contains("| $jpRel |") }).Count
try {
    $hitAnsi = @(Get-Content -LiteralPath $versionsFile -Encoding $ansiEnc | Where-Object { $_.Contains("| $jpRel |") }).Count
    if ($hitUtf8 -ge 1 -and $hitAnsi -eq 0) { Ok ("同じ表: UTF8 読み=" + $hitUtf8 + "行 / ANSI(" + $ansiEnc + ")読み=" + $hitAnsi + "行 (日本語行は ANSI では拾えない)") }
    else { Ng ("文字コードの前提が崩れている: UTF8=" + $hitUtf8 + " ANSI=" + $hitAnsi) }
    $hitAnsiAscii = @(Get-Content -LiteralPath $versionsFile -Encoding $ansiEnc | Where-Object { $_.Contains("| $asciiRel |") }).Count
    if ($hitAnsiAscii -ge 1) { Ok 'ASCII 名の行は ANSI 読みでも拾える (穴は日本語名だけだった)' }
    else { Ng 'ASCII 名の行まで ANSI 読みで落ちている (fixture がおかしい)' }
} catch {
    Write-Host ("SKIP ANSI 読みの比較 (この環境では -Encoding " + $ansiEnc + " が使えない): " + $_.Exception.Message)
}

# Windows PowerShell 5.1 の既定読みを再現する。出荷関数の -Encoding UTF8 だけを ANSI に
# 差し替えた影武者を作り、同じ改ざんを**検出できない**ことを見せる (直った内容の裏取り。
# pwsh 7 の Get-Content は既定が UTF-8 なので、素の実行では PS 5.1 の事故を再現できない)。
$fnText = ($ast.Find({
    param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-DistributionHash'
}, $true)).Extent.Text
$ansiFnText = $fnText.Replace('function Test-DistributionHash(', 'function Test-DistributionHashAnsi(').Replace('-Encoding UTF8', "-Encoding $ansiEnc")
try {
    Invoke-Expression $ansiFnText
    [System.IO.File]::WriteAllText($jpAbs, "書き換えられた本文`n", $utf8NoBom)
    $ansiCaught = Throws { Test-DistributionHashAnsi $jpRel } 'ハッシュ不一致'
    $utf8Caught = Throws { Test-DistributionHash $jpRel } 'ハッシュ不一致' 
    [System.IO.File]::WriteAllText($jpAbs, "そうだん の本文`n", $utf8NoBom)
    if ($utf8Caught -and -not $ansiCaught) { Ok 'PS 5.1 既定 (ANSI) 読みの影武者は同じ改ざんを見逃す = -Encoding UTF8 が効いている' }
    else { Ng ("影武者比較が想定外: UTF8検出=" + $utf8Caught + " ANSI検出=" + $ansiCaught) }
} catch {
    Write-Host ("SKIP 影武者比較: " + $_.Exception.Message)
}

# --- (2) 指示書の登録漏れ ----------------------------------------------------
$unlistedRel = 'workspace-template/opencode-harness/commands/よぶんな.md'
[System.IO.File]::WriteAllText((Join-Path $fx ($unlistedRel -replace '/', '\')), "混入`n", $utf8NoBom)
if (Throws { Test-DistributionHashListed $unlistedRel } '一覧に登録されていません') { Ok '指示書: ハッシュ行の無い .md が混入したら中止する (YELLOW-1)' }
else { Ng '指示書: ハッシュ行の無い .md が警告だけで配置される (YELLOW-1 の退行)' }

$env:AI_SAFE_ALLOW_UNLISTED_HARNESS = '1'
if (-not (Throws { Test-DistributionHashListed $unlistedRel })) { Ok '指示書: 講師向け override (AI_SAFE_ALLOW_UNLISTED_HARNESS=1) で続行できる' }
else { Ng '指示書: override を設定しても中止した' }
$env:AI_SAFE_ALLOW_UNLISTED_HARNESS = $null

if (-not (Throws { Test-DistributionHashListed 'configs/general.md' })) { Ok '一般ファイル: 未登録でも警告のみで続行する (受講者の導入を止めない)' }
else { Ng '一般ファイル: 未登録で中止した (止めすぎ)' }

# --- (3) 検証表そのものの欠落 ------------------------------------------------
Remove-Item -LiteralPath $versionsFile -Force
if (Throws { Assert-VersionsTable } '見つかりません') { Ok '検証表が無ければ中止する (Y-6)' }
else { Ng '検証表が無いのに続行した (Y-6 の退行)' }

$env:AI_SAFE_ALLOW_HASH_MISMATCH = '1'
if (-not (Throws { Assert-VersionsTable })) { Ok '検証表が無くても override (AI_SAFE_ALLOW_HASH_MISMATCH=1) なら続行できる' }
else { Ng '検証表の欠落で override が効かない' }
$env:AI_SAFE_ALLOW_HASH_MISMATCH = $null

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("install-hash.test: pass=" + $script:pass + " fail=" + $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
