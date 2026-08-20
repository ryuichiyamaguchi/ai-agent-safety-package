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
# 動作確認済みの Claude Code 版との比較（版差＝「人により違う」「機能が黙って落ちる」の親玉）。
# 期待版の SSOT は policy の testedClaudeCodeVersion。
$expectedCc = ""
$polForVer = Join-Path $Workspace ".ai-safety\policy\safety-policy.json"
if (Test-Path -LiteralPath $polForVer) {
    try { $expectedCc = ([System.IO.File]::ReadAllText($polForVer, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).testedClaudeCodeVersion } catch { $expectedCc = "" }
}
if ($expectedCc) {
    $ccM = [regex]::Match([string]$claudeVer, '[0-9]+\.[0-9]+\.[0-9]+')
    if (-not $ccM.Success) { WARN ("Claude Code 期待版=" + $expectedCc + " / 実版=取得できず（動作確認済みの版に揃えてください）") }
    elseif ($ccM.Value -eq $expectedCc) { OK ("Claude Code 版が動作確認済みと一致 (" + $expectedCc + ")") }
    else { WARN ("Claude Code 版ちがい: 実版=" + $ccM.Value + " / 動作確認済み=" + $expectedCc + " → 揃えるには npm install -g @anthropic-ai/claude-code@" + $expectedCc) }
}
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
$dpapi = Join-Path $up ".ai-safety\deepseek.dpapi"
if (Test-Path -LiteralPath $dpapi) {
    # v1.17.0: 金庫(DPAPI)に入っている。中身は復号できるかどうかだけを見て、値も長さも出さない。
    try {
        $ss = ConvertTo-SecureString ((Get-Content -LiteralPath $dpapi -Raw).Trim())
        $b = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
        if ($b.StartsWith('v1:')) { $b = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b.Substring(3))) }
        if ($b -and $b.Trim()) { OK ("金庫に登録済み（" + $dpapi + "）。中身は暗号化されています") }
        else { BAD ("金庫のファイルはあるが中身が空: " + $dpapi) }
    } catch {
        BAD ("金庫のファイルを復号できません（PC を替えた／Windows を入れ直した可能性）: " + $dpapi + " → キーを作り直して登録し直してください")
    }
}
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
} elseif (-not (Test-Path -LiteralPath $dpapi)) {
    BAD ("キーが見つかりません（金庫 " + $dpapi + " / ファイル " + $auth + " のどちらにも無い） → 「登録-初回だけ」を実行してください")
}
if (Test-Path -LiteralPath $auth) {
    WARN ("平文のキーファイルがまだ残っています: " + $auth + " → 「キー削除」を実行するか、登録し直すと金庫へ移ります")
}
Line ""

# 5) DeepSeek 以外の API キーの保管状態
#    v1.17.1: ここは以前「4. DeepSeek キーの状態」の中に混ざっていた。AIコーチ（Gemini）の
#    平文が残っているだけで「DeepSeek の問題」と誤解される実機報告があったため、
#    キーごとに正しい節へ分けた（doctor.ps1 / doctor.sh は元からキー単位で報告している）。
#    平文の残骸は、環境変数（1Password の op run など）の有無に関係なく必ず見る。
Line "■ 5. DeepSeek 以外の API キーの状態（AIコーチ／Buffer）"
$secretDir = Join-Path $up ".ai-safety"
$otherKeys = @(
    @{ Name = "AIコーチ（Gemini）のキー"; Dpapi = "gemini.dpapi";      Legacy = (Join-Path $secretDir "gemini-api-key.txt") },
    @{ Name = "Gemini（有料）のキー";      Dpapi = "gemini-paid.dpapi"; Legacy = (Join-Path $secretDir "gemini-api-key-paid.txt") },
    @{ Name = "Buffer のキー";             Dpapi = "buffer.dpapi";      Legacy = (Join-Path $secretDir "buffer-api-key.txt") }
)
foreach ($k in $otherKeys) {
    $kDpapi = Join-Path $secretDir $k.Dpapi
    $kInVault = Test-Path -LiteralPath $kDpapi
    $kInPlain = Test-Path -LiteralPath $k.Legacy
    if ($kInVault) { OK ($k.Name + ": 金庫に登録済み（" + $kDpapi + "）") }
    if ($kInPlain) { WARN ($k.Name + ": 平文のキーファイルが残っています: " + $k.Legacy + " → 登録し直すと金庫へ移ります") }
    if (-not $kInVault -and -not $kInPlain) { Line ("  " + $k.Name + ": 未登録") }
}
# 「金庫へ書けなかった」履歴。平文が残る原因のほとんどはここなので、必ず見せる。
$migrateLog = Join-Path $up ".ai-safety\logs\secret-migrate-events.jsonl"
if (Test-Path -LiteralPath $migrateLog) {
    $fails = @(Get-Content -LiteralPath $migrateLog -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '"event":"(vault-write-failed|verify-failed)"' })
    if ($fails.Count -gt 0) {
        BAD ("金庫への書き込みに失敗した記録が " + $fails.Count + " 件あります（これが平文の残る原因です）")
        foreach ($raw in ($fails | Select-Object -Last 3)) { Line ("       " + $raw) }
        Line ("       記録の場所: " + $migrateLog)
    } else {
        OK "金庫への書き込みに失敗した記録はありません"
    }
}
Line ""

# 6) d-claude コマンド登録（PATH）
Line "■ 6. d-claude コマンド登録（PATH）"
$bin = Join-Path $up ".ai-safety\bin"
$shim = Join-Path $bin "d-claude.cmd"
if (Test-Path -LiteralPath $shim) { OK ("シムあり: " + $shim) } else { BAD "d-claude.cmd が無い → setup-commands 未実行/失敗" }
$userPath = [Environment]::GetEnvironmentVariable('Path','User'); if (-not $userPath){$userPath=""}
if (($userPath.Split(';')) -contains $bin) { OK "ユーザーPATHに bin 登録済み（新しいターミナルで有効）" } else { BAD "bin が PATH に無い → どこからでも d-claude と打てない" }
Line ""

# 7) d-claude の実体解決（どの d-claude が実際に呼ばれるか＝野良シャドーイング検出）
Line "■ 7. d-claude の実体（野良シャドーイング検出）"
Line "    ※ PowerShell は 関数/エイリアス を PATH の .cmd より優先します。学校PC上に野良の"
Line "       d-claude 関数（プロファイル定義）や別スクリプトがあると、正規ランチャーをバイパスして"
Line "       『素の claude + DeepSeek 化（=バカ）』『人により違う英語エラー』の原因になります。"
$legitDClaude = @($shim, (Join-Path $Workspace "d-claude.cmd"))
$winnerLegit = $false
$dcAll = @(Get-Command d-claude -All -ErrorAction SilentlyContinue)
if ($dcAll.Count -eq 0) {
    WARN "現在のセッションで d-claude が見つかりません（この診断は -NoProfile 実行のため、プロファイル定義の関数はここには出ません。下のプロファイル走査で確認します）"
} else {
    Line "    解決順（先頭 → が実際に呼ばれる勝者）:"
    for ($i = 0; $i -lt $dcAll.Count; $i++) {
        $c = $dcAll[$i]
        if ($c.Source) { $where = $c.Source }
        elseif ($c.CommandType -eq 'Alias') { $where = "エイリアス → " + [string]$c.Definition }
        elseif ($c.CommandType -eq 'Function') { $where = "関数（プロファイル等で定義）" }
        else { $where = [string]$c.Definition }
        $mark = if ($i -eq 0) { " -> " } else { "    " }
        Line ("    " + $mark + "[" + $c.CommandType + "] " + $where)
    }
    $winner = $dcAll[0]
    $winnerPath = ""
    if ($winner.Source) { $winnerPath = $winner.Source }
    $winnerLegit = (($winner.CommandType -eq 'Application') -or ($winner.CommandType -eq 'ExternalScript')) -and ($legitDClaude -contains $winnerPath)
    if ($winnerLegit) {
        OK ("d-claude の勝者は正規シムです: " + $winnerPath)
    } else {
        BAD "d-claude の勝者が正規シムではありません（野良の関数/エイリアス/別スクリプトが優先されています）"
        Line ("       正規シムの場所: " + $shim + "  または  " + (Join-Path $Workspace "d-claude.cmd"))
    }
}
# PowerShell プロファイル 4種を静的に走査（-NoProfile でも野良定義を必ず捕捉できる）。
Line "    ● PowerShell プロファイルの d-claude 定義を走査:"
$profileFound = $false
foreach ($pn in @('AllUsersAllHosts','AllUsersCurrentHost','CurrentUserAllHosts','CurrentUserCurrentHost')) {
    $pp = $null
    if ($PROFILE) { $pp = $PROFILE.$pn }
    if ($pp -and (Test-Path -LiteralPath $pp)) {
        $hits = @(Get-DClaudeProfileDefinitionHits $pp)
        if ($hits.Count -gt 0) {
            $profileFound = $true
            WARN ("プロファイルに d-claude の記述あり: " + $pn + " (" + $pp + ")")
            foreach ($h in $hits) { Line ("       " + $h.LineNumber + "行目: " + $h.Text) }
        }
    }
}
if (-not $profileFound) {
    OK "PowerShell プロファイルに d-claude の記述はありません（野良定義なし）"
} else {
    if ($winnerLegit) {
        Line "    ● 現在の診断では正規シムが勝っていますが、通常の PowerShell では"
        Line "       プロファイル関数が優先される可能性があります。"
    }
    Line "    ● 対処: 『11_野良d-claudeを退治』でバックアップ付きコメントアウトを実行するか、"
    Line "       上の該当行を手でコメントアウトして、新しいターミナルを開き直してください。"
}
# 他シムの勝者も軽く確認（同種のシャドーイングが無いか）。
Line "    ● 他コマンドの勝者（参考・勝者のみ表示）:"
foreach ($cmdName in @('claude-safe','codex-safe','agy-safe','monitor')) {
    $one = @(Get-Command $cmdName -All -ErrorAction SilentlyContinue)
    if ($one.Count -eq 0) { Line ("       " + $cmdName + ": （見つからない）") }
    else {
        $w = $one[0]
        if ($w.Source) { $wp = $w.Source } elseif ($w.CommandType -eq 'Function') { $wp = "関数（プロファイル定義）" } else { $wp = [string]$w.Definition }
        Line ("       " + $cmdName + ": [" + $w.CommandType + "] " + $wp)
    }
}
Line ""

Line "============================================================"
Line "  診断おわり。[問題] の行が今のPCの原因です。この画面を講師に共有してください。"
Line "============================================================"
