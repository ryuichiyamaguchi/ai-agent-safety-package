param()

# guard-prompt.ps1 — UserPromptSubmit ガード（発話は寛容・実行は guard-bash が守る）
#
# 方針: プロンプトは「発話」であって「実行」ではない。危険なコマンドの実際の実行は
# PreToolUse の guard-bash が捕捉する。よってここでは危険コマンド regex(dangerousCommandRegex)
# も保護パス regex(protectedPathRegex) もプロンプトに適用しない。受講者が学ぶために
# 「rm -r って何？」「cat .env で中身を見たい」「password=mytestpass123 と例に書いた」
# と質問することを封じないためである（教える対象を聞くことすら止めるのは製品目的の真逆）。
#
# 唯一のブロック条件: 本物の API キー書式（outputSecretRegex = Generic sensitive assignment
# を除いた実キーのみ = OpenAI/Anthropic/Google/AWS/GitHub/Slack/JWT/秘密鍵ブロック）を
# AI に送ろうとした場合だけ。Generic な代入（password=... 等）は通す。
#
# 既知バグ②の修正: 可視化 Invoke-Explain を fail-closed の外側に出し、例外を握りつぶす
# （guard-observe と同じフェイルセーフ方針）。PS5.1 で可視化や JSON パースが例外を投げても、
# 無害なプロンプトを Fail-Closed で全ブロックしてはならない。発話段階の失敗は allow に倒す。

# 発話は寛容 = フェイルオープン。lib は StrictMode 2.0 / Stop を設定するため prompt では緩め直す。
Set-StrictMode -Off
$ErrorActionPreference = "SilentlyContinue"

# lib 読み込み（失敗しても発話は止めない = 実行は guard-bash が守る）。
try {
    . (Join-Path $PSScriptRoot "lib\SafetyPolicy.ps1")
    # 日本語のメッセージを出す前に、hook の出力を UTF-8 に固定する。
    # （PowerShell 5.1 の既定は CP932 で、Claude Code / Codex は UTF-8 として読むため）
    Set-AiSafeConsoleUtf8
    . (Join-Path $PSScriptRoot "lib\Explainer.ps1")
} catch {
    exit 0
}
# lib が再設定した StrictMode/ErrorActionPreference を prompt 用に緩め直す。
Set-StrictMode -Off
$ErrorActionPreference = "SilentlyContinue"

# policy 読込が失敗して policy 由来の秘密検出器が使えないときの「緊急」本物キー regex。
# policy/outputSecretRegex（本物キー書式のみ）と同等。壊れた policy でもキーだけは止める。
$EmergencyKeyRe = 'sk-(proj-)?[A-Za-z0-9_\-]{20,}|sk-ant-[A-Za-z0-9_\-]{20,}|AIza[0-9A-Za-z_\-]{25,}|(AKIA|ASIA)[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{36,255}|xox[baprs]-[A-Za-z0-9\-]{10,}|eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+|-----BEGIN (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----'

# 本物のキー検出時のブロック。英語生 stderr でなく日本語で理由＋次の一手＋コーチ誘導を出す。
function Block-PromptSecret([object]$HookInput, [string]$Prompt, [object]$Policy, [object]$Secret) {
    $name = ""
    try { if ($Secret -and $Secret.Name) { $name = [string]$Secret.Name } } catch { $name = "" }
    try {
        if ($null -ne $Policy) {
            Write-AuditLog $HookInput "prompt" "block" ("sensitive API key format in user input: " + $name) $Prompt $Policy
        }
    } catch { }
    $lines = @(
        "【AI 安全ガード】入力に本物の API キーらしき文字列が含まれています。",
        "API キーやアクセストークンは AI に送らないでください（会話履歴やログに残る恐れがあります）。",
        "次の一手: キー本体を伏せて（例: sk-xxxx… や「自分の APIキー」と書く）質問し直してください。",
        "使い方が分からないときは、モニター画面の AI コーチに「APIキーの扱い方」と聞いてください。"
    )
    try { [Console]::Error.WriteLine(($lines -join [Environment]::NewLine)) } catch { }
    exit 2
}

# --- フック入力の取得 ---
# raw stdin を UTF-8 で一度だけ読む（Read-HookInput と同じ読み方）。JSON パースが失敗しても
# raw を保持し、本物キーの検査は raw に対して行う（壊れた JSON にキーが紛れても素通りさせない
# = RED-2 修正）。パース例外自体で発話を止めない方針（既知バグ②）は維持。
$rawInput = ""
try {
    $stdinStream = [Console]::OpenStandardInput()
    $stdinReader = New-Object System.IO.StreamReader($stdinStream, [System.Text.Encoding]::UTF8)
    try { $rawInput = $stdinReader.ReadToEnd() } finally { $stdinReader.Dispose() }
    if ($rawInput.Length -gt 262144) { $rawInput = $rawInput.Substring(0, 262144) }
} catch { $rawInput = "" }

$policy = $null
try { $policy = Get-SafetyPolicy } catch { $policy = $null }

# JSON パース（失敗しても発話は止めない = 既知バグ②）。失敗時 $inputObj は $null のまま進む。
$inputObj = $null
try { if (-not [string]::IsNullOrWhiteSpace($rawInput)) { $inputObj = $rawInput | ConvertFrom-Json } } catch { $inputObj = $null }

# プロンプト本文を取り出す。パース失敗時は raw 全体を秘密検査対象にする（RED-2）。
$prompt = ""
if ($null -ne $inputObj) { try { $prompt = Get-PromptText $inputObj } catch { $prompt = "" } }
$secretScanText = $prompt
if ([string]::IsNullOrEmpty($secretScanText)) { $secretScanText = $rawInput }

# --- 唯一の deny 条件: 本物の API キー書式（narrow = outputSecretRegex） ---
# ★可視化(Invoke-Explain)より先に検査する。本物キーを含む入力は now.html カードにも残さないため、
#   キー検出時は explain を呼ばず即ブロックする（RED-1 / RED-3 修正）。
# dangerousCommandRegex / protectedPathRegex はここでは適用しない（発話は寛容）。
# Generic assignment（password=... 等）は outputSecretRegex に含まれないため通す。
if ($null -ne $policy) {
    $secret = $null
    try { $secret = Find-OutputSecretMatch $secretScanText $policy } catch { $secret = $null }
    if ($secret) {
        Block-PromptSecret $inputObj $prompt $policy $secret
    }
} else {
    # policy 読込失敗＝policy 由来の検出器(Find-OutputSecretMatch)が使えない。緊急の本物キー
    # regex だけを適用し、キーがあれば explain を呼ばずに即ブロック（now.html への漏洩回避＝RED 修正）。
    # キーが無ければ発話を許可する（explain は policy 無しでは呼ばない＝生プロンプトを now.html に残さない）。
    if ($secretScanText -match $EmergencyKeyRe) {
        try {
            [Console]::Error.WriteLine("【AI 安全ガード】入力に本物の API キーらしき文字列が含まれています。")
            [Console]::Error.WriteLine("API キーやアクセストークンは AI に送らないでください。キー本体を伏せて質問し直してください。")
        } catch { }
        exit 2
    }
    exit 0
}

# --- 可視化（fail-safe・絶対に発話を止めない = 既知バグ②の本丸） ---
# 本物キーが無いと確認できた後にだけ書く（policy があるときのみ＝生プロンプトを now.html に残さない）。
try { Invoke-Explain -HookInput $inputObj -Mode "prompt" -Policy $policy } catch { }

# それ以外は全て許可（発話は寛容・実行は guard-bash が守る）。
try {
    if ($null -ne $policy) {
        Allow-Action $inputObj "prompt" "prompt passed policy (narrow secret check only)" $prompt $policy
    }
} catch { }
exit 0
