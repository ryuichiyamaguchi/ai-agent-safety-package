# 野良d-claudeを退治.ps1 — 正規シムを乗っ取る「野良の d-claude」を検出し、確認のうえ退避/無効化する。
# 破壊的操作を含むため、必ず「表示 → y/N 確認 → 退避/コメントアウト」の順で進む。確認前は一切ファイルを動かさない。
# 削除ではなく退避またはコメントアウト（バックアップ作成）を基本にし、誤爆時に戻せるようにする。
# PATH 順の変更や環境変数の書き換えはしない（footgun 回避）。退避のみ。
# 正規/野良の判定基準は 診断.ps1 と同一（%USERPROFILE%\.ai-safety\bin\d-claude.cmd と <workspace>\d-claude.cmd を正規とする）。
param(
    [string]$Workspace = (Join-Path $HOME "Documents\my-ai-workspace"),
    [switch]$Yes
)
$ErrorActionPreference = "Continue"
$OutputEncoding = [System.Text.Encoding]::UTF8

function Line($s){ Write-Host $s }
function OK($s){ Write-Host ("  [正規] " + $s) -ForegroundColor Green }
function WARN($s){ Write-Host ("  [注意] " + $s) -ForegroundColor Yellow }
function HIT($s){ Write-Host ("  [野良] " + $s) -ForegroundColor Red }
function Get-DClaudeProfileDefinitions($Path) {
    $defs = @()
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        $trim = $line.TrimStart()
        if ($trim.StartsWith("#")) { continue }

        if ($trim -match '^function\s+(global:|script:)?d-claude(\s|\{|\()') {
            $start = $i
            $end = $i
            $depth = 0
            $sawOpen = $false
            for ($j = $i; $j -lt $lines.Count; $j++) {
                $text = [string]$lines[$j]
                $open = ([regex]::Matches($text, '\{')).Count
                $close = ([regex]::Matches($text, '\}')).Count
                if ($open -gt 0) { $sawOpen = $true }
                $depth += ($open - $close)
                $end = $j
                if ($sawOpen -and $depth -le 0) { break }
            }
            $defs += [pscustomobject]@{ File = $Path; Start = $start; End = $end; LineNo = $start + 1; Text = $trim }
            $i = $end
        } elseif (($trim -match '^(Set-Alias|New-Alias)\b') -and ($trim -match '\bd-claude\b')) {
            $defs += [pscustomobject]@{ File = $Path; Start = $i; End = $i; LineNo = $i + 1; Text = $trim }
        }
    }
    return $defs
}
function Disable-DClaudeProfileDefinitions($Definitions, $BackupDir) {
    if (@($Definitions).Count -eq 0) { return 0 }

    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $changed = 0
    foreach ($group in ($Definitions | Group-Object File)) {
        $file = $group.Name
        if (-not (Test-Path -LiteralPath $file)) { continue }

        $leaf = Split-Path -Leaf $file
        $backup = Join-Path $BackupDir $leaf
        $n = 1
        while (Test-Path -LiteralPath $backup) { $backup = Join-Path $BackupDir ($leaf + "." + $n); $n++ }
        Copy-Item -LiteralPath $file -Destination $backup -Force

        $lines = @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)
        $disable = @{}
        foreach ($d in $group.Group) {
            for ($i = [int]$d.Start; $i -le [int]$d.End; $i++) { $disable[$i] = $true }
        }
        foreach ($idx in ($disable.Keys | Sort-Object)) {
            if ($idx -ge 0 -and $idx -lt $lines.Count) {
                $line = [string]$lines[$idx]
                if (-not $line.TrimStart().StartsWith("#")) {
                    $lines[$idx] = "# AI Safety disabled legacy d-claude: " + $line
                }
            }
        }
        [System.IO.File]::WriteAllLines($file, [string[]]$lines, (New-Object System.Text.UTF8Encoding($true)))
        OK ("コメントアウトしました: " + $file + "（バックアップ: " + $backup + "）")
        $changed++
    }
    return $changed
}

Line "============================================================"
Line "  野良 d-claude 退治ツール"
Line "  正規ランチャーを乗っ取る「野良の d-claude」を退避します"
Line "============================================================"
Line ("日時: " + (Get-Date))
$up = $env:USERPROFILE; if (-not $up) { $up = $HOME }
Line ("USERPROFILE: " + $up)
Line ("ワークスペース: " + $Workspace)
Line ""

# 正規シムの定義（診断.ps1 の $legitDClaude と同一基準）。
$bin  = Join-Path $up ".ai-safety\bin"
$shim = Join-Path $bin "d-claude.cmd"
$legitDClaude = @($shim, (Join-Path $Workspace "d-claude.cmd"))

Line "■ 正規シム（これは残します）:"
foreach ($lp in $legitDClaude) {
    if (Test-Path -LiteralPath $lp) { OK $lp } else { Line ("  （未設置）" + $lp) }
}
Line ""

# 1) d-claude の全解決を列挙（勝者＝先頭）。
Line "■ いまPCにある d-claude を全部さがします:"
$dcAll = @(Get-Command d-claude -All -ErrorAction SilentlyContinue)
if ($dcAll.Count -eq 0) {
    Line "  （PATH 上に d-claude コマンドは見つかりませんでした）"
} else {
    for ($i = 0; $i -lt $dcAll.Count; $i++) {
        $c = $dcAll[$i]
        if ($c.Source) { $where = $c.Source }
        elseif ($c.CommandType -eq 'Alias') { $where = "エイリアス → " + [string]$c.Definition }
        elseif ($c.CommandType -eq 'Function') { $where = "関数（プロファイル等で定義）" }
        else { $where = [string]$c.Definition }
        $mark = if ($i -eq 0) { " -> " } else { "    " }
        Line ("    " + $mark + "[" + $c.CommandType + "] " + $where)
    }
    Line "    （-> が、いま実際に呼ばれている『勝者』です）"
}
Line ""

# 2) 退避できる「野良ファイル」を抽出（正規シム以外の Application / ExternalScript 実体）。
$rogueFiles = New-Object System.Collections.Generic.List[string]
foreach ($c in $dcAll) {
    if (($c.CommandType -eq 'Application') -or ($c.CommandType -eq 'ExternalScript')) {
        $src = ""
        if ($c.Source) { $src = $c.Source }
        if ($src -and (Test-Path -LiteralPath $src)) {
            if ($legitDClaude -notcontains $src) {
                if (-not $rogueFiles.Contains($src)) { $rogueFiles.Add($src) }
            }
        }
    }
}

# 3) 既知の場所（npm グローバル等）も走査。PATH に載っていない残骸ファイルも拾う。
#    正規シムのある .ai-safety\bin も見るが、正規 d-claude.cmd は $legitDClaude 除外で必ず残る。
$scanDirs = @()
if ($env:APPDATA) { $scanDirs += (Join-Path $env:APPDATA "npm") }
$scanDirs += (Join-Path $up "AppData\Roaming\npm")
$scanDirs += $bin
$scanDirs = $scanDirs | Where-Object { $_ } | Select-Object -Unique
foreach ($d in $scanDirs) {
    if (Test-Path -LiteralPath $d) {
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter "d-claude*" -File -ErrorAction SilentlyContinue)) {
            $fp = $f.FullName
            if (($legitDClaude -notcontains $fp) -and (-not $rogueFiles.Contains($fp))) {
                $rogueFiles.Add($fp)
            }
        }
    }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $up (".ai-safety\backups\rogue-d-claude\" + $stamp)

# 4) PowerShell プロファイルの d-claude 定義を静的に走査（関数/エイリアスは確認後にコメントアウト）。
Line "■ PowerShell プロファイルの d-claude 定義:"
$profileDefs = @()
foreach ($pn in @('AllUsersAllHosts','AllUsersCurrentHost','CurrentUserAllHosts','CurrentUserCurrentHost')) {
    $pp = $null
    if ($PROFILE) { $pp = $PROFILE.$pn }
    if ($pp -and (Test-Path -LiteralPath $pp)) {
        $defs = @(Get-DClaudeProfileDefinitions $pp)
        if ($defs.Count -gt 0) {
            foreach ($d in $defs) {
                $profileDefs += [pscustomobject]@{ File = $pp; Start = $d.Start; End = $d.End; LineNo = $d.LineNo; Text = $d.Text }
            }
        }
    }
}
if ($profileDefs.Count -eq 0) {
    OK "プロファイルに d-claude の定義はありません"
} else {
    foreach ($ph in $profileDefs) {
        HIT ($ph.File + " の " + $ph.LineNo + "行目: " + $ph.Text)
    }
    Line ""
    Line "  ↑ これは PowerShell が .cmd より優先する古い定義です。"
    Line "     このツールでバックアップを作ってコメントアウトできます。"
}
Line ""

# 5) プロファイル定義のコメントアウト（確認前は何も書き換えない）。
$profileDisabled = 0
if ($profileDefs.Count -gt 0) {
    Line "■ コメントアウトする PowerShell プロファイル定義:"
    foreach ($ph in $profileDefs) { HIT ($ph.File + " の " + $ph.LineNo + "行目: " + $ph.Text) }
    Line ""
    Line ("  バックアップ先: " + $backupDir)
    $ansProfile = if ($Yes) { 'y' } else { Read-Host "これらをバックアップ付きでコメントアウトしますか？  y = 実行 / それ以外 = スキップ" }
    if ($ansProfile -eq 'y' -or $ansProfile -eq 'Y') {
        $profileDisabled = Disable-DClaudeProfileDefinitions $profileDefs $backupDir
    } else {
        Line "プロファイル定義は変更しませんでした。"
    }
    Line ""
}

# 6) 退避対象の提示 → 確認 → 退避（確認前は何も動かさない）。
if ($rogueFiles.Count -eq 0) {
    Line "------------------------------------------------------------"
    if ($profileDefs.Count -eq 0) {
        OK "野良は見つかりませんでした（正常です）。"
    } elseif ($profileDisabled -gt 0) {
        OK "プロファイルの古い d-claude 定義をコメントアウトしました。"
        Line "  次にやること:"
        Line "   1) いま開いているターミナル/PowerShell をすべて閉じる"
        Line "   2) 新しいターミナルを開いて『7_困ったとき診断』をもう一度実行する"
    } else {
        Line "  退避できるファイル形式の野良はありません（上のプロファイル定義は未変更です）。"
    }
    Line "------------------------------------------------------------"
    return
}

Line "■ 退避（＝バックアップへ移動）する野良ファイル:"
foreach ($rf in $rogueFiles) { HIT $rf }
Line ""
Line "  ※ 削除ではなく、下記フォルダへ『移動』します。まちがいのときは戻せます。"
Line ("  退避先: " + $backupDir)
Line ""

$ans = if ($Yes) { 'y' } else { Read-Host "これらを退避しますか？（元に戻せます）  y = 実行 / それ以外 = 中止" }
if ($ans -ne 'y' -and $ans -ne 'Y') {
    Line ""
    Line "中止しました。何も変更していません。"
    return
}

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$manifest = @()
$moved = 0
foreach ($rf in $rogueFiles) {
    try {
        $leaf = Split-Path -Leaf $rf
        $dest = Join-Path $backupDir $leaf
        $n = 1
        while (Test-Path -LiteralPath $dest) { $dest = Join-Path $backupDir ($leaf + "." + $n); $n++ }
        Move-Item -LiteralPath $rf -Destination $dest -Force
        $manifest += ($rf + "`t=>`t" + $dest)
        OK ("退避しました: " + $rf)
        $moved++
    } catch {
        WARN ("退避できませんでした（管理者権限が必要かもしれません）: " + $rf + " — " + $_.Exception.Message)
    }
}
if ($manifest.Count -gt 0) {
    $restoreNote = Join-Path $backupDir "戻し方.txt"
    $noteBody = "この中のファイルは『野良 d-claude 退治』で退避したものです。`r`n元に戻すには、下の各行の右側パスから左側パスへ、ファイルを移動し直してください。`r`n`r`n" + ($manifest -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($restoreNote, $noteBody, (New-Object System.Text.UTF8Encoding($true)))
}
Line ""
Line "------------------------------------------------------------"
Line ("  " + $moved + " 件を退避しました。")
Line "  次にやること:"
Line "   1) いま開いているターミナル/PowerShell をすべて閉じる"
Line "   2) 新しいターミナルを開いて『7_困ったとき診断』をもう一度実行する"
Line "   3) d-claude の『勝者』が正規シムになっていれば成功です:"
Line ("      " + $shim)
if ($profileDefs.Count -gt 0 -and $profileDisabled -eq 0) {
    Line "   ※ 上で表示した PowerShell プロファイルの d-claude 定義は未変更です。"
    Line "      必要ならこのツールを再実行してコメントアウトしてください。"
}
Line "------------------------------------------------------------"
