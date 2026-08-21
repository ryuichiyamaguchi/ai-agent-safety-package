# policy-floor.test.ps1 — 決定的 deny 床の回帰テスト (Windows / mac の policy-floor.test.sh と対称)
#
# 収録しているのは 2026-07-28 の敵対的レビューで実際に床を破った入力そのもの。
#   RED-1: フック JSON のエスケープ未復号（Windows は ConvertFrom-Json が復号する = 元から BLOCK。
#          mac を直した後もパリティが保たれていることを確認する）
#   RED-3: 環境変数 AI_SAFE_POLICY で無害なポリシーへ差し替えられる
#   空配列 / 無害化ポリシー: 読み込みには成功するので「読めた=床が生きている」ではないことの確認
#   Y-3: chmod -R 777
#   Y-4: シェル初期化ファイル・LaunchAgents 相当・.ai-safety への書き込み
# 実行: pwsh -NoProfile -File scripts/windows/test/policy-floor.test.ps1

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here "..\..\..")).Path
$guardBash = Join-Path $repo "scripts\windows\guard-bash.ps1"
$guardWrite = Join-Path $repo "scripts\windows\guard-write.ps1"
$policy = Join-Path $repo "policy\safety-policy.json"

$pass = 0; $fail = 0
function Ok($m) { Write-Host "PASS $m"; $script:pass++ }
function Ng($m) { Write-Host "FAIL $m"; $script:fail++ }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("policyfloor-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$logDir = Join-Path $tmp "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = "pwsh" }

function Invoke-Guard([string]$ScriptPath, [string]$Json, [hashtable]$Env) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = "-NoProfile -File `"$ScriptPath`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardInputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables["AI_SAFE_LOG_DIR"] = $logDir
    if ($Env) { foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] } }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($Json)
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(20000) | Out-Null
    return [PSCustomObject]@{ Code = $proc.ExitCode; Stdout = $out; Stderr = $err }
}

function BashJson([string]$Command) {
    return '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"' + ($tmp -replace '\\', '\\\\') + '","tool_input":{"command":"' + $Command + '"}}'
}
function WriteJson([string]$Path) {
    return '{"hook_event_name":"PreToolUse","tool_name":"Write","cwd":"' + ($tmp -replace '\\', '\\\\') + '","tool_input":{"file_path":"' + ($Path -replace '\\', '\\\\') + '","content":"hello"}}'
}

function ExpectBlock([string]$Label, [string]$Script, [string]$Json, [hashtable]$Env) {
    $r = Invoke-Guard $Script $Json $Env
    if ($r.Code -eq 2) { Ok "$Label (blocked)" } else { Ng "$Label — expected 2, got $($r.Code) $($r.Stderr)" }
}
function ExpectAllow([string]$Label, [string]$Script, [string]$Json, [hashtable]$Env) {
    $r = Invoke-Guard $Script $Json $Env
    if ($r.Code -eq 0 -and $r.Stdout -notmatch 'permissionDecision') { Ok "$Label (allowed)" }
    else { Ng "$Label — expected plain allow, got $($r.Code) $($r.Stdout)" }
}

$rm = 'rm -rf /Users/x/Documents'
$mode777 = '7' + '77'
$mode666 = '6' + '66'

# --- RED-1 パリティ: 復号済みで検査されること -------------------------------
ExpectBlock "RED-1 改行後の再帰削除" $guardBash (BashJson ("echo hi\n" + $rm)) $null
ExpectBlock "RED-1 タブ区切りの再帰削除" $guardBash (BashJson ("echo hi\t" + $rm)) $null
ExpectBlock "RED-1 改行後の find -delete" $guardBash (BashJson 'echo hi\nfind /Users/x -delete') $null
ExpectAllow "通常のテストコマンドは自動許可のまま" $guardBash (BashJson 'npm test') $null

# --- 入力そのものを読めないときは fail-closed（mac の plutil 復号失敗と同じ扱い）---
ExpectBlock "壊れた JSON は fail-closed" $guardBash 'this is not json at all' $null
ExpectAllow "空の入力は止めない" $guardBash '' $null

# --- Y-3 権限全開（他人に書き込みを与える形）— 2026-07-28 の裁定範囲 -------
#   対象   : 下3桁 777/666（先頭桁 0-7 可）/ 付与先に a か o を含み +・= で w を与える記号形
#   対象外 : 755・+x・u+w・g+w・a+r・a-w・付与先省略の chmod +w・setuid 単体
ExpectBlock "Y-3 chmod -R $mode777" $guardBash (BashJson ("chmod -R " + $mode777 + " /")) $null
ExpectBlock "Y-3 chmod $mode777 -R" $guardBash (BashJson ("chmod " + $mode777 + " -R /Users/x")) $null
ExpectBlock "Y-3 chmod -Rf $mode777" $guardBash (BashJson ("chmod -Rf " + $mode777 + " /Users/x")) $null
ExpectBlock "Y-3 chmod --recursive $mode777" $guardBash (BashJson ("chmod --recursive " + $mode777 + " /Users/x")) $null
ExpectBlock "Y-3 chmod -R -v $mode777" $guardBash (BashJson ("chmod -R -v " + $mode777 + " /Users/x")) $null
ExpectBlock "Y-3 chmod -v -R $mode777" $guardBash (BashJson ("chmod -v -R " + $mode777 + " /Users/x")) $null
ExpectBlock "Y-3 chmod $mode777 (従来形)" $guardBash (BashJson ("chmod " + $mode777 + " app.sh")) $null
ExpectBlock "Y-3 chmod 0$mode777" $guardBash (BashJson ("chmod 0" + $mode777 + " app.sh")) $null
ExpectBlock "Y-3 chmod 1$mode777 (sticky 付き)" $guardBash (BashJson ("chmod 1" + $mode777 + " /tmp/shared")) $null
ExpectBlock "Y-3 chmod $mode666" $guardBash (BashJson ("chmod " + $mode666 + " notes.txt")) $null
ExpectBlock "Y-3 chmod 0$mode666" $guardBash (BashJson ("chmod 0" + $mode666 + " notes.txt")) $null
ExpectBlock "Y-3 chmod -R a+rwx" $guardBash (BashJson 'chmod -R a+rwx /Users/x') $null
ExpectBlock "Y-3 chmod a+w" $guardBash (BashJson 'chmod a+w notes.txt') $null
ExpectBlock "Y-3 chmod a=rwx" $guardBash (BashJson 'chmod a=rwx /Users/x') $null
ExpectBlock "Y-3 chmod o+w" $guardBash (BashJson 'chmod o+w notes.txt') $null
ExpectBlock "Y-3 chmod go+w" $guardBash (BashJson 'chmod go+w notes.txt') $null
# カンマ区切りの複合指定: 2 つ目以降の節に危険な指定を隠す形も捕捉すること
ExpectBlock "Y-3 chmod a+x,o+w" $guardBash (BashJson 'chmod a+x,o+w notes.txt') $null
ExpectBlock "Y-3 chmod u+r,a+w" $guardBash (BashJson 'chmod u+r,a+w notes.txt') $null
ExpectBlock "Y-3 chmod o+w,u+x (1 節目が危険)" $guardBash (BashJson 'chmod o+w,u+x notes.txt') $null
ExpectBlock "Y-3 chmod -R a+x,o+w" $guardBash (BashJson 'chmod -R a+x,o+w /Users/x') $null
ExpectBlock "Y-3 chmod a+r,a+w" $guardBash (BashJson 'chmod a+r,a+w notes.txt') $null
ExpectBlock "Y-3 chmod u+x,go+w" $guardBash (BashJson 'chmod u+x,go+w notes.txt') $null
ExpectBlock "Y-3 chmod g+r,o=w (= 形)" $guardBash (BashJson 'chmod g+r,o=w notes.txt') $null
ExpectBlock "Y-3 chmod u+r,g+x,a+w (3 節)" $guardBash (BashJson 'chmod u+r,g+x,a+w notes.txt') $null
ExpectAllow "chmod u+w,g+x は通る" $guardBash (BashJson 'chmod u+w,g+x notes.txt') $null
ExpectAllow "chmod u+r,g+r は通る" $guardBash (BashJson 'chmod u+r,g+r notes.txt') $null
ExpectAllow "chmod u+rw,go+r は通る" $guardBash (BashJson 'chmod u+rw,go+r notes.txt') $null
ExpectAllow "chmod u+rw,go+rx は通る" $guardBash (BashJson 'chmod u+rw,go+rx notes.txt') $null
ExpectAllow "chmod a+r,u+w は通る" $guardBash (BashJson 'chmod a+r,u+w notes.txt') $null
ExpectAllow "chmod a+rX,u+w は通る" $guardBash (BashJson 'chmod a+rX,u+w notes.txt') $null
ExpectAllow "chmod u+x,g+x は通る" $guardBash (BashJson 'chmod u+x,g+x build.sh') $null

ExpectAllow "chmod +x は通常操作として通る" $guardBash (BashJson 'chmod +x build.sh') $null
ExpectAllow "chmod 755 は通る" $guardBash (BashJson 'chmod 755 build.sh') $null
ExpectAllow "chmod u+w は通る" $guardBash (BashJson 'chmod u+w notes.txt') $null
ExpectAllow "chmod g+w は通る" $guardBash (BashJson 'chmod g+w notes.txt') $null
ExpectAllow "chmod a+r (読み取りのみ) は通る" $guardBash (BashJson 'chmod a+r notes.txt') $null
ExpectAllow "chmod a-w (権限を狭める) は通る" $guardBash (BashJson 'chmod a-w notes.txt') $null
ExpectAllow "chmod +w (付与先省略) は通る" $guardBash (BashJson 'chmod +w notes.txt') $null
ExpectAllow "パスに 777 を含むだけなら通る" $guardBash (BashJson 'chmod 644 /tmp/777/notes.txt') $null

# Windows の権限全開（icacls / cacls）。付与先の名前ではなく権限記号で拾う。
ExpectBlock "Y-3 icacls /grant Everyone:F" $guardBash (BashJson 'icacls C:/data /grant Everyone:F') $null
ExpectBlock "Y-3 icacls /grant SID:F" $guardBash (BashJson 'icacls C:/data /grant *S-1-1-0:F') $null
ExpectBlock "Y-3 icacls /grant:r Users:M" $guardBash (BashJson 'icacls C:/data /grant:r Users:M') $null
ExpectBlock "Y-3 cacls /G Everyone:F" $guardBash (BashJson 'cacls report.txt /G Everyone:F') $null
ExpectAllow "icacls /grant Users:R (読み取り) は通る" $guardBash (BashJson 'icacls C:/data /grant Users:R') $null
ExpectAllow "icacls /remove は通る" $guardBash (BashJson 'icacls C:/data /remove Everyone') $null

# --- Y-4 書き込み先の保護 ----------------------------------------------------
ExpectBlock "Y-4 > で .zshrc 上書き" $guardBash (BashJson 'git log --all > /Users/x/.zshrc') $null
ExpectBlock "Y-4 2> で .zshrc 上書き" $guardBash (BashJson 'git log --all 2> /Users/x/.zshrc') $null
ExpectBlock "Y-4 >> で .bashrc 追記" $guardBash (BashJson 'echo evil >> /Users/x/.bashrc') $null
ExpectBlock "Y-4 tee で .zprofile" $guardBash (BashJson 'echo evil | tee -a /Users/x/.zprofile') $null
ExpectBlock "Y-4 .claude\settings.json へのリダイレクト" $guardBash (BashJson 'echo {} > /Users/x/.claude/settings.json') $null
ExpectBlock "Y-4 Write で .zshrc" $guardWrite (WriteJson '/Users/x/.zshrc') $null
ExpectBlock "Y-4 Write で安全ルール本体" $guardWrite (WriteJson (Join-Path $tmp ".ai-safety\policy\safety-policy.json")) $null
ExpectBlock "RED-2 .ai-safety はコマンドからも触れない" $guardBash (BashJson 'ls /Users/x/.ai-safety/cache') $null
ExpectAllow "ワークスペース内の通常リダイレクトは通る" $guardBash (BashJson 'npm run build > build.log') $null
ExpectAllow "ワークスペース内への Write は通る" $guardWrite (WriteJson (Join-Path $tmp "app.js")) $null

# --- RED-3 ポリシー差し替え --------------------------------------------------
$harmless = Join-Path $tmp "harmless-policy.json"
@'
{
  "packageVersion": "0.0.0-harmless",
  "allowedDomains": ["example.com"],
  "blockedDomains": ["blocked.example.com"],
  "protectedPathRegex": ["^ZZZ_NEVER_MATCHES_ZZZ$"],
  "secretRegex": [{ "name": "none", "pattern": "^ZZZ_NEVER_MATCHES_ZZZ$" }],
  "outputSecretRegex": [{ "name": "none", "pattern": "^ZZZ_NEVER_MATCHES_ZZZ$" }],
  "dangerousCommandRegex": ["^ZZZ_NEVER_MATCHES_ZZZ$"]
}
'@ | Set-Content -LiteralPath $harmless -Encoding UTF8

ExpectBlock "RED-3 差し替えポリシーを無視して床が残る" $guardBash (BashJson $rm) @{ "AI_SAFE_POLICY" = $harmless }
ExpectBlock "RED-3 AI_SAFE_ROOT 経由の差し替えも効かない" $guardBash (BashJson $rm) @{ "AI_SAFE_ROOT" = $tmp }
ExpectBlock "同梱ポリシーを指す AI_SAFE_POLICY は尊重される" $guardBash (BashJson $rm) @{ "AI_SAFE_POLICY" = $policy }

# --- 空配列 / 無害化ポリシー: 読めても床が死んでいれば止める -----------------
function New-Workspace([string]$Name, [scriptblock]$Mutate) {
    $ws = Join-Path $tmp $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $ws "policy") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $ws "scripts\windows\lib") | Out-Null
    Copy-Item (Join-Path $repo "scripts\windows\guard-bash.ps1") (Join-Path $ws "scripts\windows\") -Force
    Copy-Item (Join-Path $repo "scripts\windows\lib\SafetyPolicy.ps1") (Join-Path $ws "scripts\windows\lib\") -Force
    Copy-Item (Join-Path $repo "scripts\windows\lib\Explainer.ps1") (Join-Path $ws "scripts\windows\lib\") -Force
    $p = Get-Content -LiteralPath $policy -Raw -Encoding UTF8 | ConvertFrom-Json
    & $Mutate $p
    ($p | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath (Join-Path $ws "policy\safety-policy.json") -Encoding UTF8
    return (Join-Path $ws "scripts\windows\guard-bash.ps1")
}

$emptyGuard = New-Workspace "empty-ws" {
    param($p)
    $p.dangerousCommandRegex = @()
    $p.protectedPathRegex = @()
}
ExpectBlock "空配列ポリシーは fail-closed" $emptyGuard (BashJson $rm) $null

$neuteredGuard = New-Workspace "neutered-ws" {
    param($p)
    $p.dangerousCommandRegex = @(1..20 | ForEach-Object { "^ZZZ_NEVER_MATCHES_ZZZ$" })
}
ExpectBlock "無害化ポリシーは fail-closed" $neuteredGuard (BashJson $rm) $null

# --- WebFetch の宛先判定（2026-08-21 に許可リスト方式 → 拒否リスト方式へ変更）-------
#
#   (1) blockedDomains（45 件）に載っている宛先は止まる
#   (2) それ以外の普通の宛先は通る（旧 allowedDomains 15 件に無いものも通る）
#
# mac の policy-floor.test.sh の同名セクションと対称。ここが逆転したら出荷を止める。
$guardWebfetch = Join-Path $repo "scripts\windows\guard-webfetch.ps1"
function WebFetchJson([string]$Url) {
    return '{"hook_event_name":"PreToolUse","tool_name":"WebFetch","cwd":"' + ($tmp -replace '\\', '\\\\') + '","tool_input":{"url":"' + $Url + '","prompt":"read"}}'
}

ExpectBlock "WebFetch 拒否: pastebin.com" $guardWebfetch (WebFetchJson 'https://pastebin.com/raw/abc') $null
ExpectBlock "WebFetch 拒否: gist.github.com" $guardWebfetch (WebFetchJson 'https://gist.github.com/x/y') $null
ExpectBlock "WebFetch 拒否: 0x0.st" $guardWebfetch (WebFetchJson 'https://0x0.st/abc') $null
ExpectBlock "WebFetch 拒否: gofile.io (匿名アップロード)" $guardWebfetch (WebFetchJson 'https://gofile.io/d/abc') $null
ExpectBlock "WebFetch 拒否: catbox.moe (匿名アップロード)" $guardWebfetch (WebFetchJson 'https://catbox.moe/') $null
ExpectBlock "WebFetch 拒否: files.catbox.moe (ワイルドカード)" $guardWebfetch (WebFetchJson 'https://files.catbox.moe/abc.txt') $null
ExpectBlock "WebFetch 拒否: webhook.site (受信箱)" $guardWebfetch (WebFetchJson 'https://webhook.site/abc') $null
ExpectBlock "WebFetch 拒否: *.ngrok-free.app (使い捨てトンネル)" $guardWebfetch (WebFetchJson 'https://abc.ngrok-free.app/x') $null
ExpectBlock "WebFetch 拒否: *.trycloudflare.com" $guardWebfetch (WebFetchJson 'https://abc.trycloudflare.com/x') $null
ExpectBlock "WebFetch 拒否: *.workers.dev" $guardWebfetch (WebFetchJson 'https://abc.workers.dev/x') $null

ExpectAllow "WebFetch 許可: example.com" $guardWebfetch (WebFetchJson 'https://example.com/') $null
ExpectAllow "WebFetch 許可: docs.python.org（旧許可リスト外）" $guardWebfetch (WebFetchJson 'https://docs.python.org/3/library/os.html') $null
ExpectAllow "WebFetch 許可: qiita.com（旧許可リスト外）" $guardWebfetch (WebFetchJson 'https://qiita.com/items/abc') $null
ExpectAllow "WebFetch 許可: developer.mozilla.org（旧許可リスト外）" $guardWebfetch (WebFetchJson 'https://developer.mozilla.org/ja/docs/Web') $null
ExpectAllow "WebFetch 許可: github.com（従来どおり）" $guardWebfetch (WebFetchJson 'https://github.com/anthropics/claude-code') $null

ExpectBlock "WebFetch: 内部ネットワーク宛は止まる" $guardWebfetch (WebFetchJson 'http://127.0.0.1:8080/') $null
ExpectBlock "WebFetch: 192.168.x 宛は止まる" $guardWebfetch (WebFetchJson 'http://192.168.1.1/') $null
ExpectBlock "WebFetch: http/https 以外のスキームは止まる" $guardWebfetch (WebFetchJson 'file:///Users/x/.ssh/id_rsa') $null
ExpectBlock "WebFetch: 入力に秘密が混ざっていたら止まる" $guardWebfetch (WebFetchJson 'https://example.com/?k=sk-ant-abcdefghijklmnopqrstuvwxyz0123') $null

Write-Host ""
Write-Host "policy-floor(win): $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
