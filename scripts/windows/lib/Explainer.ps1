# agent-monitor: 承認解説カードのロード/表示ライブラリ (Windows)
# SafetyPolicy.ps1 が source 済みであることを前提とする。
# 公開関数: Invoke-Explain（フェイルセーフ。失敗してもポリシー判定を阻害しない）

Set-StrictMode -Version 2.0

function Get-CardsDir {
    if ($env:AI_SAFE_CARDS_DIR) { return $env:AI_SAFE_CARDS_DIR }

    $here = $PSScriptRoot
    # 配置想定: $CLAUDE_PROJECT_DIR\.ai-safety\hooks\windows\lib\Explainer.ps1
    #            $CLAUDE_PROJECT_DIR\.ai-safety\cards\
    $guess = Join-Path $here "..\..\..\cards"
    if (Test-Path -LiteralPath $guess) {
        return (Resolve-Path -LiteralPath $guess).Path
    }

    # 開発時 fallback: リポジトリ直下の configs\safety\cards\
    $dev = Join-Path $here "..\..\..\..\configs\safety\cards"
    if (Test-Path -LiteralPath $dev) {
        return (Resolve-Path -LiteralPath $dev).Path
    }

    return ""
}

function ConvertTo-DotNetRegex([string]$Pattern) {
    # POSIX 文字クラスを .NET 正規表現の短縮形に変換
    $p = $Pattern
    $p = $p -replace '\[\[:space:\]\]', '\s'
    $p = $p -replace '\[\[:digit:\]\]', '\d'
    $p = $p -replace '\[\[:alpha:\]\]', '[A-Za-z]'
    $p = $p -replace '\[\[:alnum:\]\]', '[A-Za-z0-9]'
    $p = $p -replace '\[\[:upper:\]\]', '[A-Z]'
    $p = $p -replace '\[\[:lower:\]\]', '[a-z]'
    return $p
}

function Get-ExplainTarget {
    param([object]$HookInput, [string]$Mode)
    switch ($Mode) {
        "bash" { return Get-CommandText $HookInput }
        "write" { return Get-WriteTarget $HookInput }
        "webfetch" {
            $url = Get-WebUrl $HookInput
            $uri = $null
            if ([System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri)) {
                return $uri.Host.ToLowerInvariant()
            }
            return $url
        }
        "prompt" { return Get-PromptText $HookInput }
        "post-output" { return ConvertTo-SafeText $HookInput }
        default { return "" }
    }
}

function Find-Card {
    param([string]$Target, [string]$Mode, [string]$CardsDir)
    $indexPath = Join-Path $CardsDir "index.tsv"
    if (-not (Test-Path -LiteralPath $indexPath)) { return $null }

    $lines = Get-Content -LiteralPath $indexPath -Encoding UTF8
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith("#")) { continue }
        $parts = $line -split "`t"
        if ($parts.Length -lt 4) { continue }
        $tool = $parts[0]
        $pattern = $parts[1]
        $risk = $parts[2]
        $cardId = $parts[3]
        if ($tool -ne $Mode) { continue }
        $dotnetPattern = ConvertTo-DotNetRegex $pattern
        try {
            if ($Target -match $dotnetPattern) {
                return [PSCustomObject]@{ CardId = $cardId; Risk = $risk }
            }
        } catch {
            # 無効パターンは飛ばす
        }
    }
    return $null
}

function Read-FrontmatterField {
    param([string]$Path, [string]$Key)
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    $inFm = $false
    $first = $true
    foreach ($line in $lines) {
        if ($line -eq "---") {
            if ($first -and -not $inFm) { $inFm = $true; $first = $false; continue }
            if ($inFm) { return "" }
        }
        $first = $false
        if ($inFm) {
            $regex = "^" + [regex]::Escape($Key) + "\s*:\s*(.+?)\s*$"
            if ($line -match $regex) {
                return $matches[1]
            }
        }
    }
    return ""
}

function Get-CardBody {
    param([string]$Path)
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    $inFm = $false
    $doneFm = $false
    $first = $true
    $body = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ($line -eq "---") {
            if ($first -and -not $inFm) { $inFm = $true; $first = $false; continue }
            if ($inFm) { $inFm = $false; $doneFm = $true; $first = $false; continue }
        }
        $first = $false
        if ($doneFm) { [void]$body.Add($line) }
    }
    return ($body -join "`n")
}

# ----- コマンド解説エンジン (パターン式・LLM不要・オフライン・決定的) ----
# 入力: 実コマンド文字列。戻り値: [PSCustomObject]@{ WhatDo=...; Icon=...; Danger=... }
#   WhatDo  平易な日本語の「何をする？」本文（未知コマンドは空）
#   Icon    セクション見出しアイコン（既定 📂）
#   Danger  危険語が含まれる時の強調1行（無ければ空）
# 嘘解説を避けるため、語彙に無い動詞は WhatDo を空にしてフォールバックさせる。
# scripts/macos/lib/explainer.sh の explain_command と parity を保つ。

# 複合コマンドの主コマンド（先頭セグメント）を返す。| ; && || の手前まで。
function Get-PrimarySegment([string]$Full) {
    $out = New-Object System.Text.StringBuilder
    $i = 0
    $len = $Full.Length
    while ($i -lt $len) {
        $c = $Full[$i]
        $c2 = if ($i + 1 -lt $len) { [string]$c + [string]$Full[$i + 1] } else { "" }
        if ($c -eq '|' -or $c -eq ';') { break }
        if ($c2 -eq '&&' -or $c2 -eq '||') { break }
        [void]$out.Append($c)
        $i++
    }
    return $out.ToString().Trim()
}

# 主コマンドの対象を抽出する。URL優先 → -Path/-LiteralPath/-Destination/-Url の値
# → 最初の非フラグ位置引数。取れなければ空。
function Get-ExplainTargetFromCmd([string]$Primary) {
    $toks = $Primary -split '\s+' | Where-Object { $_ -ne "" }
    if ($toks.Count -eq 0) { return "" }
    # URL 最優先
    foreach ($t in $toks) {
        if ($t -match '^https?://') { return $t }
    }
    # 名前付きパラメータ
    for ($i = 1; $i -lt $toks.Count; $i++) {
        $lf = $toks[$i].ToLowerInvariant()
        if ($lf -eq '-path' -or $lf -eq '-literalpath' -or $lf -eq '-destination' -or $lf -eq '-url' -or $lf -eq '-uri') {
            if ($i + 1 -lt $toks.Count) { return $toks[$i + 1] }
        }
    }
    # 最初の非フラグ位置引数（動詞 [0] をスキップ）
    for ($i = 1; $i -lt $toks.Count; $i++) {
        if ($toks[$i].StartsWith('-')) { continue }
        return $toks[$i]
    }
    return ""
}

# 危険語（再帰削除・権限昇格）を全文から検知して強調1行を返す（無ければ空）。
function Get-ExplainDanger([string]$Full) {
    $lc = $Full.ToLowerInvariant()
    if ($lc -match '(^|\s)sudo(\s|$)' -or $lc -match 'runas' -or $lc -match 'start-process.*-verb\s+runas') {
        return "⚠️ 管理者権限への昇格を含みます（PC全体に影響する可能性）"
    }
    if ($lc -match '\brm\b[^|;]*\s-[a-z]*r' -or $lc -match '\s-recurse' -or $lc -match '\s-rf' -or $lc -match '\s-fr' -or $lc -match 'remove-item[^|;]*-recurse') {
        return "⚠️ フォルダごとの完全削除（復元できません）を含みます"
    }
    return ""
}

function Get-CommandExplanation([string]$Full) {
    $whatdo = ""
    $icon = "📂"
    $danger = ""
    if ([string]::IsNullOrWhiteSpace($Full)) {
        return [PSCustomObject]@{ WhatDo = ""; Icon = $icon; Danger = "" }
    }

    $danger = Get-ExplainDanger $Full
    $primary = Get-PrimarySegment $Full
    # 先頭の sudo を剥がして verb/target を実コマンド基準に揃える（sudo は danger 側で強調済み）。
    $ptoks = $primary -split '\s+' | Where-Object { $_ -ne "" }
    if ($ptoks.Count -ge 2 -and $ptoks[0].ToLowerInvariant() -eq 'sudo') {
        $primary = ($ptoks[1..($ptoks.Count - 1)] -join ' ')
    }
    $toks = $primary -split '\s+' | Where-Object { $_ -ne "" }
    $verb = if ($toks.Count -gt 0) { $toks[0] } else { "" }
    $verbLc = $verb.ToLowerInvariant()
    $target = Get-ExplainTargetFromCmd $primary
    $tdisp = if ([string]::IsNullOrEmpty($target)) { "現在のフォルダ" } else { $target }

    # 複合（パイプ/連結）一言
    $extra = ""
    if ($Full -match '(\||;|&&|\|\|)') {
        $extra = "（ほかにも処理が続きます。全文は上のコマンドを確認してください）"
    }

    switch -Regex ($verbLc) {
        '^(ls|dir|get-childitem|gci|ll|la)$' {
            $icon = "📂"
            $whatdo = "$tdisp の中のファイル・フォルダ一覧を見ようとしています。（中身を見るだけ。削除や書き換えはしません）"
            break
        }
        '^(cat|head|tail|less|more|type|get-content|gc)$' {
            $icon = "📄"
            $whatdo = "$tdisp の中身を読もうとしています。（読むだけ。書き換えはしません）"
            break
        }
        '^(rm|rmdir|del|erase|remove-item|ri)$' {
            $icon = "🗑"
            $whatdo = "$tdisp を削除しようとしています。"
            break
        }
        '^(touch|new-item|set-content|out-file|add-content|tee)$' {
            $icon = "✏️"
            $whatdo = "$tdisp を作成または書き換えようとしています。"
            break
        }
        '^(echo|printf)$' {
            if ($primary -match '>') {
                $redir = ""
                if ($primary -match '>>?\s*([^\s|;]+)') { $redir = $matches[1] }
                if ([string]::IsNullOrEmpty($redir)) { $redir = "ファイル" }
                $icon = "✏️"
                $whatdo = "$redir に文字を書き込もうとしています。"
            } else {
                $icon = "📄"
                $whatdo = "画面に文字を表示しようとしています。（表示するだけ）"
            }
            break
        }
        '^(mv|move|move-item)$' {
            $icon = "📦"
            $whatdo = "$tdisp を別の場所に移動しようとしています。"
            break
        }
        '^(cp|copy|copy-item)$' {
            $icon = "📦"
            $whatdo = "$tdisp を別の場所にコピーしようとしています。"
            break
        }
        '^(curl|wget|invoke-webrequest|iwr|invoke-restmethod|irm|nc|ncat|netcat)$' {
            $icon = "🌐"
            if (-not [string]::IsNullOrEmpty($target)) {
                $whatdo = "$target とインターネット通信（ダウンロードまたは送信）をしようとしています。"
            } else {
                $whatdo = "インターネット通信（ダウンロードまたは送信）をしようとしています。"
            }
            break
        }
        '^(npm|pip|pip3|winget|choco|brew|apt|apt-get|yum|gem)$' {
            if ($primary -match '(^|\s)(install|add|i)(\s|$)') {
                $icon = "📥"
                $pkg = ""
                if ($toks.Count -ge 3) {
                    for ($j = 2; $j -lt $toks.Count; $j++) {
                        if (-not $toks[$j].StartsWith('-')) { $pkg = $toks[$j]; break }
                    }
                }
                if ([string]::IsNullOrEmpty($pkg)) { $pkg = "パッケージ" }
                $whatdo = "$pkg をインターネットからインストール（PC に新しいプログラムを追加）しようとしています。"
            } else {
                $icon = "⚙️"
                $whatdo = "$verb コマンドを実行しようとしています。"
            }
            break
        }
        '^(bash|sh|zsh|python|python3|node|source|\.|invoke-expression|iex|start-process)$' {
            $icon = "⚙️"
            $whatdo = "$tdisp を実行しようとしています。（別のプログラムやスクリプトを動かします）"
            break
        }
        '^(chmod|chown|icacls|set-acl|set-itemproperty)$' {
            $icon = "🔑"
            $whatdo = "$tdisp のアクセス権限や設定を変更しようとしています。"
            break
        }
        '^(cd|set-location|sl|pushd)$' {
            $icon = "📁"
            $whatdo = "作業フォルダを $tdisp に移動しようとしています。"
            break
        }
        '^(grep|findstr|select-string|sls|find)$' {
            $icon = "🔍"
            $whatdo = "$tdisp から文字列やファイルを検索しようとしています。"
            break
        }
        default {
            # 未知コマンド: 嘘解説をせず空のままフォールバックさせる
            $whatdo = ""
        }
    }

    if (-not [string]::IsNullOrEmpty($whatdo) -and -not [string]::IsNullOrEmpty($extra)) {
        $whatdo = $whatdo + $extra
    }
    return [PSCustomObject]@{ WhatDo = $whatdo; Icon = $icon; Danger = $danger }
}

# ツール別に「AI が実際にしようとしていること」の文字列を返す。
# 戻り値: [PSCustomObject]@{ Text=...; Label=... }
# 800字超は安全に切り捨て。XSS対策は呼び出し側(Write-NowHtml)で行う。
function Get-ActionText {
    param([object]$HookInput, [string]$Mode)
    $text = ""
    $label = "操作"
    try {
        switch ($Mode) {
            "bash" {
                $text = [string](Get-CommandText $HookInput)
                $label = "コマンド実行"
            }
            "write" {
                $fp = [string](Get-WriteTarget $HookInput)
                $toolInput = Get-ToolInput $HookInput
                $content = [string](Get-JsonValue $toolInput @("content", "new_string"))
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    $preview = ($content -replace "[\r\n\t]", " ").Substring(0, [Math]::Min($content.Length, 120))
                    $text = "$fp (内容: $preview)"
                } else {
                    $text = $fp
                }
                $label = "ファイル書き込み"
            }
            "webfetch" {
                $text = [string](Get-WebUrl $HookInput)
                $label = "Web アクセス"
            }
            { $_ -eq "prompt" -or $_ -eq "post-output" } {
                $raw = [string](Get-PromptText $HookInput)
                $text = if ($raw.Length -gt 300) { $raw.Substring(0, 300) } else { $raw }
                $label = "プロンプト"
            }
            default {
                $raw = ConvertTo-SafeText $HookInput
                $text = if ($raw.Length -gt 200) { $raw.Substring(0, 200) } else { $raw }
            }
        }
    } catch { $text = "" }

    if ([string]::IsNullOrWhiteSpace($text)) { $text = "（取得できませんでした）" }
    # 800字で切り捨て
    if ($text.Length -gt 800) { $text = $text.Substring(0, 800) + "…(省略)" }
    return [PSCustomObject]@{ Text = $text; Label = $label }
}

# ----- now.html 書き出し (Phase 1: HTML モニター足場) ---------------------
# now.md と「並立」する追加出力。now.md の挙動は一切変えない。
# meta refresh による file:// 直開きの自動更新を前提に、自己完結 HTML を
# 原子書換 (tmp -> Move-Item -Force) で吐く。文字コードは UTF8。

function ConvertTo-HtmlEscaped([string]$Text) {
    if ($null -eq $Text) { return "" }
    $t = $Text -replace "&", "&amp;"
    $t = $t -replace "<", "&lt;"
    $t = $t -replace ">", "&gt;"
    $t = $t -replace '"', "&quot;"
    return $t
}

# decision -> (cssClass, icon)
function Get-DecisionStyle([string]$Decision) {
    switch ($Decision) {
        "block" { return @("d-block", "⛔") }
        "allow" { return @("d-allow", "✅") }
        "explain" { return @("d-explain", "💬") }
        default { return @("d-other", "•") }
    }
}

# カード本文 (markdown) を最小限の HTML に変換する。
#   '# 見出し' -> <h2>、'- 項目' -> <ul><li>、空行 -> 段落区切り、その他 -> <p>。
function ConvertTo-CardHtml([string]$Body) {
    $sb = New-Object System.Text.StringBuilder
    $inList = $false
    foreach ($raw in ($Body -split "`n")) {
        $line = $raw.TrimEnd()
        if ($line -match '^#+\s') {
            if ($inList) { [void]$sb.Append("</ul>`n"); $inList = $false }
            $h = $line -replace '^#+\s+', ''
            [void]$sb.Append("<h2>" + (ConvertTo-HtmlEscaped $h) + "</h2>`n")
            continue
        }
        if ($line -match '^[-*]\s') {
            if (-not $inList) { [void]$sb.Append("<ul>`n"); $inList = $true }
            $item = $line -replace '^[-*]\s+', ''
            [void]$sb.Append("<li>" + (ConvertTo-HtmlEscaped $item) + "</li>`n")
            continue
        }
        if ($line -match '^\s*$') {
            if ($inList) { [void]$sb.Append("</ul>`n"); $inList = $false }
            continue
        }
        if ($inList) { [void]$sb.Append("</ul>`n"); $inList = $false }
        [void]$sb.Append("<p>" + (ConvertTo-HtmlEscaped $line) + "</p>`n")
    }
    if ($inList) { [void]$sb.Append("</ul>`n") }
    return $sb.ToString()
}

# 本日の events-YYYY-MM-DD.jsonl の末尾 N 件を HTML テーブル行に変換する。
function Get-EventsHtmlRows([string]$LogDir) {
    $tailN = 12
    if ($env:AI_SAFE_MONITOR_TAIL) { try { $tailN = [int]$env:AI_SAFE_MONITOR_TAIL } catch { $tailN = 12 } }
    $day = Get-Date -Format "yyyy-MM-dd"
    $eventsPath = Join-Path $LogDir ("events-" + $day + ".jsonl")
    if (-not (Test-Path -LiteralPath $eventsPath)) { return "" }
    $lines = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8 -Tail $tailN)
    if ($lines.Count -eq 0) { return "" }
    [array]::Reverse($lines)
    $sb = New-Object System.Text.StringBuilder
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json
        } catch {
            continue
        }
        $ts = [string]$obj.ts
        $short = $ts -replace ".*T", "" -replace "\..*", "" -replace "Z$", "" -replace "([+-]\d{2}:?\d{2})$", ""
        $decision = [string]$obj.decision
        $mode = [string]$obj.mode
        $reason = [string]$obj.reason
        $style = Get-DecisionStyle $decision
        $cls = $style[0]; $icon = $style[1]
        [void]$sb.Append('<tr class="' + $cls + '"><td class="ev-ts">' + (ConvertTo-HtmlEscaped $short) + '</td><td class="ev-dec">' + $icon + ' ' + (ConvertTo-HtmlEscaped $decision) + '</td><td class="ev-mode">' + (ConvertTo-HtmlEscaped $mode) + '</td><td class="ev-reason">' + (ConvertTo-HtmlEscaped $reason) + "</td></tr>`n")
    }
    return $sb.ToString()
}

# now.html の <head>（meta + style + JS reload）+ ラッパ開始を返す。
# Write-NowHtml と Write-NowHtmlPlaceholder で共通利用し、体裁を一元化する。
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

function Write-NowHtml {
    param([string]$Icon, [string]$Title, [string]$BodyRisk, [string]$Ts, [string]$CardId, [string]$Mode, [string]$Body, [string]$LogDir, [string]$ActionText = "", [string]$ActionLabel = "操作")
    try {
        $refresh = 1
        if ($env:AI_SAFE_MONITOR_INTERVAL -match '^\d+$') { $refresh = [int]$env:AI_SAFE_MONITOR_INTERVAL }
        $cardcls = switch ($BodyRisk) {
            "high" { "card-high" }
            "medium" { "card-medium" }
            default { "card-low" }
        }
        $cardHtml = ConvertTo-CardHtml $Body
        $rows = Get-EventsHtmlRows $LogDir
        $day = Get-Date -Format "yyyy-MM-dd"

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append((Get-NowHtmlHead $refresh))
        [void]$sb.Append("<div class=`"card $cardcls`">`n")
        [void]$sb.Append("<div class=`"ctitle`">" + (ConvertTo-HtmlEscaped $Icon) + " " + (ConvertTo-HtmlEscaped $Title) + "</div>`n")
        [void]$sb.Append("<div class=`"cmeta`">" + (ConvertTo-HtmlEscaped $Ts) + " ・ tool=" + (ConvertTo-HtmlEscaped $Mode) + " ・ risk=" + (ConvertTo-HtmlEscaped $BodyRisk) + " ・ card=" + (ConvertTo-HtmlEscaped $CardId) + "</div>`n")
        if (-not [string]::IsNullOrWhiteSpace($ActionText)) {
            [void]$sb.Append("<div class=`"action`">`n")
            [void]$sb.Append("<div class=`"action-label`">🤖 AI がしようとしていること（" + (ConvertTo-HtmlEscaped $ActionLabel) + "）</div>`n")
            [void]$sb.Append("<pre class=`"action-cmd`">" + (ConvertTo-HtmlEscaped $ActionText) + "</pre>`n")
            [void]$sb.Append("</div>`n")
            # 「これは何をする？」具体解説（bash モードのみ・決定的・LLM不要）。
            if ($Mode -eq "bash") {
                $expl = Get-CommandExplanation $ActionText
                if (-not [string]::IsNullOrEmpty($expl.WhatDo)) {
                    [void]$sb.Append("<div class=`"whatdo`">`n")
                    [void]$sb.Append("<div class=`"whatdo-label`">" + (ConvertTo-HtmlEscaped $expl.Icon) + " これは何をする？</div>`n")
                    [void]$sb.Append("<p class=`"whatdo-body`">" + (ConvertTo-HtmlEscaped $expl.WhatDo) + "</p>`n")
                    if (-not [string]::IsNullOrEmpty($expl.Danger)) {
                        [void]$sb.Append("<p class=`"whatdo-danger`">" + (ConvertTo-HtmlEscaped $expl.Danger) + "</p>`n")
                    }
                    [void]$sb.Append("</div>`n")
                } elseif (-not [string]::IsNullOrEmpty($expl.Danger)) {
                    [void]$sb.Append("<div class=`"whatdo`">`n")
                    [void]$sb.Append("<p class=`"whatdo-danger`">" + (ConvertTo-HtmlEscaped $expl.Danger) + "</p>`n")
                    [void]$sb.Append("</div>`n")
                }
            }
        }
        [void]$sb.Append($cardHtml)
        [void]$sb.Append("</div>`n")
        [void]$sb.Append("<div class=`"events`">`n<h2>直近の出来事 (events-$day.jsonl)</h2>`n")
        if (-not [string]::IsNullOrWhiteSpace($rows)) {
            [void]$sb.Append("<table>`n<thead><tr><th>時刻</th><th>判定</th><th>種類</th><th>理由</th></tr></thead>`n<tbody>`n")
            [void]$sb.Append($rows)
            [void]$sb.Append("</tbody>`n</table>`n")
        } else {
            [void]$sb.Append("<p class=`"empty`">本日の監査ログはまだありません。AI が tool を呼ぶとここに出ます。</p>`n")
        }
        [void]$sb.Append("</div>`n")
        [void]$sb.Append("<div class=`"foot`">この画面は $refresh 秒ごとに自動更新されます (JS reload + meta refresh フォールバック)。判断はこの画面ではなくターミナル側で行ってください。</div>`n")
        [void]$sb.Append("</div>`n</body>`n</html>`n")

        Write-NowHtmlFile $LogDir $sb.ToString()
    } catch {
        # フェイルセーフ: now.html 失敗は now.md / 判定に影響させない
    }
}

function Write-NowCard {
    param([string]$CardId, [string]$RiskDefault, [string]$Mode, [string]$CardsDir, [object]$HookInput = $null)
    $bodyPath = Join-Path $CardsDir ($CardId + ".md")
    if (-not (Test-Path -LiteralPath $bodyPath)) {
        $bodyPath = Join-Path $CardsDir ("default-" + $Mode + ".md")
    }
    if (-not (Test-Path -LiteralPath $bodyPath)) { return "" }

    $title = Read-FrontmatterField $bodyPath "title"
    $icon = Read-FrontmatterField $bodyPath "icon"
    $risk = Read-FrontmatterField $bodyPath "risk"
    if ([string]::IsNullOrWhiteSpace($risk)) { $risk = $RiskDefault }
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "(title not set)" }
    if ([string]::IsNullOrWhiteSpace($icon)) { $icon = "[*]" }

    $body = Get-CardBody $bodyPath
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # 実際の操作文字列を抽出（HookInput が渡された場合のみ）。
    $actionText = ""
    $actionLabel = "操作"
    if ($null -ne $HookInput) {
        try {
            $action = Get-ActionText -HookInput $HookInput -Mode $Mode
            $actionText = $action.Text
            $actionLabel = $action.Label
        } catch { }
    }

    $logDir = $env:AI_SAFE_LOG_DIR
    if (-not $logDir) { $logDir = Join-Path $HOME ".ai-safety\logs" }
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    $out = Join-Path $logDir "now.md"

    $sep = ("─" * 41)
    # 実際の操作を最上部に表示（コンソール monitor が読む）。
    $actionLine = if (-not [string]::IsNullOrWhiteSpace($actionText)) { "`n▶ ${actionLabel}:`n  $actionText`n" } else { "" }
    # 「これは何をする？」具体解説（bash モードのみ）。
    if (-not [string]::IsNullOrWhiteSpace($actionText) -and $Mode -eq "bash") {
        try {
            $expl = Get-CommandExplanation $actionText
            if (-not [string]::IsNullOrEmpty($expl.WhatDo)) {
                $actionLine = $actionLine + "$($expl.Icon) これは何をする？`n  $($expl.WhatDo)`n"
            }
            if (-not [string]::IsNullOrEmpty($expl.Danger)) {
                $actionLine = $actionLine + "  $($expl.Danger)`n"
            }
        } catch { }
    }
    $header = "$icon $title  (risk: $risk)`n$sep`n[$ts  tool=$Mode  card=$CardId]$actionLine`n"
    Set-Content -LiteralPath $out -Value ($header + $body) -Encoding UTF8

    # now.html を「並立」出力 (now.md は上で確定済み・不変)。失敗しても判定は止めない。
    Write-NowHtml -Icon $icon -Title $title -BodyRisk $risk -Ts $ts -CardId $CardId -Mode $Mode -Body $body -LogDir $logDir -ActionText $actionText -ActionLabel $actionLabel

    return $CardId
}

function Invoke-Explain {
    param([object]$HookInput, [string]$Mode, [object]$Policy)
    try {
        $cardsDir = Get-CardsDir
        if ([string]::IsNullOrWhiteSpace($cardsDir)) { return }

        $target = Get-ExplainTarget -HookInput $HookInput -Mode $Mode
        if ($null -eq $target) { $target = "" }
        $hit = Find-Card -Target ([string]$target) -Mode $Mode -CardsDir $cardsDir
        if ($null -ne $hit) {
            $cardId = $hit.CardId
            $risk = $hit.Risk
        } else {
            $cardId = "default-$Mode"
            $risk = "low"
        }

        $written = Write-NowCard -CardId $cardId -RiskDefault $risk -Mode $Mode -CardsDir $cardsDir -HookInput $HookInput
        if (-not [string]::IsNullOrWhiteSpace($written)) {
            try {
                Write-AuditLog $HookInput $Mode "explain" ("card=" + $written + " risk=" + $risk) "" $Policy
            } catch {
                # 監査ログ失敗時もポリシーは続行
            }
        }
    } catch {
        # フェイルセーフ
    }
}
