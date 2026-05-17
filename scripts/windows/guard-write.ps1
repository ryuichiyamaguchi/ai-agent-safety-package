param()

try {
    . (Join-Path $PSScriptRoot "lib\SafetyPolicy.ps1")
    . (Join-Path $PSScriptRoot "lib\Explainer.ps1")
    $policy = Get-SafetyPolicy
    $inputObj = Read-HookInput
    Invoke-Explain -HookInput $inputObj -Mode "write" -Policy $policy
    $cwd = Get-HookCwd $inputObj
    $target = Get-WriteTarget $inputObj
    $content = Get-WriteContent $inputObj
    $observed = $target + "`n" + $content

    if (-not [string]::IsNullOrWhiteSpace($target)) {
        $resolved = Resolve-SafePath $target $cwd
        if (-not (Test-IsPathInside $resolved $cwd)) {
            Block-Action $inputObj "write" ("write outside workspace: " + $resolved) $observed $policy
        }
        $protectedTarget = Test-ProtectedPathText $resolved $policy
        if ($protectedTarget) {
            Block-Action $inputObj "write" ("protected path write target: " + $target) $observed $policy
        }
    }

    $secret = Find-SecretMatch $content $policy
    if ($secret) {
        Block-Action $inputObj "write" ("sensitive pattern in generated file: " + $secret.Name) $observed $policy
    }

    $generated = Find-RegexMatch $content $policy.generatedCodeDenyRegex "generated code deny"
    if ($generated) {
        Block-Action $inputObj "write" "generated code contains blocked read or exfil pattern" $observed $policy
    }

    $danger = Find-RegexMatch $content $policy.dangerousCommandRegex "dangerous embedded command"
    if ($danger) {
        Block-Action $inputObj "write" "generated content embeds dangerous command" $observed $policy
    }

    Allow-Action $inputObj "write" "write passed policy" $observed $policy
} catch {
    Fail-Closed "write" $_.Exception.Message
}
