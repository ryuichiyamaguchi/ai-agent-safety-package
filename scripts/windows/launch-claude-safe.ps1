param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = "",
    # --assisted 相当: 2 鍵グレーゾーン自動承認を有効化（既定 OFF）。mac の launch-claude-safe.sh と対称。
    [switch]$Assisted
)

# 事前に AI_SAFE_ASSISTED_APPROVAL=1 が立っていればそのまま尊重し、-Assisted 指定時は立てる。
# どちらでもない場合は OFF（環境変数を変更しない＝今日と同じ挙動）。
if ($Assisted) { $env:AI_SAFE_ASSISTED_APPROVAL = "1" }

# M13: Claude Code の approval 制御は CLI フラグでは渡せない（Codex の
# --ask-for-approval untrusted に相当する仕組みは settings.json 側にある）。
# 本パッケージは configs\claude\settings.windows.json の permissions / hooks 経由で
# 同等の効果（PreToolUse hook による fail-closed 判定 + 危険コマンド deny）を出している。
# 追加の保険として --permission-mode default を渡し、Claude Code 側のデフォルト
# 承認モードを明示する。古い CLI でフラグ非対応の場合はフォールバックする。
$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$settings = Join-Path $Workspace ".claude\settings.json"
$env:AI_SAFE_ROOT = Join-Path $Workspace ".ai-safety"
$env:AI_SAFE_POLICY = Join-Path $env:AI_SAFE_ROOT "policy\safety-policy.json"
$env:AI_SAFE_LOG_DIR = Join-Path $HOME ".ai-safety\logs"

# claude-safe は「普通の Claude（あなたのログイン認証）」を起動する。DeepSeek 連携(d-claude)が
# 残したルーティング系の環境変数を引き継ぐと、無効トークンを Anthropic に送って 401 になる
# (永続 setx の置き土産=footgun)。このプロセス内で消し、claude-safe を常に素の Anthropic に向ける。
# ただし d-claude (DeepSeek 駆動) は gateway 経由でこのスクリプトを呼び、DeepSeek キーと
# Gateway の BASE_URL/MODEL を「使う」ために渡してくる。その経路では gateway が
# DS_CLAUDE_MODE=1 を立てるので Remove をスキップする (消すと "not logged in" になる)。
if ($env:DS_CLAUDE_MODE -ne '1') {
    foreach ($v in @('ANTHROPIC_AUTH_TOKEN','ANTHROPIC_BASE_URL','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL','ANTHROPIC_CUSTOM_MODEL_OPTION')) {
        if (Test-Path "Env:\$v") { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
    }
}

if (-not (Test-Path -LiteralPath $settings)) {
    throw "Claude safety settings were not found: $settings"
}
if (-not (Test-Path -LiteralPath $env:AI_SAFE_POLICY)) {
    throw "AI Safety package is not installed in workspace: $Workspace"
}

# claude バイナリ検出（PATH に無くても npm グローバル / native installer から見つける）。
# npm install -g @anthropic-ai/claude-code は Windows で %APPDATA%\npm\claude.cmd に入る。
$Claude = $env:CLAUDE_BIN
if (-not $Claude) {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) { $Claude = $cmd.Source }
}
if (-not $Claude) {
    foreach ($c in @(
        (Join-Path $env:APPDATA "npm\claude.cmd"),
        (Join-Path $env:APPDATA "npm\claude"),
        (Join-Path $env:USERPROFILE ".local\bin\claude.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\claude")
    )) { if ($c -and (Test-Path -LiteralPath $c)) { $Claude = $c; break } }
}
if (-not $Claude) {
    Write-Host "claude コマンドが見つかりません。"
    Write-Host "「0_AIツールをまとめて入れる-Windows.bat」を実行したか、'npm install -g @anthropic-ai/claude-code' を確認してください。"
    Write-Host "（場所を手動指定する場合は環境変数 CLAUDE_BIN にフルパスを設定）"
    exit 1
}

$argsList = @("--settings", $settings, "--setting-sources", "user,project,local")
# claude --help で --permission-mode が存在するか確認してから付ける
$helpText = ""
try { $helpText = (& $Claude --help 2>&1 | Out-String) } catch { $helpText = "" }
if ($helpText -match "--permission-mode") {
    $argsList = @("--permission-mode", "default") + $argsList
}

# d-claude (DeepSeek 駆動) のときだけ、正直さ・身元の上書き指示を system prompt に追記する。
# DeepSeek は Claude Code の「あなたは Claude」プロンプトで Anthropic を装い、できないことを
# 「できる」・やっていないことを「やった」と過剰申告する傾向がある。--append-system-prompt で
# 「実際は DeepSeek」「嘘・捏造をしない」を注入して是正する。フラグ非対応の古い CLI では skip。
# ファイルは UTF-8 で読む (PS5.1 の既定 CP932 誤読で日本語が化けるのを防ぐ)。素の claude-safe には影響しない。
if ($env:DS_CLAUDE_MODE -eq '1') {
    $honestyFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\common\deepseek-honesty-prompt.txt"))
    if ((Test-Path -LiteralPath $honestyFile) -and ($helpText -match "--append-system-prompt")) {
        $honestyText = [System.IO.File]::ReadAllText($honestyFile, [System.Text.Encoding]::UTF8)
        # Windows では claude が npm の .cmd シム (cmd.exe 層) 経由で起動されるため、引数内の
        # 改行や ASCII 二重引用符でコマンドラインが崩れ、テキスト後半が位置引数
        # (=初回ユーザープロンプト) になる実機事故が起きる。改行を空白に畳み " を ' に
        # 置換して 1 行で渡す (mac は execve 直渡しで崩れないため無加工のまま)。
        $honestyText = (($honestyText -replace '"', "'") -replace "\s*\r?\n\s*", " ").Trim()
        $argsList = $argsList + @("--append-system-prompt", $honestyText)
    }

    # d-claude に web 検索を与える（Gemini grounding の MCP ツール web_search）。標準 WebSearch は
    # Anthropic サーバー側実装で DeepSeek バックエンドでは動かないため、検索のみの自前 MCP を追加する。
    # 既存の Gemini キーを使い回すので受講者は新規アカウント不要。d-claude 限定で --mcp-config 追加。
    # 無効化は $env:AI_SAFE_DCLAUDE_SEARCH='0'。JSON はエスケープ事故回避のため ConvertTo-Json で生成。
    # d-claude に「簡単な画像生成」も与える（Pollinations の MCP ツール generate_image）。
    # 無料で画像を作れるのは受講者環境では実質 Pollinations のみ（codex 無料枠=usage limit /
    # Gemini 無料 API=画像モデル limit:0）。API キー不要・無登録。無効化は $env:AI_SAFE_DCLAUDE_IMAGE='0'。
    # 検索 MCP と画像 MCP を 1 つの --mcp-config JSON に束ねて渡す（有効なものだけ載せる）。
    # 画像は 2 系統: generate_image=Pollinations（無認証・文字なし向け・速い）/
    # generate_image_agy=agy（Google アカウント無料・日本語文字入り/高品質・1枚20秒前後）。
    # 切替: $env:AI_SAFE_DCLAUDE_IMAGE='0' / $env:AI_SAFE_DCLAUDE_AGY_IMAGE='0'。
    $searchMcp = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\common\gemini-search-mcp.js"))
    $imageMcp  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\common\pollinations-image-mcp.js"))
    $agyMcp    = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\common\agy-image-mcp.js"))
    $useSearch = ($env:AI_SAFE_DCLAUDE_SEARCH -ne '0') -and (Test-Path -LiteralPath $searchMcp)
    $useImage  = ($env:AI_SAFE_DCLAUDE_IMAGE  -ne '0') -and (Test-Path -LiteralPath $imageMcp)
    $useAgy    = ($env:AI_SAFE_DCLAUDE_AGY_IMAGE -ne '0') -and (Test-Path -LiteralPath $agyMcp)
    if (($useSearch -or $useImage -or $useAgy) -and ($helpText -match "--mcp-config")) {
        $logDir = $env:AI_SAFE_LOG_DIR
        if (-not $logDir) { $logDir = Join-Path $HOME ".ai-safety\logs" }
        try {
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            $mcpCfgPath = Join-Path $logDir "d-claude-mcp.json"
            $servers = @{}
            if ($useSearch) { $servers["gemini-search"]      = @{ command = "node"; args = @($searchMcp) } }
            if ($useImage)  { $servers["pollinations-image"] = @{ command = "node"; args = @($imageMcp) } }
            if ($useAgy)    { $servers["agy-image"]          = @{ command = "node"; args = @($agyMcp) } }
            $mcpObj = @{ mcpServers = $servers }
            ($mcpObj | ConvertTo-Json -Depth 6 -Compress) | Set-Content -LiteralPath $mcpCfgPath -Encoding UTF8
            $argsList = $argsList + @("--mcp-config", $mcpCfgPath)
        } catch { }
    }
}

if ($Prompt -and $Prompt.Trim().Length -gt 0) {
    & $Claude @argsList $Prompt
} else {
    & $Claude @argsList
}
exit $LASTEXITCODE
