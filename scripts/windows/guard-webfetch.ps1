param()

try {
    . (Join-Path $PSScriptRoot "lib\SafetyPolicy.ps1")
    $policy = Get-SafetyPolicy
    $inputObj = Read-HookInput
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

    $allowed = $false
    foreach ($domain in $policy.allowedDomains) {
        $d = ([string]$domain).ToLowerInvariant()
        if ($hostName -eq $d -or $hostName.EndsWith("." + $d)) { $allowed = $true; break }
    }
    if (-not $allowed) {
        Block-Action $inputObj "webfetch" ("domain is not allow-listed: " + $hostName) $text $policy
    }

    Allow-Action $inputObj "webfetch" ("domain allowed: " + $hostName) $text $policy
} catch {
    Fail-Closed "webfetch" $_.Exception.Message
}
