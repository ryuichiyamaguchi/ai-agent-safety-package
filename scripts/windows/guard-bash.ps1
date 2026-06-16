param()

# ---------------------------------------------------------------------------
# 2 鍵グレーゾーン自動承認（opt-in・既定 OFF）— mac の guard-bash.sh と対称。
# 決定的 deny を一切変えず、グレー確定後の最終 Allow の直前にだけ差し込む。
# 判定ロジックは scripts\common\two-key-judge.js（共有 Node モジュール）に集約。
# ---------------------------------------------------------------------------

# d-claude セッション検出（monitor-server.js の coachRedact / mac guard と同じ）。
# coach-engine マーカーが存在し fresh<12h で中身 "d-claude" のとき $true。
function Test-IsDClaudeSession([string]$LogDir) {
    try {
        $marker = Join-Path $LogDir "coach-engine"
        if (-not (Test-Path -LiteralPath $marker)) { return $false }
        $info = Get-Item -LiteralPath $marker -ErrorAction SilentlyContinue
        if (-not $info) { return $false }
        $ageMs = ((Get-Date) - $info.LastWriteTime).TotalMilliseconds
        if ($ageMs -lt 0 -or $ageMs -gt (12 * 60 * 60 * 1000)) { return $false }
        $content = (Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue)
        return (($content -ne $null) -and ($content.Trim() -eq "d-claude"))
    } catch { return $false }
}

# Claude PreToolUse permissionDecision JSON を stdout に出して exit 0。
# JSON は exit 0 のときだけ処理される（exit 2 では無視される＝決定的 deny 経路とは別）。
function Emit-AssistedDecision([string]$Decision, [string]$Reason) {
    $obj = [PSCustomObject]@{
        hookSpecificOutput = [PSCustomObject]@{
            hookEventName = "PreToolUse"
            permissionDecision = $Decision
            permissionDecisionReason = $Reason
        }
    }
    [Console]::Out.WriteLine(($obj | ConvertTo-Json -Depth 6 -Compress))
    exit 0
}

# node を多層解決（launch-claude-safe.ps1 の claude 解決と同方針）。
function Resolve-NodeBin {
    if ($env:NODE_BIN -and (Test-Path -LiteralPath $env:NODE_BIN)) { return $env:NODE_BIN }
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @(
        (Join-Path $env:APPDATA "npm\node.exe"),
        (Join-Path $env:ProgramFiles "nodejs\node.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\node.exe")
    )) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

# now.html へ 1 行サマリを最小追記（正規 writer には触れず </body> 直前に <div> を 1 つ挿入）。
# 失敗してもガードの判定は止めない（best-effort）。
function Add-AssistedNowLine([string]$LogDir, [string]$Title, [string]$Detail) {
    try {
        $out = Join-Path $LogDir "now.html"
        if (-not (Test-Path -LiteralPath $out)) { return }
        $html = [System.IO.File]::ReadAllText($out)
        $etitle = ConvertTo-HtmlEscaped $Title
        $edetail = ConvertTo-HtmlEscaped $Detail
        $line = "<div class=`"cmeta`">🔑 $etitle ・ $edetail</div>"
        $idx = $html.LastIndexOf("</body>")
        if ($idx -ge 0) {
            $html = $html.Substring(0, $idx) + $line + "`n" + $html.Substring($idx)
        } else {
            $html = $html + $line
        }
        Write-NowHtmlFile $LogDir $html
    } catch { }
}

# assisted approval 本体。判定を下したら（allow/ask いずれも）Emit-AssistedDecision で exit する。
# OFF / スキップ条件のときだけ呼び出し側の従来 Allow にフォールスルーする（$false を返す）。
function Invoke-AssistedApproval([object]$HookInput, [string]$Command, [object]$Policy) {
    if ($env:AI_SAFE_ASSISTED_APPROVAL -ne "1") { return $false }  # opt-in でなければ素通り

    $logDir = $env:AI_SAFE_LOG_DIR
    if (-not $logDir) { $logDir = Join-Path $HOME ".ai-safety\logs" }

    # d-claude セッションはスキップ（従来 Allow へ）。
    if (Test-IsDClaudeSession $logDir) { return $false }

    # node が無ければ fail-closed で ask（opt-in 時は安全側に倒す）。
    $node = Resolve-NodeBin
    if (-not $node) {
        Emit-AssistedDecision "ask" "AI 判定に必要な node が見つかりません（安全側で確認します）"
    }

    $judge = Join-Path $PSScriptRoot "..\common\two-key-judge.js"
    if (-not (Test-Path -LiteralPath $judge)) {
        Emit-AssistedDecision "ask" "AI 判定スクリプトが見つかりません（安全側で確認します）"
    }

    # 検査対象コマンド（命令ではなくデータ）と cwd を JSON で組み立てて judge に渡す。
    $cwd = Get-HookCwd $HookInput
    $payload = ([PSCustomObject]@{ command = $Command; cwd = $cwd; mode = "bash" } | ConvertTo-Json -Depth 6 -Compress)

    $stdout = ""
    try {
        # 全体 20s タイムアウト（各鍵 8s × 並列 + 余裕）。stdin へ payload を流して judge を実行。
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $node
        $psi.Arguments = "`"$judge`""
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardInputEncoding = [System.Text.Encoding]::UTF8
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Write($payload)
        $proc.StandardInput.Close()
        if (-not $proc.WaitForExit(20000)) {
            try { $proc.Kill() } catch { }
            Emit-AssistedDecision "ask" "AI 判定がタイムアウトしました（安全側で確認します）"
        }
        $stdout = $proc.StandardOutput.ReadToEnd()
    } catch {
        Emit-AssistedDecision "ask" "AI 判定の起動に失敗しました（安全側で確認します）"
    }

    # judge 出力を解析。decision=allow を厳密に確認できたときだけ allow、それ以外は ask（fail-closed）。
    $decision = "ask"; $k1v = "ask"; $k1r = ""; $k2v = "ask"; $k2r = ""
    try {
        $j = $stdout | ConvertFrom-Json
        if ($j) {
            if ($j.decision -eq "allow") { $decision = "allow" }
            if ($j.key1) { if ($j.key1.verdict) { $k1v = [string]$j.key1.verdict }; if ($j.key1.reason) { $k1r = [string]$j.key1.reason } }
            if ($j.key2) { if ($j.key2.verdict) { $k2v = [string]$j.key2.verdict }; if ($j.key2.reason) { $k2r = [string]$j.key2.reason } }
        }
    } catch { $decision = "ask" }

    # 監査ログ（両鍵 + 最終）。
    Write-AuditLog $HookInput "bash" "assist-key1" ("key1=" + $k1v + ": " + $k1r) $Command $Policy
    Write-AuditLog $HookInput "bash" "assist-key2" ("key2=" + $k2v + ": " + $k2r) $Command $Policy

    if ($decision -eq "allow") {
        Write-AuditLog $HookInput "bash" "assist-allow" ("2鍵承認: key1=" + $k1v + " / key2=" + $k2v) $Command $Policy
        Add-AssistedNowLine $logDir "✅ AI2鍵で自動承認" ("key1=" + $k1v + " / key2=" + $k2v)
        Emit-AssistedDecision "allow" "AI 2 鍵がともに承認（定型・低影響と判断）"
    }

    Write-AuditLog $HookInput "bash" "assist-ask" ("人間に確認: key1=" + $k1v + " / key2=" + $k2v) $Command $Policy
    Add-AssistedNowLine $logDir "❓ AI判定→人間に確認" ("key1=" + $k1v + " / key2=" + $k2v)
    Emit-AssistedDecision "ask" "AI 2 鍵のどちらかが確信を持てませんでした（人間に確認します）"
    return $false  # 到達しない（Emit-AssistedDecision が exit する）が保険
}

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

    # ここに来た時点でコマンドは「グレー」。2 鍵 assisted approval が判定を下せばそこで exit。
    # OFF / スキップ条件のときだけ $false が返り、従来どおりの Allow にフォールスルーする。
    Invoke-AssistedApproval $inputObj $cmd $policy | Out-Null

    Allow-Action $inputObj "bash" "command passed policy" $cmd $policy
} catch {
    Fail-Closed "bash" $_.Exception.Message
}
