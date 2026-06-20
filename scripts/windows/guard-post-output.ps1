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

    # 出力側は outputSecretRegex（本物のキー書式のみ。Generic sensitive assignment は除外）で
    # 検査する。汎用代入パターンで技術出力全体が誤ブロックされる over-blocking を回避する。
    # 入力側(guard-bash/guard-write の Find-SecretMatch)は secretRegex 全体のまま不変。
    $secret = Find-OutputSecretMatch $text $policy
    if ($secret) {
        Block-Action $inputObj "post-output" ("sensitive pattern in tool or AI output: " + $secret.Name) $text $policy
    }

    # 回答モニター用のスナップショット保存。PostToolUse のツール出力は helper 側で除外し、
    # Stop / AfterModel / AfterAgent など、回答本文を取れるイベントだけ latest-answer.json に残す。
    # 保存失敗・node 不在は安全判定に影響させない。
    try {
        $node = Get-Command node -ErrorAction SilentlyContinue
        $helper = Join-Path $PSScriptRoot "..\common\answer-snapshot.js"
        if ($node -and (Test-Path -LiteralPath $helper)) {
            $prevOutputEncoding = $OutputEncoding
            try {
                $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
                $text | & $node.Source $helper *> $null
            } finally {
                $OutputEncoding = $prevOutputEncoding
            }
        }
    } catch { }

    Allow-Action $inputObj "post-output" "output passed policy" $text $policy
} catch {
    Fail-Closed "post-output" $_.Exception.Message
}
