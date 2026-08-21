param()

try {
    . (Join-Path $PSScriptRoot "lib\SafetyPolicy.ps1")
    # 日本語のメッセージを出す前に、hook の出力を UTF-8 に固定する。
    # （PowerShell 5.1 の既定は CP932 で、Claude Code / Codex は UTF-8 として読むため）
    Set-AiSafeConsoleUtf8
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
        # 「自分の道具（スキル・コマンド）の置き場」はワークスペース外でも確認なしで通す。
        # v1.17 で「PC 全体に最低限の安全設定を入れる」設計へ変わり、作業フォルダの中だけで
        # 使う前提が外れたため。設定そのもの（~\.claude\settings.json 等）は免除表に当たらない
        # ので、下の Test-RedirectProtectedPath で従来どおり deny される。
        if ((Test-ToolboxWritablePath $resolved $policy) -or (Test-ToolboxWritablePath $target $policy)) {
            $outsideWorkspace = $false
        }
        $protectedTarget = Test-ProtectedPathText $resolved $policy
        if ($protectedTarget) {
            Block-Action $inputObj "write" ("protected path write target: " + $target) $observed $policy
        }
        # シェル初期化ファイル・スタートアップ・各 CLI の設定ディレクトリ・安全パッケージ自身
        # への書き込みは決定的に止める（mac guard-write.sh と同一集合）。リダイレクトだけ守って
        # Write ツールが素通しでは意味がないため、生パスと解決後パスの両方を見る。
        $redirectTarget = Test-RedirectProtectedPath $resolved $policy
        if (-not $redirectTarget) { $redirectTarget = Test-RedirectProtectedPath $target $policy }
        if ($redirectTarget) {
            Block-Action $inputObj "write" ("protected configuration file targeted by write: " + $target) $observed $policy
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
