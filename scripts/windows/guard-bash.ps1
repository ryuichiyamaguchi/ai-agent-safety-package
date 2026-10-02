param()

# ---------------------------------------------------------------------------
# AI グレーゾーン自動承認（opt-in・既定 OFF）— mac の guard-bash.sh と対称。
# 決定的 deny を一切変えず、グレー確定後の最終 Allow の直前にだけ差し込む。
# 判定ロジックは scripts\common\command-judge.js（共有 Node モジュール）に集約。
# 2026-09-18: 旧「2 鍵」（提案者＋検証者）は 1 者判定に戻した（検証役が毎回タイムアウトし、
# かつ 2 鍵とも同一提供元・同一キーで独立性が無かったため。command-judge.js 冒頭参照）。
# ---------------------------------------------------------------------------

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
    # permissionDecisionReason は日本語（「AI 判定に必要な node が見つかりません」等）。
    # PowerShell 5.1 の既定（日本語 Windows では CP932）のまま出すと Claude 側で化けるので、
    # 書き出す直前に UTF-8（BOM なし）へ揃える。この関数はライブラリを読み込む前に
    # 定義されるため、まだ関数が無い場合に備えて存在確認してから呼ぶ。
    if (Get-Command Set-AiSafeConsoleUtf8 -ErrorAction SilentlyContinue) { Set-AiSafeConsoleUtf8 }
    [Console]::Out.WriteLine(($obj | ConvertTo-Json -Depth 6 -Compress))
    exit 0
}

# node を多層解決。Process.Start(UseShellExecute=false) は .cmd シムを起動できないので
# node.exe を優先する（node.cmd を渡すと毎回 catch →「AI 判定の起動に失敗しました」になる）。
function Resolve-NodeBin {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:NODE_BIN) { [void]$candidates.Add($env:NODE_BIN) }
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        [void]$candidates.Add([string]$cmd.Source)
        try {
            $sibling = Join-Path (Split-Path -Parent $cmd.Source) "node.exe"
            if ($sibling) { [void]$candidates.Add($sibling) }
        } catch { }
    }
    foreach ($c in @(
        (Join-Path $env:ProgramFiles "nodejs\node.exe"),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "nodejs\node.exe" } else { $null }),
        (Join-Path $env:APPDATA "npm\node.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\node.exe")
    )) { if ($c) { [void]$candidates.Add($c) } }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c) -and ($c -match '\.exe$')) { return $c }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
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
    $logDir = $env:AI_SAFE_LOG_DIR
    if (-not $logDir) { $logDir = Join-Path $HOME ".ai-safety\logs" }

    if ($env:AI_SAFE_ASSISTED_APPROVAL -ne "1") {
        # judge が回らない（env≠1）。d-claude 経路（本来 judge ON のはず）では「黙って無効化」を
        # 検知できるよう OFF を必ず監査＋now に残す。素の claude-safe/codex-safe（DS_CLAUDE_MODE≠1）
        # では OFF が正常なのでログは残さない（従来どおり素通り）。判定ロジックは変えない（表示のみ）。
        if ($env:DS_CLAUDE_MODE -eq "1") {
            Write-AuditLog $HookInput "bash" "assist-off" "assisted OFF (env≠1): AI judge 無効のまま従来allowへフォールスルー" $Command $Policy
            Add-AssistedNowLine $logDir "⚠️ AI judge OFF" "env≠1 のため判定せず従来allow（d-claude では要確認）"
        }
        return $false  # opt-in でなければ素通り
    }

    # judge を実施（発火）することを監査に明示。以降 assist-judge と最終 allow/ask も記録される。
    Write-AuditLog $HookInput "bash" "assist-on" "AI judge で判定します（AI_SAFE_ASSISTED_APPROVAL=1）" $Command $Policy

    # d-claude でも Gemini 判定を有効にする。判定役は DeepSeek でなく独立した Gemini
    # （command-judge.js → gemini-client.js）なので自己審査にならない。秘密・保護パス・決定的
    # 危険コマンドは上流で block 済みなので、judge に渡るのはグレーな定型コマンドのみ。
    # 以前はここで d-claude を skip して従来 Allow に倒していたが、自律運用の要望で廃止。
    # d-claude で無効化したい場合は起動側で AI_SAFE_ASSISTED_APPROVAL_OPTOUT=1 を指定する（launch-deepseek-gateway.ps1 参照）。

    # node が無ければ fail-closed で ask（opt-in 時は安全側に倒す）。
    $node = Resolve-NodeBin
    if (-not $node) {
        Emit-AssistedDecision "ask" "AI 判定に必要な node が見つかりません（安全側で確認します）"
    }

    $judge = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\common\command-judge.js"))
    if (-not (Test-Path -LiteralPath $judge)) {
        Emit-AssistedDecision "ask" "AI 判定スクリプトが見つかりません（安全側で確認します）"
    }

    # 検査対象コマンド（命令ではなくデータ）と cwd を JSON で組み立てて judge に渡す。
    $cwd = Get-HookCwd $HookInput
    $payload = ([PSCustomObject]@{ command = $Command; cwd = $cwd; mode = "bash" } | ConvertTo-Json -Depth 6 -Compress)

    $stdout = ""
    try {
        # 全体 30s タイムアウト（judge 1 回・既定モデルは実測 4 秒台／上限 12s に余裕をみる）。
        # stdin へ payload を UTF-8（BOM なし）のバイトで流す。
        # ★ PS 5.1（.NET Framework）には ProcessStartInfo.StandardInputEncoding が無い。
        #   触ると毎回 catch に落ち、グレーな Bash のたびに
        #   「AI 判定の起動に失敗しました」と確認ダイアログが出て作業が止まる。
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $node
        $psi.Arguments = "`"$judge`""
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $utf8 = New-Object System.Text.UTF8Encoding $false
        if ($psi.PSObject.Properties['StandardOutputEncoding']) {
            $psi.StandardOutputEncoding = $utf8
        }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $bytes = $utf8.GetBytes($payload)
        # 判定プロセスが入力を読む前に終わっていると（異常終了など）、書き込みが「パイプが閉じている」
        # 例外になる。起動はできているので「起動に失敗」ではなく、何も返さなかった扱い（下で
        # status=unavailable →「実行できませんでした」）にする。mac の guard-bash.sh と同じ見え方（v1.19.9）。
        try {
            $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $proc.StandardInput.BaseStream.Flush()
        } catch { }
        try { $proc.StandardInput.Close() } catch { }
        if (-not $proc.WaitForExit(30000)) {
            try { $proc.Kill() } catch { }
            Emit-AssistedDecision "ask" "AI 判定がタイムアウトしました（安全側で確認します）"
        }
        $stdout = $proc.StandardOutput.ReadToEnd()
        try { $null = $proc.StandardError.ReadToEnd() } catch { }
    } catch {
        try { Write-AuditLog $HookInput "bash" "assist-error" ("judge spawn failed: " + $_.Exception.Message) $Command $Policy } catch { }
        Emit-AssistedDecision "ask" "AI 判定の起動に失敗しました（安全側で確認します）"
    }

    # judge 出力を解析。decision=allow を厳密に確認できたときだけ allow、それ以外は ask（fail-closed）。
    $decision = "ask"; $verdict = "ask"; $reason = ""; $status = "unavailable"
    try {
        $j = $stdout | ConvertFrom-Json
        if ($j) {
            if ($j.decision -eq "allow") { $decision = "allow" }
            if ($j.judge) {
                if ($j.judge.verdict) { $verdict = [string]$j.judge.verdict }
                if ($j.judge.reason) { $reason = [string]$j.judge.reason }
                if ($j.judge.status) { $status = [string]$j.judge.status }
            }
        }
    } catch { $decision = "ask"; $status = "unavailable" }

    # 監査ログ（判定 + 最終）。
    Write-AuditLog $HookInput "bash" "assist-judge" ("judge=" + $verdict + " (" + $status + "): " + $reason) $Command $Policy

    if ($decision -eq "allow") {
        Write-AuditLog $HookInput "bash" "assist-allow" ("AI 判定で自動承認: judge=" + $verdict) $Command $Policy
        Add-AssistedNowLine $logDir "✅ AI判定で自動承認" ("judge=" + $verdict)
        Emit-AssistedDecision "allow" "AI が承認しました（定型・低影響と判断）"
    }

    # 「AI に聞けなかった」(status=unavailable: キー未設定・通信断・タイムアウト) と
    # 「AI が慎重に判断した」(status=ok) は同じ ask でも原因が違うので文言を分ける。
    Write-AuditLog $HookInput "bash" "assist-ask" ("人間に確認: judge=" + $verdict + " (" + $status + ")") $Command $Policy
    if ($status -eq "unavailable") {
        Add-AssistedNowLine $logDir "⚠️ AI判定できず→人間に確認" ("judge 実行不可（" + $reason + "）")
        Emit-AssistedDecision "ask" "AI 判定を実行できませんでした（AIコーチのキー・通信・時間切れ）。人間に確認します"
    } else {
        Add-AssistedNowLine $logDir "❓ AI判定→人間に確認" ("judge=" + $verdict + ": " + $reason)
        # 理由をそのまま見せる（「なぜ聞かれたか」が分からないと利用者は判断できない）。
        if ($reason) {
            Emit-AssistedDecision "ask" ("自動承認しませんでした: " + $reason)
        } else {
            Emit-AssistedDecision "ask" "AI が自動承認してよいと確信できませんでした（人間に確認します）"
        }
    }
    return $false  # 到達しない（Emit-AssistedDecision が exit する）が保険
}

# 安全な loopback fetch（自分の localhost 開発サーバへの curl/wget）だけ decisive deny から救う。
# 外部宛て・複合コマンド・proxy/resolve 等のトリックは一切許可せず、従来どおり deny の底に残す。
# 判定は厳格ホワイトリスト:「メタ文字ゼロ + 先頭 curl|wget + 宛先が loopback リテラルのみ」。
# 少しでも形が外れたら $false → 呼び出し側の decisive deny にフォールスルー（fail-safe）。mac guard-bash.sh と対称。
function Test-IsSafeLoopbackFetch([string]$Command) {
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    # メタ文字・制御文字・クォート・変数展開・バックスラッシュを 1 個でも含めば対象外（; や $() の連結・注入を封じる）。IPv6 の [] は許可。
    if ($Command -match '[;&|<>`$(){}"''\\*?\x00-\x1F]') { return $false }
    # proxy/resolve/connect-to/interface 系（宛先すり替え）フラグは明示的に拒否（多重防御）。
    if ($Command -match '(--resolve|--connect-to|--proxy|--interface|(^|\s)-x(\s|$))') { return $false }
    # curl|wget + 単純フラグ列 + (scheme://)? loopbackホスト (:port)? (/path)? を末尾に 1 個だけ。
    if ($Command -match '^(curl|wget)(\s+-{1,2}[A-Za-z][A-Za-z0-9=._-]*)*\s+(https?://)?(localhost|127(\.[0-9]{1,3}){3}|\[::1\]|::1)(:[0-9]{1,5})?(/\S*)?$') { return $true }
    return $false
}

function Test-IsScopedGeneratedCleanup([string]$Command) {
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    $targets = '(node_modules|build|dist|coverage|target|\.next|\.turbo)'
    $unix = '^rm\s+(-[A-Za-z]*r[A-Za-z]*|--recursive)(\s+(-f|--force))?\s+(\.\\|\.\/)?' +
             $targets + '(\s+(\.\\|\.\/)?' + $targets + ')*\s*$'
    $powerShell = '^Remove-Item\s+(-Recurse\s+(-Force\s+)?|-Force\s+-Recurse\s+)(\.\\|\.\/)?' +
                  $targets + '(\s*,?\s*(\.\\|\.\/)?' + $targets + ')*\s*$'
    return ($Command -match $unix -or $Command -match $powerShell)
}

# 共通部品（lib\SafetyPolicy.ps1）は Fail-Closed そのものを定義している。読み込めないまま下の
# catch へ落ちると Fail-Closed を呼べず、エラーを 1 行出して exit 0（＝許可）で終わっていた。
# Codex / Gemini / AntiGravity はガードを -File で直接起動するので、部品が壊れたり消えたりすると
# 危険なコマンドまで素通しになる（v1.19.8 で実測して修正）。読めなければ、ここで止める。
$ErrorActionPreference = "Stop"
try {
    . ([System.IO.Path]::Combine($PSScriptRoot, "lib", "SafetyPolicy.ps1"))
    Set-AiSafeConsoleUtf8
} catch {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    [Console]::Error.WriteLine("AI Safety Guard FAILED CLOSED: 安全ガードの共通部品（lib\SafetyPolicy.ps1）を読み込めませんでした。導入（インストール）をやり直してください: " + $_.Exception.Message)
    exit 2
}

try {
    # 日本語のメッセージを出す前に、hook の出力を UTF-8 に固定する。
    # （PowerShell 5.1 の既定は CP932 で、Claude Code / Codex は UTF-8 として読むため）
    Set-AiSafeConsoleUtf8
    # 解説カードの部品は判定に使わない。読めなくても判定は続ける（v1.19.7）。
    try { . ([System.IO.Path]::Combine($PSScriptRoot, "lib", "Explainer.ps1")) } catch {
        [Console]::Error.WriteLine("warn: 解説カードの部品を読み込めませんでした（判定はそのまま続けます）: " + $_.Exception.Message)
    }
    $policy = Get-SafetyPolicy
    $inputObj = Read-HookInput
    Invoke-AiSafeExplain $inputObj "bash" $policy
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

    # 書き込み先（> >> tee）が設定ファイル等なら止める。読み取りは止めない（mac guard-bash.sh と対称）。
    $redirectHit = Test-RedirectProtectedCommand $cmd $policy
    if ($redirectHit) {
        Block-Action $inputObj "bash" ("protected file targeted by output redirect (設定ファイルの書き換え): " + $redirectHit.Target) $cmd $policy
    }

    # loopback（localhost/127.0.0.1/::1）宛ての単純 fetch は許可。外部宛ては下の decisive deny に落とす。
    if (Test-IsSafeLoopbackFetch $cmd) {
        Allow-Action $inputObj "bash" "loopback fetch to localhost permitted" $cmd $policy
    }
    if (Test-IsScopedGeneratedCleanup $cmd) {
        Ask-Action $inputObj "bash" "プロジェクト内の生成物をまとめて削除します。対象を確認できた場合だけ、今回だけ許可してください" $cmd $policy
    }

    $danger = Find-RegexMatch $cmd $policy.dangerousCommandRegex "dangerous command"
    if ($danger) {
        Block-Action $inputObj "bash" ("dangerous shell command matched: " + $danger.Pattern) $cmd $policy
    }

    # ここに来た時点でコマンドは「グレー」。AI assisted approval が判定を下せばそこで exit。
    # OFF / スキップ条件のときだけ $false が返り、従来どおりの Allow にフォールスルーする。
    Invoke-AssistedApproval $inputObj $cmd $policy | Out-Null

    Allow-Action $inputObj "bash" "command passed policy" $cmd $policy
} catch {
    Fail-Closed "bash" $_.Exception.Message
}
