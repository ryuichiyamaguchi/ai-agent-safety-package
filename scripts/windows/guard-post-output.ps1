param()

try {
    . (Join-Path $PSScriptRoot "lib\SafetyPolicy.ps1")
    . (Join-Path $PSScriptRoot "lib\Explainer.ps1")
    $policy = Get-SafetyPolicy
    $inputObj = Read-HookInput
    Invoke-Explain -HookInput $inputObj -Mode "post-output" -Policy $policy
    $text = ConvertTo-SafeText $inputObj

    $secret = Find-SecretMatch $text $policy
    if ($secret) {
        Block-Action $inputObj "post-output" ("sensitive pattern in tool or AI output: " + $secret.Name) $text $policy
    }

    Allow-Action $inputObj "post-output" "output passed policy" $text $policy
} catch {
    Fail-Closed "post-output" $_.Exception.Message
}
