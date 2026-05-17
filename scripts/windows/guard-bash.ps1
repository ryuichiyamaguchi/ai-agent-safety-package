param()

try {
    . (Join-Path $PSScriptRoot "lib\SafetyPolicy.ps1")
    . (Join-Path $PSScriptRoot "lib\Explainer.ps1")
    $policy = Get-SafetyPolicy
    $inputObj = Read-HookInput
    Invoke-Explain -HookInput $inputObj -Mode "bash" -Policy $policy
    $cmd = Get-CommandText $inputObj

    if ([string]::IsNullOrWhiteSpace($cmd)) {
        Allow-Action $inputObj "bash" "empty command" "" $policy
    }

    $secret = Find-SecretMatch $cmd $policy
    if ($secret) {
        Block-Action $inputObj "bash" ("sensitive pattern in shell command: " + $secret.Name) $cmd $policy
    }

    $protected = Test-ProtectedPathText $cmd $policy
    if ($protected) {
        Block-Action $inputObj "bash" "protected path referenced in shell command" $cmd $policy
    }

    $danger = Find-RegexMatch $cmd $policy.dangerousCommandRegex "dangerous command"
    if ($danger) {
        Block-Action $inputObj "bash" ("dangerous shell command matched: " + $danger.Pattern) $cmd $policy
    }

    Allow-Action $inputObj "bash" "command passed policy" $cmd $policy
} catch {
    Fail-Closed "bash" $_.Exception.Message
}
