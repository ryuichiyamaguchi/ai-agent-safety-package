# agent-monitor: 「いま AI がしようとしていること」表示の入口 (Windows)
# SafetyPolicy.ps1 が source 済みであることを前提とする（Write-AuditLog を使う）。
# 公開関数: Invoke-Explain（フェイルセーフ。失敗してもポリシー判定を阻害しない）
#
# v1.19.0: 解説の本体は scripts\common\explainer.js（Node・Mac/Windows 共通の 1 本）へ移した。
#   以前はここに約 1,000 行の解説エンジンがあり、mac の explainer.sh と二重実装だった。
#   ここに残すのは (1) explainer.js を呼ぶ入口 (2) Node が見つからないときの簡易表示
#   (3) 待機画面（open-monitor.ps1 が使う）と、guard-bash.ps1 が使う HTML 部品。
#   ★ 危険コマンドを止める判定（SafetyPolicy.ps1）とは無関係。ここが壊れても判定は変わらない。

Set-StrictMode -Version 2.0

# カード配置ディレクトリ。
#   導入後:  <ws>\.ai-safety\hooks\windows\lib\Explainer.ps1 → <ws>\.ai-safety\cards
#   開発時:  <repo>\scripts\windows\lib\Explainer.ps1        → <repo>\configs\safety\cards
# （v1.19.0 で開発時の探し先を修正。以前は 1 段上のフォルダを探していて見つからなかった）
function Get-CardsDir {
    if ($env:AI_SAFE_CARDS_DIR) { return $env:AI_SAFE_CARDS_DIR }
    $here = $PSScriptRoot
    # v1.19.9: Join-Path / Test-Path / Resolve-Path は使わない（SafetyPolicy.ps1 の Get-SafetyPolicyPath の説明を参照）。
    $guess = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($here, '..', '..', '..', 'cards'))
    if ([System.IO.Directory]::Exists($guess)) { return $guess }
    $dev = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($here, '..', '..', '..', 'configs', 'safety', 'cards'))
    if ([System.IO.Directory]::Exists($dev)) { return $dev }
    return ""
}

function Get-ExplainLogDir {
    $logDir = $env:AI_SAFE_LOG_DIR
    if (-not $logDir) { $logDir = [System.IO.Path]::Combine($HOME, '.ai-safety', 'logs') }
    return $logDir
}

# explainer.js を動かす node。テスト用に AI_SAFE_EXPLAINER_NODE が設定されていればそれだけを使う。
function Resolve-ExplainerNode {
    if ($null -ne $env:AI_SAFE_EXPLAINER_NODE) {
        if ($env:AI_SAFE_EXPLAINER_NODE -and [System.IO.File]::Exists($env:AI_SAFE_EXPLAINER_NODE)) { return $env:AI_SAFE_EXPLAINER_NODE }
        return $null
    }
    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:NODE_BIN) { [void]$cands.Add($env:NODE_BIN) }
    try {
        $cmd = Get-Command node -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { [void]$cands.Add([string]$cmd.Source) }
    } catch { }
    foreach ($base in @($env:ProgramFiles, $env:APPDATA)) {
        if (-not $base) { continue }
        try {
            [void]$cands.Add([System.IO.Path]::Combine($base, 'nodejs', 'node.exe'))
            [void]$cands.Add([System.IO.Path]::Combine($base, 'npm', 'node.exe'))
        } catch { }
    }
    foreach ($c in $cands) {
        if ($c -and [System.IO.File]::Exists($c)) { return $c }
    }
    return $null
}

# ----- HTML 部品（guard-bash.ps1 / open-monitor.ps1 と Node が無いときの簡易表示で使う） -----

function ConvertTo-HtmlEscaped([string]$Text) {
    if ($null -eq $Text) { return "" }
    $t = $Text -replace "&", "&amp;"
    $t = $t -replace "<", "&lt;"
    $t = $t -replace ">", "&gt;"
    $t = $t -replace '"', "&quot;"
    return $t
}

function Get-NowHtmlHead([int]$Refresh) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<!DOCTYPE html>`n<html lang=`"ja`">`n<head>`n")
    [void]$sb.Append("<meta charset=`"utf-8`">`n")
    [void]$sb.Append("<meta http-equiv=`"refresh`" content=`"$Refresh`">`n")
    [void]$sb.Append("<meta name=`"viewport`" content=`"width=device-width, initial-scale=1`">`n")
    [void]$sb.Append("<title>agent-monitor — AI の動きを見る</title>`n")
    [void]$sb.Append("<style>`n")
    [void]$sb.Append("*{box-sizing:border-box}`n")
    [void]$sb.Append("body{margin:0;padding:16px;font-family:'Yu Gothic','Meiryo',sans-serif;background:#0f1115;color:#e6e6e6;word-break:keep-all;line-height:1.7}`n")
    [void]$sb.Append(".wrap{max-width:880px;margin:0 auto}`n")
    [void]$sb.Append("h1.hdr{font-size:18px;margin:0 0 14px;color:#9ad}`n")
    [void]$sb.Append(".card{border-radius:12px;padding:18px 20px;margin-bottom:20px;border-left:8px solid #888;background:#1a1d24}`n")
    [void]$sb.Append(".card-high{border-left-color:#e5534b;background:#2a1718}`n")
    [void]$sb.Append(".card-medium{border-left-color:#e0b341;background:#2a2417}`n")
    [void]$sb.Append(".card-low{border-left-color:#3fb950;background:#15241a}`n")
    [void]$sb.Append(".card-wait{border-left-color:#6e7681;background:#1a1d24}`n")
    [void]$sb.Append(".card .ctitle{font-size:22px;font-weight:700;margin:0 0 6px}`n")
    [void]$sb.Append(".card .cmeta{font-size:12px;opacity:.7;margin-bottom:10px}`n")
    [void]$sb.Append(".card h2{font-size:15px;margin:14px 0 6px;color:#cfd}`n")
    [void]$sb.Append(".card ul{margin:4px 0 4px 1.2em;padding:0}`n")
    [void]$sb.Append(".card li{margin:3px 0}`n")
    [void]$sb.Append(".card p{margin:6px 0}`n")
    [void]$sb.Append(".events h2{font-size:15px;color:#9ad;margin:0 0 8px}`n")
    [void]$sb.Append("table{width:100%;border-collapse:collapse;font-size:13px}`n")
    [void]$sb.Append("th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #2a2f3a;vertical-align:top}`n")
    [void]$sb.Append("th{color:#9aa;font-weight:600}`n")
    [void]$sb.Append(".ev-ts{white-space:nowrap;opacity:.8}`n")
    [void]$sb.Append(".ev-mode{white-space:nowrap;opacity:.85}`n")
    [void]$sb.Append("tr.d-block .ev-dec{color:#ff7b72}`n")
    [void]$sb.Append("tr.d-allow .ev-dec{color:#56d364}`n")
    [void]$sb.Append("tr.d-explain .ev-dec{color:#79c0ff}`n")
    [void]$sb.Append(".empty{opacity:.6;font-size:13px}`n")
    [void]$sb.Append(".foot{margin-top:18px;font-size:11px;opacity:.5}`n")
    [void]$sb.Append(".action{background:#12161f;border:1px solid #2a3040;border-radius:8px;padding:12px 14px;margin:10px 0 14px}`n")
    [void]$sb.Append(".action-label{font-size:12px;color:#8ab;margin-bottom:6px;font-weight:600}`n")
    [void]$sb.Append(".action-cmd{margin:0;font-family:monospace,'Courier New',Courier;font-size:14px;color:#f0c080;white-space:pre-wrap;word-break:break-all;overflow-wrap:anywhere}`n")
    [void]$sb.Append(".whatdo{background:#14211a;border:1px solid #2a4030;border-radius:8px;padding:12px 14px;margin:0 0 14px}`n")
    [void]$sb.Append(".whatdo-label{font-size:13px;color:#7fd6a0;margin-bottom:6px;font-weight:700}`n")
    [void]$sb.Append(".whatdo-body{margin:0;font-size:15px;color:#e6e6e6;line-height:1.7}`n")
    [void]$sb.Append(".whatdo-danger{margin:8px 0 0;font-size:14px;color:#ffb4ad;font-weight:700}`n")
    [void]$sb.Append("</style>`n")
    # JS リロード: meta refresh が file:// で効かないブラウザ向けの補完。
    # ユーザ値を JS 内に一切流し込まない (XSS 不発生)。
    # JS が無効な環境では meta refresh にフォールバックする。
    [void]$sb.Append("<script>setInterval(function(){ location.reload(); }, 1000);</script>`n")
    [void]$sb.Append("</head>`n<body>`n<div class=`"wrap`">`n")
    [void]$sb.Append("<h1 class=`"hdr`">agent-monitor — いま AI がやろうとしていること</h1>`n")
    return $sb.ToString()
}

# now.html を BOM 無し UTF-8 で原子書換 (tmp -> Move-Item -Force) する共通ヘルパ。
function Write-NowHtmlFile([string]$LogDir, [string]$Html) {
    $out = Join-Path $LogDir "now.html"
    $tmp = Join-Path $LogDir ("now.html.tmp." + [System.Diagnostics.Process]::GetCurrentProcess().Id)
    # BOM 無し UTF-8 で書く (一部ブラウザの BOM 表示崩れ回避。impl-notes 参照)。
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $Html, $enc)
    # 原子書換: 同一ディレクトリ内 tmp -> Move-Item -Force で rename。
    Move-Item -LiteralPath $tmp -Destination $out -Force
}

# 待機カード placeholder の now.html を書き出す。
# ガード未発火（now.html がまだ無い）状態でモニター起動ボタンを押したとき、
# 空白 / file-not-found を防ぐために本物 now.html と同じパス・同じ体裁で吐く。
# ガード発火後は Write-NowHtml が同じパスを上書きするので自動で切り替わる。
function Write-NowHtmlPlaceholder([string]$LogDir) {
    # F-I: 本物 now.html が既に存在する場合は何もしない（レース安全化）。
    # Write-NowHtml（本物）は従来どおり上書きするが、placeholder は上書きしない。
    $existingHtml = Join-Path $LogDir "now.html"
    if (Test-Path -LiteralPath $existingHtml) { return $false }
    try {
        $refresh = 1
        if ($env:AI_SAFE_MONITOR_INTERVAL -match '^\d+$') { $refresh = [int]$env:AI_SAFE_MONITOR_INTERVAL }
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append((Get-NowHtmlHead $refresh))
        [void]$sb.Append("<div class=`"card card-wait`">`n")
        [void]$sb.Append("<div class=`"ctitle`">🟢 見守り中です</div>`n")
        [void]$sb.Append("<div class=`"cmeta`">まだ承認待ちのアクションはありません</div>`n")
        [void]$sb.Append("<p>AI が tool（コマンド実行・ファイル書き込みなど）を呼ぶと、ここに「いま何をしようとしているか」が表示されます。</p>`n")
        [void]$sb.Append("<p>この画面は開いたままにしておいてください。AI が動き出すと自動で切り替わります。</p>`n")
        [void]$sb.Append("</div>`n")
        [void]$sb.Append("<div class=`"foot`">この画面は $refresh 秒ごとに自動更新されます (JS reload + meta refresh フォールバック)。判断はこの画面ではなくターミナル側で行ってください。</div>`n")
        [void]$sb.Append("</div>`n</body>`n</html>`n")
        Write-NowHtmlFile $LogDir $sb.ToString()
        return $true
    } catch {
        return $false
    }
}

# Node が見つからないときの簡易表示。操作の文字列だけを出す（解説カード・「これは何をする？」は出ない）。
function Write-ExplainFallback([object]$HookInput, [string]$Mode) {
    $text = ""; $label = "操作"
    try {
        $ti = $null
        if ($HookInput -and $HookInput.PSObject.Properties['tool_input']) { $ti = $HookInput.tool_input }
        switch ($Mode) {
            "bash" { if ($ti -and $ti.PSObject.Properties['command']) { $text = [string]$ti.command }; $label = "コマンド実行" }
            "write" { if ($ti -and $ti.PSObject.Properties['file_path']) { $text = [string]$ti.file_path }; $label = "ファイル書き込み" }
            "webfetch" { if ($ti -and $ti.PSObject.Properties['url']) { $text = [string]$ti.url }; $label = "Web アクセス" }
            "observe" { if ($HookInput -and $HookInput.PSObject.Properties['tool_name']) { $text = [string]$HookInput.tool_name }; $label = "ツールの使用" }
            default { if ($HookInput -and $HookInput.PSObject.Properties['prompt']) { $text = [string]$HookInput.prompt }; $label = "プロンプト" }
        }
    } catch { }
    $text = ($text -replace "[\r\n]+", " ")
    $max = 800
    if ($Mode -eq "prompt" -or $Mode -eq "post-output") { $max = 300 }
    if ($text.Length -gt $max) { $text = $text.Substring(0, $max) + "…（省略）" }
    if ([string]::IsNullOrWhiteSpace($text)) { $text = "（取得できませんでした）" }
    $logDir = Get-ExplainLogDir
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $refresh = 1
    if ($env:AI_SAFE_MONITOR_INTERVAL -match '^\d+$') { $refresh = [int]$env:AI_SAFE_MONITOR_INTERVAL }
    $sep = ("─" * 41)
    $md = "💡 AI が操作をしようとしています  (risk: low)`n$sep`n[$ts  tool=$Mode  card=fallback]`n`n▶ ${label}:`n  $text`n`n（詳しい解説は Node.js が入っている PC で表示されます）`n"
    Set-Content -LiteralPath (Join-Path $logDir "now.md") -Value $md -Encoding UTF8
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Get-NowHtmlHead $refresh))
    [void]$sb.Append("<div class=`"card card-low`">`n")
    [void]$sb.Append("<div class=`"ctitle`">💡 AI が操作をしようとしています</div>`n")
    [void]$sb.Append("<div class=`"cmeta`">" + (ConvertTo-HtmlEscaped $ts) + " ・ tool=" + (ConvertTo-HtmlEscaped $Mode) + " ・ risk=low ・ card=fallback</div>`n")
    [void]$sb.Append("<div class=`"action`">`n")
    [void]$sb.Append("<div class=`"action-label`">🤖 AI がしようとしていること（" + (ConvertTo-HtmlEscaped $label) + "）</div>`n")
    [void]$sb.Append("<pre class=`"action-cmd`">" + (ConvertTo-HtmlEscaped $text) + "</pre>`n")
    [void]$sb.Append("</div>`n")
    [void]$sb.Append("<p>詳しい解説は Node.js が入っている PC で表示されます。</p>`n")
    [void]$sb.Append("</div>`n")
    [void]$sb.Append("<div class=`"foot`">この画面は $refresh 秒ごとに自動更新されます (JS reload + meta refresh フォールバック)。判断はこの画面ではなくターミナル側で行ってください。</div>`n")
    [void]$sb.Append("</div>`n</body>`n</html>`n")
    Write-NowHtmlFile $logDir $sb.ToString()
    return $true
}

# explainer.js を呼び、"<card_id>`t<risk>" を返す（呼べなかったら空文字）。
# ★ PS 5.1（.NET Framework）には ProcessStartInfo.StandardInputEncoding が無い。触らずに
#   UTF-8（BOM なし）のバイト列を標準入力へ直接書く（guard-bash.ps1 の判定呼び出しと同じやり方）。
function Invoke-ExplainerJs([object]$HookInput, [string]$Mode) {
    $node = Resolve-ExplainerNode
    if (-not $node) { return "" }
    $js = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'common', 'explainer.js'))
    if (-not [System.IO.File]::Exists($js)) { return "" }
    $payload = ""
    try { $payload = ($HookInput | ConvertTo-Json -Depth 20 -Compress) } catch { return "" }
    $cards = Get-CardsDir
    $logDir = Get-ExplainLogDir
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node
    $psi.Arguments = "`"$js`" explain --mode `"$Mode`" --log-dir `"$logDir`" --cards-dir `"$cards`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $utf8 = New-Object System.Text.UTF8Encoding $false
    if ($psi.PSObject.Properties['StandardOutputEncoding']) { $psi.StandardOutputEncoding = $utf8 }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $bytes = $utf8.GetBytes([string]$payload)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.BaseStream.Flush()
    $proc.StandardInput.Close()
    if (-not $proc.WaitForExit(10000)) {
        try { $proc.Kill() } catch { }
        return ""
    }
    $out = $proc.StandardOutput.ReadToEnd()
    try { $null = $proc.StandardError.ReadToEnd() } catch { }
    if ($null -eq $out) { return "" }
    return ([string]$out).Trim()
}

# 解説カードを「待たずに」作らせる（v1.19.9。ガードの入口 Invoke-AiSafeExplain から使う）。
# 判定とは関係のない表示なので、ガードは explainer.js の終わりを待たずに判定へ戻る（1 回あたり約 0.17 秒。
# 本物の Windows PowerShell 5.1 で計測）。注意点が 2 つある:
#   ・ふつうに子プロセスを起動すると、ガードが Claude Code から受け取った出力の通り道（パイプ）まで
#     子が引き継ぎ、Claude Code は子が終わるまで待ってしまう（速くならない）。そこで Windows では
#     ShellExecute（UseShellExecute）で起動する。こちらは何も引き継がない。
#   ・標準入力は渡せないので、入力は一時ファイルで渡す（explainer.js が読んだら消す）。置き場は
#     監査ログと同じフォルダ（本人だけが読める場所。中身はガードの入力そのもの）。
#   ・解説の結果（カードの種類と危険度）の監査行は、explainer.js が書き終えてから自分で足す。
# 起動できなかったら $false を返す（呼び出し側が、これまでどおり待つ形で表示する）。
function Start-ExplainerJs([object]$HookInput, [string]$Mode, [object]$Policy) {
    $node = Resolve-ExplainerNode
    if (-not $node) { return $false }
    $js = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'common', 'explainer.js'))
    if (-not [System.IO.File]::Exists($js)) { return $false }
    $payload = ""
    try { $payload = ($HookInput | ConvertTo-Json -Depth 20 -Compress) } catch { return $false }
    $cards = Get-CardsDir
    $logDir = Get-ExplainLogDir
    $inFile = $null
    try {
        if (-not [System.IO.Directory]::Exists($logDir)) { [void][System.IO.Directory]::CreateDirectory($logDir) }
        $inFile = [System.IO.Path]::Combine($logDir, ('.explain-in-' + [guid]::NewGuid().ToString('N') + '.json'))
        [System.IO.File]::WriteAllText($inFile, [string]$payload, (New-Object System.Text.UTF8Encoding($false)))
        $ver = ""
        try { $ver = [string](Get-JsonValue $Policy @("packageVersion")) } catch { $ver = "" }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $node
        $psi.Arguments = "`"$js`" explain --mode `"$Mode`" --log-dir `"$logDir`" --cards-dir `"$cards`" --input-file `"$inFile`" --audit 1 --package-version `"$ver`""
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        [void][System.Diagnostics.Process]::Start($psi)
        return $true
    } catch {
        if ($inFile) { try { [System.IO.File]::Delete($inFile) } catch { } }
        return $false
    }
}

function Invoke-Explain {
    param([object]$HookInput, [string]$Mode, [object]$Policy)
    try {
        $out = ""
        try { $out = Invoke-ExplainerJs $HookInput $Mode } catch { $out = "" }
        $cardId = ""; $risk = "low"
        if ($out) {
            $parts = @($out -split "`t")
            $cardId = [string]$parts[0]
            if ($parts.Count -ge 2) { $risk = [string]$parts[1] }
        } else {
            try { [void](Write-ExplainFallback $HookInput $Mode); $cardId = "fallback" } catch { $cardId = "" }
        }
        if (-not [string]::IsNullOrWhiteSpace($cardId)) {
            try {
                Write-AuditLog $HookInput $Mode "explain" ("card=" + $cardId + " risk=" + $risk) "" $Policy
            } catch {
                # 監査ログ失敗時もポリシーは続行
            }
        }
    } catch {
        # フェイルセーフ
    }
}
