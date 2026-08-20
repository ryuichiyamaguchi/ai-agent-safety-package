# setup-commands.ps1 — ターミナルから `codex-safe` / `monitor` 等を `.\` 無しで使えるようにする。
# %USERPROFILE%\.ai-safety\bin に短命名シム(.cmd)を生成し、そのフォルダをユーザー PATH に冪等追加する。
# シムにはワークスペース絶対パスを焼き込む(bin 配下は %~dp0 でワークスペースを特定できないため)。
# 既存のワークスペース直下 .cmd (v1.9.0) はそのまま残り、本 PATH 版と併存する。
param(
    [string]$Workspace = (Get-Location).Path,
    [string]$BinDir = (Join-Path $env:USERPROFILE ".ai-safety\bin")
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
function Get-DClaudeProfileDefinitionHits($Path) {
    $out = @()
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        $trim = $line.TrimStart()
        if ($trim.StartsWith("#")) { continue }
        $isFunction = ($trim -match '^function\s+(global:|script:)?d-claude(\s|\{|\()')
        $isAlias = ($trim -match '^(Set-Alias|New-Alias)\b' -and $trim -match '\bd-claude\b')
        if ($isFunction -or $isAlias) {
            $out += [pscustomobject]@{ LineNumber = $i + 1; Text = $trim }
        }
    }
    return $out
}

$hooksDir = Join-Path $Workspace ".ai-safety\hooks\windows"
if (-not (Test-Path -LiteralPath $hooksDir)) {
    throw "AI Safety package is not installed in workspace: $Workspace`n先に install-one-click.bat（または install.ps1）を実行してください。"
}

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

# name -> 呼び出すランチャー(ps1 or bat) と、-Workspace 引数の要否
# bat 指定は DeepSeek 起動チェーン等(同意ゲート込み)を call する用。
$cmds = @(
    @{ name = "codex-safe";  ps1 = "launch-codex-safe.ps1";  ws = $true },
    @{ name = "claude-safe"; ps1 = "launch-claude-safe.ps1"; ws = $true },
    @{ name = "agy-safe";    ps1 = "launch-agy-safe.ps1";    ws = $true },
    @{ name = "monitor";     ps1 = "open-monitor.ps1";       ws = $false },
    # OpenCode は「起動したフォルダ」が作業対象になるため、フォルダを受け取れる薄い
    # ラッパー (oc-safe.ps1) 経由で呼ぶ。ccmux / Zed のターミナルからも同じ 1 行で起動できる。
    @{ name = "oc-safe";     ps1 = "oc-safe.ps1";            ws = $true },
    @{ name = "d-claude";    bat = "deepseek\起動-Claude-DeepSeek.bat" }
)

# CP932 で書く(ワークスペースパスに日本語が含まれても cmd.exe が正しく読めるように)。
$cp932 = [System.Text.Encoding]::GetEncoding(932)
foreach ($c in $cmds) {
    if ($c.bat) {
        # .bat ターゲット(同意ゲート込みの DeepSeek 起動チェーン等)はそのまま call する。
        $target = Join-Path $hooksDir $c.bat
        $body = "@echo off`r`n" +
                "chcp 932 >nul`r`n" +
                "call `"$target`" %*`r`n"
    } else {
        $target = Join-Path $hooksDir $c.ps1
        $wsArg = ""
        if ($c.ws) { $wsArg = " -Workspace `"$Workspace`"" }
        $body = "@echo off`r`n" +
                "chcp 932 >nul`r`n" +
                "powershell -NoProfile -ExecutionPolicy Bypass -File `"$target`"$wsArg %*`r`n"
    }
    $dest = Join-Path $BinDir ($c.name + ".cmd")
    [System.IO.File]::WriteAllText($dest, $body, $cp932)
    Write-Host ("  生成: " + $dest)
}

# PATH 登録は Windows のみ(他 OS の User スコープは未サポート=テスト時はシム生成だけ確認できる)。
if ($IsWindows -eq $false) {
    Write-Host "(非 Windows 環境のため PATH 登録はスキップしました。シム生成のみ実施)"
    return
}

# ユーザー PATH に BinDir を冪等追加(setx は 1024 字切り詰めの罠があるため .NET API を使う)。
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($null -eq $userPath) { $userPath = "" }
$paths = $userPath.Split(';') | Where-Object { $_ -ne "" }
if ($paths -notcontains $BinDir) {
    $newPath = ($userPath.TrimEnd(';') + ';' + $BinDir).TrimStart(';')
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "ユーザー PATH に追加しました: $BinDir"
} else {
    Write-Host "ユーザー PATH には既に登録済みです: $BinDir"
}

# 現在開いているターミナルでも即使えるように(best-effort)。
if (($env:Path -split ';') -notcontains $BinDir) {
    $env:Path = $env:Path.TrimEnd(';') + ';' + $BinDir
}

# E: 野良 d-claude シャドーイング検出（自動修正はしない・警告のみ）。
# PowerShell は 関数/エイリアス（プロファイル定義）を PATH の .cmd より優先するため、野良の
# d-claude 関数があると、いま登録した正規シムをバイパスしてしまう（=素の claude+DeepSeek 化）。
$shadowFound = $false
foreach ($pn in @('AllUsersAllHosts','AllUsersCurrentHost','CurrentUserAllHosts','CurrentUserCurrentHost')) {
    $pp = $null
    if ($PROFILE) { $pp = $PROFILE.$pn }
    if ($pp -and (Test-Path -LiteralPath $pp)) {
        $hits = @(Get-DClaudeProfileDefinitionHits $pp)
        if ($hits.Count -gt 0) {
            if (-not $shadowFound) {
                Write-Warning "野良の d-claude 定義が PowerShell プロファイルに見つかりました。正規シムより優先され、バイパスの原因になります:"
                $shadowFound = $true
            }
            foreach ($h in $hits) { Write-Warning ("  " + $pp + " の " + $h.LineNumber + "行目: " + $h.Text) }
        }
    }
}
if ($shadowFound) {
    Write-Host "  → 対処: スタートフォルダの 11_野良d-claudeを退治 を実行すると、バックアップ付きでコメントアウトできます。" -ForegroundColor Yellow
    Write-Host "     手で直す場合は、上の行を削除するか行頭に # を付けて、新しいターミナルを開き直してください。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "完了しました。新しいターミナルを開くと、どのフォルダからでも次が使えます:"
Write-Host "  monitor       … 見守りモニターを開く"
Write-Host "  codex-safe    … 監視つき Codex を起動"
Write-Host "  claude-safe   … 監視つき Claude を起動"
Write-Host "  agy-safe      … 監視つき AntiGravity を起動"
Write-Host "  d-claude      … DeepSeek版 Claude Code を起動"
