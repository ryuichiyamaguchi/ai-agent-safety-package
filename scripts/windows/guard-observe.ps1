param()

# guard-observe.ps1 — catch-all 可視化フック（案A': catch-all observe + per-tool deny）。
# mac の guard-observe.sh と対称。
#
# 役割（可視化のみ・deny 一切なし）:
#   - PreToolUse / PermissionRequest の matcher "*" から呼ばれ、あらゆる tool を受け取る。
#   - 専用 deny ガード（guard-bash / guard-write / guard-webfetch）が担当する tool
#     {Bash, PowerShell, Write, Edit, MultiEdit, WebFetch} は now.html カードを書かない
#     （専用ガードのカードが本物。observe が上書きすると解説が消えるため）。
#   - それ以外の tool（WebSearch / Read / Glob / Grep / Agent / Task / NotebookRead など、
#     および未知の tool）は、tool_name + 安全な短い入力要約のカードを now.html に書く。
#
# 安全方針（重要）:
#   - permissionDecision を「絶対に」出さない（exit 0・JSON 無し）。allow/ask/deny の判断はしない。
#   - 外部サービス（Gemini 等）へ何も送らない。ローカル now.html + 監査ログのみ。
#   - フェイルオープン: どんなエラーでも exit 0。observe はセキュリティ責務を持たないので、
#     ここでエージェントを止めてはいけない（deny ガードだけが fail-closed）。

# StrictMode は使わない（observe はフェイルオープン優先。未定義参照でも止めたくない）。
$ErrorActionPreference = "SilentlyContinue"

try {
    . (Join-Path $PSScriptRoot "lib\SafetyPolicy.ps1")
    . (Join-Path $PSScriptRoot "lib\Explainer.ps1")
    # Explainer/SafetyPolicy は StrictMode 2.0 を設定するが、observe では緩める。
    Set-StrictMode -Off
    $ErrorActionPreference = "SilentlyContinue"

    $inputObj = Read-HookInput
    $tool = ""
    try { $tool = [string](Get-ToolName $inputObj) } catch { $tool = "" }

    # 専用 deny ガードが now.html カードを所有する tool（observe はカードを書かない）。
    $covered = @("Bash", "PowerShell", "Write", "Edit", "MultiEdit", "WebFetch")
    if ($covered -contains $tool) {
        exit 0
    }

    # 可視化対象 tool: explain がカードを書く。
    $policy = $null
    try { $policy = Get-SafetyPolicy } catch { $policy = $null }
    try { Invoke-Explain -HookInput $inputObj -Mode "observe" -Policy $policy } catch { }

    # 監査 trace（best-effort）。decision="observe" は deny でも allow でもない可視化マーカー。
    try {
        if ($null -ne $policy) {
            Write-AuditLog $inputObj "observe" "observe" ("tool=" + $tool) "" $policy
        }
    } catch { }

    exit 0
} catch {
    # フェイルオープン: 何があっても agent を止めない。permissionDecision は出さない。
    exit 0
}
