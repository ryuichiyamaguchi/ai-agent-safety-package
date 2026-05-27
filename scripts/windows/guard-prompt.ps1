param()

try {
    . (Join-Path $PSScriptRoot "lib\SafetyPolicy.ps1")
    . (Join-Path $PSScriptRoot "lib\Explainer.ps1")
    $policy = Get-SafetyPolicy
    $inputObj = Read-HookInput
    Invoke-Explain -HookInput $inputObj -Mode "prompt" -Policy $policy
    $prompt = Get-PromptText $inputObj

    $secret = Find-SecretMatch $prompt $policy
    if ($secret) {
        Block-Action $inputObj "prompt" ("sensitive pattern in user input: " + $secret.Name) $prompt $policy
    }

    $protected = Test-ProtectedPathText $prompt $policy
    if ($protected) {
        Block-Action $inputObj "prompt" "user input asks for or contains protected path" $prompt $policy
    }

    $danger = Find-RegexMatch $prompt $policy.dangerousCommandRegex "dangerous prompt"
    if ($danger) {
        Block-Action $inputObj "prompt" "user input contains a blocked command pattern" $prompt $policy
    }

    Allow-Action $inputObj "prompt" "prompt passed policy" $prompt $policy
} catch {
    Fail-Closed "prompt" $_.Exception.Message
}
