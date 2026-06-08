param()

try {
    . (Join-Path $PSScriptRoot "lib\SafetyPolicy.ps1")
    . (Join-Path $PSScriptRoot "lib\Explainer.ps1")
    $policy = Get-SafetyPolicy
    $inputObj = Read-HookInput
    # 注: post-output はカードを書かない。書くと、ターン終了の Stop イベントで
    # 直前のコマンドカードを汎用カード(「AI の出力を確認しています」)で上書きし、
    # シェルコマンドがモニターに残らなくなる。検査(下の block/allow)は維持。
    $text = ConvertTo-SafeText $inputObj

    $secret = Find-SecretMatch $text $policy
    if ($secret) {
        Block-Action $inputObj "post-output" ("sensitive pattern in tool or AI output: " + $secret.Name) $text $policy
    }

    Allow-Action $inputObj "post-output" "output passed policy" $text $policy
} catch {
    Fail-Closed "post-output" $_.Exception.Message
}
