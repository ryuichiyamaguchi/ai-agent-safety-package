# 診断.ps1 — d-claude が「学校PCでバカ/設定が効かない/人によって違うエラー」の実態を1画面で吐き出す。
# 何も変更しない読み取り専用。結果をそのまま講師に送れば原因が特定できる。
param(
    [string]$Workspace = (Join-Path $HOME "Documents\my-ai-workspace")
)
$ErrorActionPreference = "Continue"
$OutputEncoding = [System.Text.Encoding]::UTF8
function Line($s){ Write-Host $s }
function OK($s){ Write-Host ("  [OK] " + $s) -ForegroundColor Green }
function WARN($s){ Write-Host ("  [注意] " + $s) -ForegroundColor Yellow }
function BAD($s){ Write-Host ("  [問題] " + $s) -ForegroundColor Red }

Line "============================================================"
Line "  d-claude 診断ツール（読み取り専用・何も変更しません）"
Line "============================================================"
Line ("日時: " + (Get-Date))
$up = $env:USERPROFILE; if (-not $up) { $up = $HOME }
Line ("USERPROFILE: " + $up)
Line ("PowerShell: " + $PSVersionTable.PSVersion.ToString())
Line ""

# 1) 必須コマンドの版（★ここのバラつきが「人によって違う」の主因）
Line "■ 1. ツールの版（人によって違う＝症状が変わる原因）"
$claudeVer = ""; try { $claudeVer = (& claude --version 2>&1 | Out-String).Trim() } catch { $claudeVer = "(取得失敗)" }
if ($claudeVer -and $claudeVer -notmatch "失敗") { OK ("Claude Code: " + $claudeVer) } else { BAD "Claude Code が見つからない/起動できない" }
$nodeVer = ""; try { $nodeVer = (& node --version 2>&1 | Out-String).Trim() } catch { $nodeVer = "" }
if ($nodeVer) { OK ("node: " + $nodeVer + "（MCP/ゲートウェイに必須）") } else { BAD "node が無い → 検索/画像/vision の MCP が動かない・ゲートウェイも動かない" }
Line ""

# 2) 安全機能が「実際に適用されるか」（★バカ/設定未適用の核心）
Line "■ 2. 安全ランチャーが機能を適用できるか（--help のフラグ検出）"
$help = ""; try { $help = (& claude --help 2>&1 | Out-String) } catch { $help = "" }
if (-not $help) { BAD "claude --help が取得できない → ランチャーが機能を付けられず“素のd-claude”化（=バカ＋ガード無し）" }
else {
    foreach($f in @("--settings","--setting-sources","--permission-mode","--append-system-prompt","--mcp-config")){
        if ($help -match [regex]::Escape($f)) { OK ($f + " 対応") }
        else { BAD ($f + " が --help に無い → この機能はスキップされる（版が古い/新しい/非対応）") }
    }
    if ($help -match "--append-system-prompt") { Line "    （正直プロンプト＝“自分はDeepSeek”の枠付け。無いと過剰申告でバカっぽくなる）" }
    if ($help -match "--mcp-config") { Line "    （MCP＝検索/画像/vision ツール。無いとツールが使えず“できない”連発）" }
}
Line ""

# 3) インストール本体（設定・ポリシー・フック・キー）
Line "■ 3. インストール状態（ファイル破損/未適用の確認）"
if (-not (Test-Path -LiteralPath $Workspace)) { BAD ("ワークスペースが無い: " + $Workspace); }
else {
    OK ("ワークスペース: " + $Workspace)
    $policy = Join-Path $Workspace ".ai-safety\policy\safety-policy.json"
    if (Test-Path -LiteralPath $policy) {
        try { $pv = (Get-Content -LiteralPath $policy -Raw -Encoding UTF8 | ConvertFrom-Json).packageVersion; OK ("policy: packageVersion=" + $pv) }
        catch { BAD "policy JSON を読めない（本当に破損 or 文字コード）。ガードは -Encoding UTF8 で読むので実害有無は doctor で確認" }
    } else { BAD "policy が無い（未インストール or 破損）" }

    $settings = Join-Path $Workspace ".claude\settings.json"
    if (Test-Path -LiteralPath $settings) {
        try {
            $sj = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
            $mode = $sj.permissions.defaultMode
            $denyN = @($sj.permissions.deny).Count
            $hookN = @($sj.hooks.PreToolUse).Count
            OK ("settings: defaultMode=" + $mode + " / deny件数=" + $denyN + " / PreToolUseフック=" + $hookN)
            if ($denyN -eq 0 -or $hookN -eq 0) { BAD "deny/フックが空 → deny/ask/allow が効かない（設定破損/未適用）" }
        } catch { BAD "settings.json が壊れている（JSONとして読めない＝破損）" }
    } else { BAD "settings.json が無い → deny/ask/allow が全く効かない" }

    $guard = Join-Path $Workspace ".ai-safety\hooks\windows\guard-bash.ps1"
    if (Test-Path -LiteralPath $guard) { OK "ガードフック(guard-bash.ps1)あり" } else { BAD "ガードフックが無い" }
}
Line ""

# 4) DeepSeek キー（「登録したのに登録しろと言われる」の確認）
Line "■ 4. DeepSeek キーの状態"
$auth = Join-Path $up ".deepseek-claude\auth"
if (Test-Path -LiteralPath $auth) {
    $bytes = [System.IO.File]::ReadAllBytes($auth)
    $txt = [System.IO.File]::ReadAllText($auth)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Line ("  ファイル: " + $auth + " / " + $bytes.Length + " バイト")
    if ($bytes.Length -eq 0) { BAD "キーが空（登録で貼り付けが取れていない）" }
    elseif ($hasBom) { BAD "先頭にBOMがある → for/f が読めず“未登録”扱いになる（要修正）" }
    elseif ($txt.Trim() -ne $txt) { WARN "前後に空白/改行がある → 無効トークンになりうる" }
    elseif ($txt -notmatch '^sk-') { WARN ("中身が sk- で始まらない（先頭: '" + $txt.Substring(0,[Math]::Min(4,$txt.Length)) + "'）") }
    else { OK ("キー形式OK（sk-…、" + $txt.Length + "文字）") }
} else { BAD ("キーファイルが無い: " + $auth + " → 別ユーザー(管理者実行)で保存された可能性") }
Line ""

# 5) d-claude コマンド登録（PATH）
Line "■ 5. d-claude コマンド登録（PATH）"
$bin = Join-Path $up ".ai-safety\bin"
$shim = Join-Path $bin "d-claude.cmd"
if (Test-Path -LiteralPath $shim) { OK ("シムあり: " + $shim) } else { BAD "d-claude.cmd が無い → setup-commands 未実行/失敗" }
$userPath = [Environment]::GetEnvironmentVariable('Path','User'); if (-not $userPath){$userPath=""}
if (($userPath.Split(';')) -contains $bin) { OK "ユーザーPATHに bin 登録済み（新しいターミナルで有効）" } else { BAD "bin が PATH に無い → どこからでも d-claude と打てない" }
Line ""

Line "============================================================"
Line "  診断おわり。[問題] の行が今のPCの原因です。この画面を講師に共有してください。"
Line "============================================================"
