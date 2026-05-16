Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-SafetyPolicyPath {
    $candidates = New-Object System.Collections.ArrayList
    if ($env:AI_SAFE_POLICY) { [void]$candidates.Add($env:AI_SAFE_POLICY) }
    if ($env:AI_SAFE_ROOT) { [void]$candidates.Add((Join-Path $env:AI_SAFE_ROOT "policy\safety-policy.json")) }
    [void]$candidates.Add((Join-Path (Get-Location) ".ai-safety\policy\safety-policy.json"))
    [void]$candidates.Add((Join-Path $HOME ".ai-safety\policy\safety-policy.json"))

    $root = $PSScriptRoot
    for ($i = 0; $i -lt 5; $i++) {
        if ($root) {
            [void]$candidates.Add((Join-Path $root "policy\safety-policy.json"))
            $root = Split-Path -Parent $root
        }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "safety-policy.json was not found. Set AI_SAFE_POLICY or install .ai-safety."
}

function Get-SafetyPolicy {
    $path = Get-SafetyPolicyPath
    $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    return $json | ConvertFrom-Json
}

function Read-HookInput {
    $raw = [Console]::In.ReadToEnd()
    if ($raw.Length -gt 262144) {
        $raw = $raw.Substring(0, 262144)
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return "{}" | ConvertFrom-Json
    }
    return $raw | ConvertFrom-Json
}

function ConvertTo-SafeText([object]$Value) {
    if ($null -eq $Value) { return "" }
    if ($Value -is [string]) { return $Value }
    try {
        return ($Value | ConvertTo-Json -Depth 20 -Compress)
    } catch {
        return [string]$Value
    }
}

function Get-JsonValue([object]$Object, [string[]]$Names) {
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $prop = $Object.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    }
    return $null
}

function Get-ToolName([object]$HookInput) {
    $v = Get-JsonValue $HookInput @("tool_name", "toolName", "name")
    if ($v) { return [string]$v }
    return ""
}

function Get-ToolInput([object]$HookInput) {
    $v = Get-JsonValue $HookInput @("tool_input", "toolInput", "input", "parameters", "args")
    if ($v) { return $v }
    return $HookInput
}

function Get-HookCwd([object]$HookInput) {
    $v = Get-JsonValue $HookInput @("cwd", "workspace", "workspace_root")
    if ($v) { return [string]$v }
    return (Get-Location).Path
}

function Get-CommandText([object]$HookInput) {
    $toolInput = Get-ToolInput $HookInput
    $v = Get-JsonValue $toolInput @("command", "cmd", "shell_command", "script")
    if ($v) { return [string]$v }
    return ConvertTo-SafeText $toolInput
}

function Get-PromptText([object]$HookInput) {
    $v = Get-JsonValue $HookInput @("prompt", "user_prompt", "message", "content")
    if ($v) { return ConvertTo-SafeText $v }
    return ConvertTo-SafeText $HookInput
}

function Get-WebUrl([object]$HookInput) {
    $toolInput = Get-ToolInput $HookInput
    $v = Get-JsonValue $toolInput @("url", "uri", "href")
    if ($v) { return [string]$v }
    return ""
}

function Get-WriteTarget([object]$HookInput) {
    $toolInput = Get-ToolInput $HookInput
    $v = Get-JsonValue $toolInput @("file_path", "path", "target_path", "notebook_path")
    if ($v) { return [string]$v }
    return ""
}

function Get-WriteContent([object]$HookInput) {
    $toolInput = Get-ToolInput $HookInput
    $parts = New-Object System.Collections.ArrayList
    foreach ($name in @("content", "new_string", "old_string", "patch", "diff", "cell_source")) {
        $v = Get-JsonValue $toolInput @($name)
        if ($v) { [void]$parts.Add((ConvertTo-SafeText $v)) }
    }
    if ($parts.Count -eq 0) { return ConvertTo-SafeText $toolInput }
    return ($parts -join "`n")
}

function Find-SecretMatch([string]$Text, [object]$Policy) {
    foreach ($item in $Policy.secretRegex) {
        if ($Text -match $item.pattern) {
            return [PSCustomObject]@{ Name = $item.name; Pattern = $item.pattern }
        }
    }
    return $null
}

function Find-RegexMatch([string]$Text, [object[]]$RegexList, [string]$NamePrefix) {
    foreach ($pattern in $RegexList) {
        if ($Text -match $pattern) {
            return [PSCustomObject]@{ Name = $NamePrefix; Pattern = $pattern }
        }
    }
    return $null
}

function Test-ProtectedPathText([string]$Text, [object]$Policy) {
    return Find-RegexMatch $Text $Policy.protectedPathRegex "protected path"
}

function Resolve-SafePath([string]$Path, [string]$Cwd) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Cwd $Path))
}

function Test-IsPathInside([string]$TargetPath, [string]$RootPath) {
    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $true }
    $target = [System.IO.Path]::GetFullPath($TargetPath).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
    if ($env:OS -eq "Windows_NT") {
        $target = $target.ToLowerInvariant()
        $root = $root.ToLowerInvariant()
    }
    return ($target -eq $root -or $target.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar))
}

function ConvertTo-RedactedText([string]$Text, [object]$Policy) {
    $out = $Text
    foreach ($item in $Policy.secretRegex) {
        $out = [regex]::Replace($out, $item.pattern, "[REDACTED:" + $item.name + "]")
    }
    if ($out.Length -gt 12000) { $out = $out.Substring(0, 12000) + "...[truncated]" }
    return $out
}

function Set-AuditLogAcl([string]$Path) {
    # M4: マルチユーザー環境で他ユーザーから監査ログが読まれないよう、
    # ACL を継承解除して CurrentUser のみ FullControl に絞る。失敗しても本処理は継続。
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        # 既存の継承ルールを完全に取り除く
        $existing = @($acl.Access)
        foreach ($r in $existing) {
            [void]$acl.RemoveAccessRule($r)
        }
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            'FullControl',
            'Allow'
        )
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        # ACL 設定失敗は致命ではない（ログ出力は継続させる）
        [Console]::Error.WriteLine("warn: failed to harden ACL on " + $Path + ": " + $_.Exception.Message)
    }
}

function Write-AuditLog([object]$HookInput, [string]$Mode, [string]$Decision, [string]$Reason, [string]$ObservedText, [object]$Policy) {
    $logDir = $env:AI_SAFE_LOG_DIR
    if (-not $logDir) { $logDir = Join-Path $HOME ".ai-safety\logs" }
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    $day = Get-Date -Format "yyyy-MM-dd"
    $path = Join-Path $logDir ("events-" + $day + ".jsonl")
    $isNew = -not (Test-Path -LiteralPath $path)
    if ($isNew) {
        $null = New-Item -ItemType File -Force -Path $path
        Set-AuditLogAcl $path
    }
    $entry = [PSCustomObject]@{
        ts = (Get-Date).ToString("o")
        user = $env:USERNAME
        computer = $env:COMPUTERNAME
        mode = $Mode
        decision = $Decision
        reason = $Reason
        cwd = Get-HookCwd $HookInput
        hook_event_name = (Get-JsonValue $HookInput @("hook_event_name", "eventName", "event"))
        tool_name = Get-ToolName $HookInput
        observed = (ConvertTo-RedactedText $ObservedText $Policy)
        packageVersion = $Policy.packageVersion
    }
    ($entry | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $path -Encoding UTF8
}

function Test-IsDomainMatch([string]$HostName, [string]$Pattern) {
    if ([string]::IsNullOrWhiteSpace($HostName) -or [string]::IsNullOrWhiteSpace($Pattern)) {
        return $false
    }
    $h = $HostName.ToLowerInvariant()
    $p = $Pattern.ToLowerInvariant()
    if ($p.StartsWith("*.")) {
        $suffix = $p.Substring(1) # ".pages.dev"
        return $h.EndsWith($suffix)
    }
    return ($h -eq $p -or $h.EndsWith("." + $p))
}

function Test-IsBlockedDomain([string]$HostName, [object]$Policy) {
    $blocked = Get-JsonValue $Policy @("blockedDomains")
    if ($null -eq $blocked) { return $false }
    foreach ($pattern in $blocked) {
        if (Test-IsDomainMatch $HostName ([string]$pattern)) { return $true }
    }
    return $false
}

function Test-IsAllowedDomain([string]$HostName, [object]$Policy) {
    if (Test-IsBlockedDomain $HostName $Policy) { return $false }
    $allowed = Get-JsonValue $Policy @("allowedDomains")
    if ($null -eq $allowed) { return $false }
    foreach ($pattern in $allowed) {
        if (Test-IsDomainMatch $HostName ([string]$pattern)) { return $true }
    }
    return $false
}

function Block-Action([object]$HookInput, [string]$Mode, [string]$Reason, [string]$ObservedText, [object]$Policy) {
    Write-AuditLog $HookInput $Mode "block" $Reason $ObservedText $Policy
    [Console]::Error.WriteLine("AI Safety Guard BLOCKED: " + $Reason)
    exit 2
}

function Allow-Action([object]$HookInput, [string]$Mode, [string]$Reason, [string]$ObservedText, [object]$Policy) {
    Write-AuditLog $HookInput $Mode "allow" $Reason $ObservedText $Policy
    exit 0
}

function Fail-Closed([string]$Mode, [string]$Message) {
    [Console]::Error.WriteLine("AI Safety Guard FAILED CLOSED (" + $Mode + "): " + $Message)
    exit 2
}
