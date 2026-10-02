param()

# 共通部品（lib\SafetyPolicy.ps1）は Fail-Closed そのものを定義している。読み込めないまま下の
# catch へ落ちると Fail-Closed を呼べず、エラーを 1 行出して exit 0（＝許可）で終わっていた。
# Codex / Gemini / AntiGravity はガードを -File で直接起動するので、部品が壊れたり消えたりすると
# 危険なコマンドまで素通しになる（v1.19.8 で実測して修正）。読めなければ、ここで止める。
$ErrorActionPreference = "Stop"
try {
    . (Join-Path $PSScriptRoot "lib\SafetyPolicy.ps1")
    Set-AiSafeConsoleUtf8
} catch {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    [Console]::Error.WriteLine("AI Safety Guard FAILED CLOSED: 安全ガードの共通部品（lib\SafetyPolicy.ps1）を読み込めませんでした。導入（インストール）をやり直してください: " + $_.Exception.Message)
    exit 2
}

try {
    # 日本語のメッセージを出す前に、hook の出力を UTF-8 に固定する。
    # （PowerShell 5.1 の既定は CP932 で、Claude Code / Codex は UTF-8 として読むため）
    Set-AiSafeConsoleUtf8
    # 解説カードの部品は判定に使わない。読めなくても判定は続ける（v1.19.7）。
    try { . (Join-Path $PSScriptRoot "lib\Explainer.ps1") } catch {
        [Console]::Error.WriteLine("warn: 解説カードの部品を読み込めませんでした（判定はそのまま続けます）: " + $_.Exception.Message)
    }
    $policy = Get-SafetyPolicy
    $inputObj = Read-HookInput
    Invoke-AiSafeExplain $inputObj "webfetch" $policy
    $url = Get-WebUrl $inputObj
    $text = ConvertTo-SafeText (Get-ToolInput $inputObj)

    if ([string]::IsNullOrWhiteSpace($url)) {
        Block-Action $inputObj "webfetch" "WebFetch URL is missing" $text $policy
    }

    $secret = Find-SecretMatch $text $policy
    if ($secret) {
        Block-Action $inputObj "webfetch" ("sensitive pattern in WebFetch input: " + $secret.Name) $text $policy
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri)) {
        Block-Action $inputObj "webfetch" ("invalid URL: " + $url) $text $policy
    }

    if ($uri.Scheme -notin @("https", "http")) {
        Block-Action $inputObj "webfetch" ("blocked URL scheme: " + $uri.Scheme) $text $policy
    }

    $hostName = $uri.Host.ToLowerInvariant()
    if ($hostName -match "^(localhost|127[.]|10[.]|172[.](1[6-9]|2[0-9]|3[0-1])[.]|192[.]168[.]|::1)") {
        Block-Action $inputObj "webfetch" ("local/private network URL is blocked: " + $hostName) $text $policy
    }

    if (Test-IsBlockedDomain $hostName $policy) {
        Block-Action $inputObj "webfetch" ("domain is block-listed: " + $hostName) $text $policy
    }

    if (-not (Test-IsAllowedDomain $hostName $policy)) {
        Block-Action $inputObj "webfetch" ("domain is not allow-listed: " + $hostName) $text $policy
    }

    Allow-Action $inputObj "webfetch" ("domain allowed: " + $hostName) $text $policy
} catch {
    Fail-Closed "webfetch" $_.Exception.Message
}
