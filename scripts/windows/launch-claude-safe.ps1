param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Prompt = "",
    # --assisted 相当: AI グレーゾーン自動承認を有効化（既定 OFF）。mac の launch-claude-safe.sh と対称。
    [switch]$Assisted,
    # 長時間おまかせモード（v1.19.9）。d-claude を launch-longrun.ps1 から起動するとき、
    # launch-integrated.ps1 → launch-deepseek-gateway.ps1 を通って渡ってくる。下の「長時間おまかせモード」を参照。
    [switch]$LongRun
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

# --- ネイティブコマンドを「標準エラーで落ちない」形で呼ぶ ---------------------------------
# Windows PowerShell 5.1 は、ネイティブコマンド (claude 等) が標準エラーへ 1 行でも出すと、
# その出力をリダイレクト (2>$null / 2>&1) やパイプで受けた時点で NativeCommandError という
# エラーレコードに変換する。$ErrorActionPreference = "Stop" の下ではそれが終了時エラーになるので、
# `claude --help` が警告を 1 行出しただけで try/catch に落ち、対応フラグの判定が空になる
# (= --permission-mode default が黙って付かなくなる)。合否は必ず .ExitCode / .Output で判定する。
function Invoke-NativeQuiet {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$Arguments = @()
    )
    $prevEap = $ErrorActionPreference
    $prevErrCount = $global:Error.Count
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $raw = @(& $File @Arguments 2>&1)
        $code = $LASTEXITCODE
        $stdout = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        $stderr = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        return [pscustomobject]@{
            ExitCode = $code
            Output   = ($stdout | Out-String)
            Error    = (($stderr | ForEach-Object { [string]$_ }) -join "`n")
        }
    } finally {
        $ErrorActionPreference = $prevEap
        while ($global:Error.Count -gt $prevErrCount) { $global:Error.RemoveAt(0) }
    }
}

# claude-safe は「普通の Claude（あなたのログイン認証）」を起動する。DeepSeek 連携(d-claude)が
# 残したルーティング系の環境変数を引き継ぐと、無効トークンを Anthropic に送って 401 になる
# (永続 setx の置き土産=footgun)。このプロセス内で消し、claude-safe を常に素の Anthropic に向ける。
# ただし d-claude (DeepSeek 駆動) は gateway 経由でこのスクリプトを呼び、DeepSeek キーと
# Gateway の BASE_URL/MODEL を「使う」ために渡してくる。その経路では gateway が
# DS_CLAUDE_MODE=1 を立てるので Remove をスキップする (消すと "not logged in" になる)。
if ($env:DS_CLAUDE_MODE -ne '1') {
    foreach ($v in @('ANTHROPIC_AUTH_TOKEN','ANTHROPIC_BASE_URL','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL','CLAUDE_CODE_SUBAGENT_MODEL','CLAUDE_CODE_EFFORT_LEVEL','ANTHROPIC_CUSTOM_MODEL_OPTION','ANTHROPIC_CUSTOM_MODEL_OPTION_NAME','ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION')) {
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
    Write-Host "「0_AIツールをまとめて入れる-Windows.bat」を実行したか、'npm install -g @anthropic-ai/claude-code@latest' を確認してください。"
    Write-Host "（場所を手動指定する場合は環境変数 CLAUDE_BIN にフルパスを設定）"
    exit 1
}

# 長時間おまかせモード（d-claude。v1.19.9 で追加・v1.20.0 で確認なしに）: 恒久的な設定ファイルは書き換えず、
# このモードの差分だけを当てた一時設定を作って渡し、終了時に消す。変換は scripts\common\longrun-claude-settings.js。
#   ・dontAsk モードで起動する（確認が要る操作は自動で断り、入力を待って止まらない。Claude Code 公式）。
#     実行されるのは「許可の規則に合うもの」と「ガード（フック）が許可したもの」だけ
#   ・d-claude（DeepSeek）は Claude Code 公式の判定役（auto モード）を使えないので、コマンドは安全パッケージの
#     AI 判定（Gemini）が見て、「通してよい」ならガードが許可する。「確認」と言ったもの・判定できなかったものは
#     ガードが止める（AI_SAFE_LONGRUN=1）
#   ・Web 取得と d-claude の補助ツールは、一時設定で許可の規則を足す（--dclaude）
#   ・全承認（bypassPermissions）は使わない。ask は deny へ寄せる。禁止の規則とガードはそのまま
#   ・Windows には壁（Claude Code の OS サンドボックス）が無いので --wall は付けない。壁が無いことの同意は
#     launch-longrun.ps1 で取ってある
#   ・作業フォルダの .claude\settings.json は直接読まず（--setting-sources から project を外す）、その中身を写した
#     一時設定（フック・禁止の規則を含む）だけを渡す（作業フォルダの ask を確認ではなく deny として効かせるため）
#   ・dontAsk が無い古い Claude Code では acceptEdits で起動する（そのときは確認が出ることがある）
$permissionMode = "default"
$settingSources = "user,project,local"
$longRunDir = $null
if ($LongRun) {
    $lrBuilder = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'common', 'longrun-claude-settings.js'))
    if (-not (Test-Path -LiteralPath $lrBuilder -PathType Leaf)) {
        throw ("長時間おまかせモードの設定づくりが見つかりません: " + $lrBuilder + "（「1_安全パッケージを最新版にする」を実行してください）")
    }
    $lrNode = Get-Command node -ErrorAction SilentlyContinue
    if (-not $lrNode) { throw "node コマンドが見つかりません（このモードの設定づくりに必要です）。" }
    $longRunDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ai-safe-longrun-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $longRunDir | Out-Null
    $lrSettings = Join-Path $longRunDir 'settings.json'
    $lrRun = Invoke-NativeQuiet -File $lrNode.Source -Arguments @($lrBuilder, $settings, $lrSettings, '--dclaude')
    if ($lrRun.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $lrSettings -PathType Leaf)) {
        Remove-Item -LiteralPath $longRunDir -Recurse -Force -ErrorAction SilentlyContinue
        throw ("このモード用の設定を作れませんでした。" + $lrRun.Error)
    }
    $settings = $lrSettings
    $permissionMode = "acceptEdits"
    $settingSources = "user,local"
    $env:AI_SAFE_LONGRUN = '1'
    # コマンドを通すかどうかは AI 判定（Gemini）が決めるので、このモードでは必ずオンにする。ふだんの d-claude では
    # AI_SAFE_ASSISTED_APPROVAL_OPTOUT=1 で外せるが、このモードでは外させない（外れていると、許可リストにない
    # コマンドがすべて断られて作業が進まない）。
    $env:AI_SAFE_ASSISTED_APPROVAL = '1'
    Write-Host '（長時間おまかせモード: 確認は出しません。危険な操作はガードが止め、グレーなコマンドは AI が判定します。終了すると一時設定は自動で消えます）'
}

$argsList = @("--settings", $settings, "--setting-sources", $settingSources)
# claude --help で --permission-mode が存在するか確認してから付ける
$helpText = ""
try {
    $helpRun = Invoke-NativeQuiet -File $Claude -Arguments @('--help')
    $helpText = ($helpRun.Output + "`n" + $helpRun.Error)
} catch { $helpText = "" }
# 長時間おまかせモード（d-claude）は、対応していれば dontAsk（確認が要る操作は自動で断る）で起動する。
if ($LongRun -and $helpText.Contains('"dontAsk"')) { $permissionMode = "dontAsk" }
if ($helpText -match "--permission-mode") {
    $argsList = @("--permission-mode", $permissionMode) + $argsList
}

# C: Claude Code の版チェック（素の claude-safe / d-claude 共通）。動作確認済みの版
# (policy の testedClaudeCodeVersion) と実版を比較し、差異があれば黙らず日本語で警告する
# （起動は止めない）。旧ポリシー（キー無し）では静かにスキップ（この照合は任意の助言）。
$expectedCcVer = $null
try {
    if ($env:AI_SAFE_POLICY -and (Test-Path -LiteralPath $env:AI_SAFE_POLICY)) {
        $polText = [System.IO.File]::ReadAllText($env:AI_SAFE_POLICY, [System.Text.Encoding]::UTF8)
        $expectedCcVer = ($polText | ConvertFrom-Json).testedClaudeCodeVersion
    }
} catch { $expectedCcVer = $null }
if ($expectedCcVer) {
    $actualCcRaw = ""
    try {
        $verRun = Invoke-NativeQuiet -File $Claude -Arguments @('--version')
        $actualCcRaw = ($verRun.Output + "`n" + $verRun.Error)
    } catch { $actualCcRaw = "" }
    $ccMatch = [regex]::Match($actualCcRaw, '[0-9]+\.[0-9]+\.[0-9]+')
    if (-not $ccMatch.Success) {
        Write-Warning ("Claude Code の版を確認できませんでした（claude --version が取得できない）。動作確認済みの版は " + $expectedCcVer + " です。")
    } elseif ($ccMatch.Value -ne $expectedCcVer) {
        Write-Warning ("Claude Code の版が動作確認済みと異なります（実際: " + $ccMatch.Value + " / 動作確認済み: " + $expectedCcVer + "）。")
        Write-Host    ("  版差で一部の安全/補助機能が黙って無効化されることがあります。揃えるには: npm install -g @anthropic-ai/claude-code@" + $expectedCcVer) -ForegroundColor Yellow
    }
}

# ★安全機能の適用は claude --help のフラグ検出に依存する。Claude Code の版が古い/新しい/
#   --help が取得できないと、正直プロンプト・MCP・権限モードが「黙って」スキップされ、
#   d-claude が“素の Claude Code + DeepSeek”に劣化する(=賢さもガードも欠ける)。これを
#   沈黙させず、その場で受講者に見える警告にする(版差による原因不明の劣化を可視化)。
if ($env:DS_CLAUDE_MODE -eq '1') {
    $missing = @()
    if (-not $helpText) { $missing += "claude --help が取得できない" }
    else {
        foreach ($f in @('--append-system-prompt','--mcp-config','--permission-mode')) {
            if ($helpText -notmatch [regex]::Escape($f)) { $missing += $f }
        }
    }
    if ($missing.Count -gt 0) {
        Write-Warning ("d-claude の一部の安全/補助機能が、この Claude Code の版では適用できません: " + ($missing -join ", "))
        Write-Host    "  → 賢さやツール(検索/画像)、deny/ask/allow が欠けることがあります。" -ForegroundColor Yellow
        Write-Host    "     Claude Code を動作確認済みの版に更新してください（診断.bat で版を確認できます）。" -ForegroundColor Yellow
    }
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
    # 画像生成は 3 系統（2026-10 の授業方針: agy が標準）:
    #   generate_image_agy=agy（標準。Google アカウント無料・日本語文字入り・参考画像を渡せる・最大 10 分待つ）/
    #   generate_image=Pollinations（無認証・文字なし向け・速い）/ generate_image_gpt=下記（ChatGPT 有料プラン向け）。
    # 切替: $env:AI_SAFE_DCLAUDE_IMAGE='0' / $env:AI_SAFE_DCLAUDE_AGY_IMAGE='0'。
    $searchMcp = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\common\gemini-search-mcp.js"))
    $imageMcp  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\common\pollinations-image-mcp.js"))
    $agyMcp    = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\common\agy-image-mcp.js"))
    # generate_image_gpt=GPT Image (Codex 経由・ChatGPT 有料プラン向け・参考画像を渡せる・最大 10 分待つ)。
    # 切替: $env:AI_SAFE_DCLAUDE_CODEX_IMAGE=0。プロンプトと参考画像はそのまま OpenAI へ送られる (Gateway は通らない)。
    $codexImgMcp = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\common\codex-image-mcp.js"))
    # vision MCP=画像→テキスト。2026-10 からは通常モデルの deepseek-flash が画像を直接見られる（Gateway も通す）ので、
    # deepseek-v4-pro（画像を見られない）に切り替えたときや、文字を正確に書き出したいときの補助。
    # 検索と同じ無料 Gemini キーを使う。無効化は $env:AI_SAFE_DCLAUDE_VISION='0'。
    # Playwright MCP=ブラウザ自動操作・UIテスト・スクレイピング。無効化は $env:AI_SAFE_DCLAUDE_PLAYWRIGHT='0'。
    $visionMcp     = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\common\gemini-vision-mcp.js"))
    $playwrightMcp = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\common\playwright-mcp.js"))
    $useSearch     = ($env:AI_SAFE_DCLAUDE_SEARCH     -ne '0') -and (Test-Path -LiteralPath $searchMcp)
    $useImage      = ($env:AI_SAFE_DCLAUDE_IMAGE      -ne '0') -and (Test-Path -LiteralPath $imageMcp)
    $useAgy        = ($env:AI_SAFE_DCLAUDE_AGY_IMAGE  -ne '0') -and (Test-Path -LiteralPath $agyMcp)
    $useCodexImg   = ($env:AI_SAFE_DCLAUDE_CODEX_IMAGE -ne '0') -and (Test-Path -LiteralPath $codexImgMcp)
    $useVision     = ($env:AI_SAFE_DCLAUDE_VISION     -ne '0') -and (Test-Path -LiteralPath $visionMcp)
    $usePlaywright = ($env:AI_SAFE_DCLAUDE_PLAYWRIGHT -ne '0') -and (Test-Path -LiteralPath $playwrightMcp)
    if (($useSearch -or $useImage -or $useAgy -or $useCodexImg -or $useVision -or $usePlaywright) -and ($helpText -match "--mcp-config")) {
        $logDir = $env:AI_SAFE_LOG_DIR
        if (-not $logDir) { $logDir = Join-Path $HOME ".ai-safety\logs" }
        try {
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            $mcpCfgPath = Join-Path $logDir "d-claude-mcp.json"
            # PS 5.1 の ConvertTo-Json は要素 1 個の配列をスカラーに潰す
            # （"args":["path.js"] → "args":"path.js"）。Claude Code の spawn は
            # args に配列を要求するので、gemini-vision を含む MCP が全部起動に失敗する。
            # 加えて Set-Content -Encoding UTF8 は BOM 付きになり、JSON パーサが拒否する。
            # node で書けば配列も BOM も正しい（mac の launch-claude-safe.sh と同じ）。
            $nodeCmd = "node"
            $nodeCmdCandidate = $env:NODE_BIN
            if (-not $nodeCmdCandidate) {
                $nodeWhich = Get-Command node -ErrorAction SilentlyContinue
                if ($nodeWhich) { $nodeCmdCandidate = [string]$nodeWhich.Source }
            }
            foreach ($c in @(
                $nodeCmdCandidate,
                $(if ($nodeCmdCandidate) { Join-Path (Split-Path -Parent $nodeCmdCandidate) "node.exe" } else { $null }),
                (Join-Path $env:ProgramFiles "nodejs\node.exe")
            )) {
                if ($c -and (Test-Path -LiteralPath $c) -and ($c -match '\.exe$')) { $nodeCmd = $c; break }
            }
            $writer = @'
const fs = require("fs");
const servers = {};
const nodeCmd = process.argv[3];
function add(name, p) { if (p && p !== "--none--") servers[name] = { command: nodeCmd, args: [p] }; }
add("gemini-search", process.argv[4]);
add("pollinations-image", process.argv[5]);
add("agy-image", process.argv[6]);
add("codex-image", process.argv[7]);
add("gemini-vision", process.argv[8]);
add("playwright", process.argv[9]);
fs.writeFileSync(process.argv[2], JSON.stringify({ mcpServers: servers }));
'@
            $writerPath = Join-Path $logDir "d-claude-mcp-write.js"
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($writerPath, $writer, $utf8NoBom)
            # PS 5.1 はネイティブコマンドへ空文字引数を渡すと省略するので、番兵を使う。
            $none = "--none--"
            $argSearch = $(if ($useSearch) { $searchMcp } else { $none })
            $argImage  = $(if ($useImage) { $imageMcp } else { $none })
            $argAgy    = $(if ($useAgy) { $agyMcp } else { $none })
            $argCodex  = $(if ($useCodexImg) { $codexImgMcp } else { $none })
            $argVision = $(if ($useVision) { $visionMcp } else { $none })
            $argPw     = $(if ($usePlaywright) { $playwrightMcp } else { $none })
            $writeOk = $false
            try {
                & $nodeCmd $writerPath $mcpCfgPath $nodeCmd $argSearch $argImage $argAgy $argCodex $argVision $argPw
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $mcpCfgPath)) { $writeOk = $true }
            } finally {
                Remove-Item -LiteralPath $writerPath -Force -ErrorAction SilentlyContinue
            }
            if ($writeOk) {
                $argsList = $argsList + @("--mcp-config", $mcpCfgPath)
                # 補助ツール（MCP）の起動待ちを長めにする。Playwright を事前に入れていない PC の
                # 最初の起動はダウンロードを待つので、既定の待ち時間だと時間切れになる（教室一斉起動・2026-10）。
                # 利用者が MCP_TIMEOUT を指定していればそれを優先する。単位はミリ秒（Claude Code 公式）。
                if (-not $env:MCP_TIMEOUT) { $env:MCP_TIMEOUT = '90000' }
            } else {
                Write-Warning "d-claude の補助ツール設定（検索/画像読取）を書けませんでした。"
            }
        } catch {
            Write-Warning ("d-claude の補助ツール設定を書けませんでした: " + $_.Exception.Message)
        }
    }
}

$claudeExit = 0
try {
    if ($Prompt -and $Prompt.Trim().Length -gt 0) {
        & $Claude @argsList $Prompt
    } else {
        & $Claude @argsList
    }
    $claudeExit = $LASTEXITCODE
} finally {
    if ($longRunDir) { Remove-Item -LiteralPath $longRunDir -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $claudeExit
