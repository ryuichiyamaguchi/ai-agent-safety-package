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

function Write-NowCard {
    param([string]$CardId, [string]$RiskDefault, [string]$Mode, [string]$CardsDir)
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

    $logDir = $env:AI_SAFE_LOG_DIR
    if (-not $logDir) { $logDir = Join-Path $HOME ".ai-safety\logs" }
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    $out = Join-Path $logDir "now.md"

    $sep = ("─" * 41)
    $header = "$icon $title  (risk: $risk)`n$sep`n[$ts  tool=$Mode  card=$CardId]`n`n"
    Set-Content -LiteralPath $out -Value ($header + $body) -Encoding UTF8

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

        $written = Write-NowCard -CardId $cardId -RiskDefault $risk -Mode $Mode -CardsDir $cardsDir
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
