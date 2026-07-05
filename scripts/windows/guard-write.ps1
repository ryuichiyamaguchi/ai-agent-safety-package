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

    # 保護パス・秘密・危険生成は deny（exit 2）。ワークスペース外書き込みだけは deny でなく
    # ask（人間に承認を求める）にする。ask は最後に判定する — 先に deny 群を全部通すことで、
    # 「ワークスペース外の .env」のような危険物が ask で素通りするのを防ぐ。
    $outsideWorkspace = $false
    if (-not [string]::IsNullOrWhiteSpace($target)) {
        $resolved = Resolve-SafePath $target $cwd
        if (-not (Test-IsPathInside $resolved $cwd)) {
            $outsideWorkspace = $true
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

    if ($outsideWorkspace) {
        Ask-Action $inputObj "write" ("ワークスペース外への書き込みです（" + $resolved + "）。許可しますか？") $observed $policy
    }

    Allow-Action $inputObj "write" "write passed policy" $observed $policy
} catch {
    Fail-Closed "write" $_.Exception.Message
}
