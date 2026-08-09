param(
    [string]$Workspace = "$env:USERPROFILE\Documents\my-ai-workspace",
    [switch]$WebSearch,
    # 前回のセッションを開き直す（OpenCode の --continue）。
    [switch]$Resume,
    # 作業フォルダ。OpenCode は「起動したフォルダ」が作業対象になり、動き出したあとで
    # cd しても移らない (本体仕様)。プロジェクトごとに分けて作業できるよう、
    # 起動するフォルダをここで指定する。既定はワークスペース直下。
    [string]$Project = ""
)

$ErrorActionPreference = 'Stop'
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
$hooks = Join-Path $Workspace '.ai-safety\hooks'
$gatewayJs = Join-Path $hooks 'common\ds-gateway.js'
$gatewayTokenJs = Join-Path $hooks 'common\gateway-token.js'
$configJs = Join-Path $hooks 'common\opencode-config.js'
$monitorPlugin = Join-Path $hooks 'common\opencode-bouncer-monitor.mjs'
$port = if ($env:DS_GATEWAY_PORT) { $env:DS_GATEWAY_PORT } else { '8788' }
$keyDir = Join-Path $env:USERPROFILE '.deepseek-claude'
$keyFile = Join-Path $keyDir 'auth'
$logDir = if ($env:AI_SAFE_LOG_DIR) { $env:AI_SAFE_LOG_DIR } else { Join-Path $env:USERPROFILE '.ai-safety\logs' }
$coachMarker = Join-Path $logDir 'coach-engine'

if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw "作業フォルダが見つかりません: $Workspace" }

# 作業フォルダ (OpenCode を起動する場所) を決める。既定はワークスペース直下。
# ワークスペースの外は指定させない: ガードとポリシーはワークスペースを基準に配置されており、
# 外で起動すると保護が及ばない場所で AI が動くことになる。
if ($Project) {
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) { throw "指定されたフォルダが見つかりません: $Project" }
    $Project = [System.IO.Path]::GetFullPath($Project)
    $wsPrefix = $Workspace.TrimEnd('\') + '\'
    if (-not ($Project -eq $Workspace -or $Project.StartsWith($wsPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "作業フォルダはワークスペースの中だけを指定できます（fail-closed）。指定: $Project / ワークスペース: $Workspace"
    }
} else {
    $Project = $Workspace
}
if (-not (Test-Path -LiteralPath $gatewayJs -PathType Leaf)) { throw "送信検査 Gateway が見つかりません: $gatewayJs" }
if (-not (Test-Path -LiteralPath $gatewayTokenJs -PathType Leaf)) { throw "送信検査 Gateway の合言葉管理が見つかりません: $gatewayTokenJs" }
if (-not (Test-Path -LiteralPath $configJs -PathType Leaf)) { throw "OpenCode 安全設定が見つかりません: $configJs" }
if (-not (Test-Path -LiteralPath $monitorPlugin -PathType Leaf)) { throw "OpenCode承認モニターが見つかりません: $monitorPlugin" }

if ($env:AI_SAFE_DRY_RUN -eq '1') {
    Write-Output 'OpenCode + DeepSeek dry-run'
    Write-Output "  workspace: $Workspace"
    Write-Output "  project:   $Project"
    if ($env:DS_GATEWAY_PORT) {
        Write-Output "  gateway:   http://127.0.0.1:$port/v1 (mandatory)"
    } else {
        Write-Output "  gateway:   http://127.0.0.1:8788/v1 (mandatory / 使用中なら 8789-8797 から自動選択)"
    }
    Write-Output '  config:    OPENCODE_CONFIG_CONTENT'
    Write-Output '  model:     DeepSeek V4 Pro / small: V4 Flash'
    Write-Output ('  websearch: ' + $(if ($WebSearch) { 'opt-in (approval required)' } else { 'off' }))
    Write-Output ('  session:   ' + $(if ($Resume) { 'continue last' } else { 'new' }))
    exit 0
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw 'Node.js が見つかりません。' }
# 安全プラグインが壊れていると「黙って無防備」になるので、起動前に構文まで確かめる。
& $node.Source --check $monitorPlugin 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "OpenCode承認モニターが壊れているため、OpenCode は起動しません（fail-closed）。「導入(インストール)」をやり直してください: $monitorPlugin"
}
$openCode = if ($env:OPENCODE_BIN) { $env:OPENCODE_BIN } else {
    $found = Get-Command opencode -ErrorAction SilentlyContinue
    if ($found) { $found.Source } else { $null }
}
if (-not $openCode) { throw 'OpenCode が見つかりません。先に OpenCode をインストールしてください。' }
if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf) -or (Get-Item -LiteralPath $keyFile).Length -eq 0) {
    throw 'DeepSeek APIキーが未登録です。先に「DeepSeekキーを登録」を実行してください。'
}

$versionRaw = (& $openCode --version 2>$null | Select-Object -First 1)
if ($null -eq $versionRaw) { throw 'OpenCode のバージョンを取得できませんでした。OpenCode を入れ直してから、もう一度お試しください。' }
$version = ([string]$versionRaw).Trim()
if (-not $version) { throw 'OpenCode のバージョンを取得できませんでした。OpenCode を入れ直してから、もう一度お試しください。' }
& $node.Source -e 'const m=require(process.argv[1]);process.exit(m.isSupportedVersion(process.argv[2])?0:1)' $configJs $version
if ($LASTEXITCODE -ne 0) { throw "OpenCode 1.14.24 以上が必要です（検出: $version）。" }

# そのポートを握っているのが「自分たちの ds-gateway.js」かどうかを、実行中のコマンドラインで
# 確かめる。ポートに何かが応答するだけでは、それが本物の gateway とは限らないため。
# 見つからなければ 0 を返す（＝再利用しない）。
function Get-OurGatewayPid {
    param([string]$Port, [string]$GatewayJs)
    $gatewayPath = (Resolve-Path -LiteralPath $GatewayJs).Path.Replace('/', '\').ToLowerInvariant()
    try {
        $listeners = @(Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort ([int]$Port) -State Listen -ErrorAction SilentlyContinue)
    } catch { $listeners = @() }
    foreach ($listener in $listeners) {
        try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" -ErrorAction Stop } catch { continue }
        $cmd = ([string]$proc.CommandLine).Replace('/', '\').ToLowerInvariant()
        if ($cmd.Contains($gatewayPath)) { return [int]$listener.OwningProcess }
    }
    return 0
}

function Stop-StaleGateway {
    param([string]$Port, [string]$GatewayJs)
    $gatewayPath = (Resolve-Path -LiteralPath $GatewayJs).Path.Replace('/', '\').ToLowerInvariant()
    try {
        $listeners = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort ([int]$Port) -State Listen -ErrorAction SilentlyContinue
    } catch { $listeners = @() }
    foreach ($listener in @($listeners)) {
        try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" -ErrorAction Stop } catch { continue }
        $cmd = ([string]$proc.CommandLine).Replace('/', '\').ToLowerInvariant()
        if ($cmd.Contains($gatewayPath)) {
            Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 250
        }
    }
}

# 稼働中の gateway をそのまま使えるかを判定する（生きている＋中身が今と同じ）。
function Test-GatewayReusable {
    param([string]$Port, [string]$GatewayJs, [string]$GatewayTokenJs, [string]$NodePath)
    if ((Get-OurGatewayPid -Port $Port -GatewayJs $GatewayJs) -le 0) { return $false }
    & $NodePath $GatewayTokenJs '--probe' '--gateway' $GatewayJs '--port' $Port 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# 呼び出し元認証の合言葉は、この PC の共有ファイル (実キーと同じ置き場) から取る。
# 以前は起動ごとに採番して、動いている gateway を必ず停止して立て直していた。その方式だと
# OpenCode を 2 枚開いたり d-claude と併用したりすると、後発が先発の gateway を殺すため、
# 先に開いていた窓だけが古い合言葉のまま取り残されて全リクエストが 401 になっていた。
# コマンドライン引数には載せない (プロセス一覧に出るため)。標準出力で受け取る。
$gatewayToken = (& $node.Source $gatewayTokenJs '--ensure' '--gateway' $gatewayJs | Out-String).Trim()
if (-not $gatewayToken) { throw '送信検査 Gateway の合言葉を用意できませんでした (fail-closed)。' }

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$gatewayOut = Join-Path $logDir 'opencode-deepseek-gateway.log'
$gatewayErr = Join-Path $logDir 'opencode-deepseek-gateway.err.log'

# 使うポートを決める。DS_GATEWAY_PORT で明示指定されたときはその 1 つだけを使い (利用者の
# 意図を尊重し、黙って別のポートへ逃げない)、未指定なら既定 8788 から順に空きを探す。
# 8788 が他のプログラム (別プロジェクトの常駐サービス等) に取られている PC があり、
# 決め打ちのままだと「Gateway を確認できない」で起動そのものができなくなるため。
if ($env:DS_GATEWAY_PORT) { $portCandidates = @($env:DS_GATEWAY_PORT) } else { $portCandidates = @(8788..8797) }

# 既に動いている gateway が「自分たちのプロセス」かつ「中身が今と同じ」なら、そのまま使う。
# どのポートで動いているかは gateway 自身が合言葉ファイルへ記録しているのでそれを見る。
$gw = $null
$gatewayReused = $false
$port = $null
$recordedPort = (& $node.Source $gatewayTokenJs '--recorded-port' | Out-String).Trim()
if ($recordedPort -and (Test-GatewayReusable -Port $recordedPort -GatewayJs $gatewayJs -GatewayTokenJs $gatewayTokenJs -NodePath $node.Source)) {
    $port = $recordedPort
    $gatewayReused = $true
}

# 再利用できないときは、候補ポートを順に試して自分で立てる。
# ポートを他に取られていれば gateway は即座に終了するので、次の候補へ進む。
if (-not $gatewayReused) {
    foreach ($candidate in $portCandidates) {
        # 自分たちの gateway が中身違い (更新後に古いものが居座っている) で居るなら止める。
        Stop-StaleGateway -Port $candidate -GatewayJs $gatewayJs
        $env:DS_GATEWAY_PORT = $candidate
        $env:DS_GATEWAY_UPSTREAM = 'https://api.deepseek.com'
        $env:DS_GATEWAY_AUTH_FILE = $keyFile
        $env:DS_GATEWAY_TOKEN = $gatewayToken
        $env:DS_GATEWAY_WORKSPACE = $Workspace
        $gw = Start-Process -FilePath $node.Source -ArgumentList @($gatewayJs) -PassThru -WindowStyle Hidden -RedirectStandardOutput $gatewayOut -RedirectStandardError $gatewayErr
        Remove-Item Env:\DS_GATEWAY_AUTH_FILE, Env:\DS_GATEWAY_UPSTREAM, Env:\DS_GATEWAY_TOKEN, Env:\DS_GATEWAY_WORKSPACE -ErrorAction SilentlyContinue

        # healthz の応答だけで判断してはいけない。ポートが他に取られていた場合、自分の gateway は
        # bind に失敗して終了するが、その同じポートで「別の gateway」(例: 別ワークスペースから
        # 起動されたもの) が動いていると healthz は正常に応答する。それを自分のものと取り違えると、
        # 別の検査設定を通って通信することになる。
        # 確実なのは gateway 自身が listen 直後に出す 1 行の照合:
        #   listening on 127.0.0.1:<port> pid=<pid>
        # ここの pid は自分が起動した node のプロセス ID そのもの。
        $ready = $false
        $listenMark = "listening on 127.0.0.1:$candidate pid=$($gw.Id)"
        for ($i = 0; $i -lt 50; $i++) {
            if ($gw -and $gw.HasExited) { break }
            $listened = $false
            try {
                foreach ($line in @(Get-Content -LiteralPath $gatewayOut -ErrorAction Stop)) {
                    if ([string]$line -eq '') { continue }
                    if (([string]$line).StartsWith($listenMark)) { $listened = $true; break }
                }
            } catch {}
            if ($listened) {
                try {
                    $health = Invoke-WebRequest -Uri "http://127.0.0.1:$candidate/healthz" -UseBasicParsing -TimeoutSec 1
                    if ($health.Content -match '"status":"ok"') { $ready = $true }
                } catch {}
                break
            }
            Start-Sleep -Milliseconds 100
        }
        if ($ready -and $gw -and -not $gw.HasExited) { $port = $candidate; break }

        # 窓を二つ同時に開いてポートを取り合い、こちらが負けた可能性がある。
        # 相手が正しい gateway なら、それをそのまま使って続行する。
        if (Test-GatewayReusable -Port $candidate -GatewayJs $gatewayJs -GatewayTokenJs $gatewayTokenJs -NodePath $node.Source) {
            if ($gw -and -not $gw.HasExited) { Stop-Process -Id $gw.Id -Force -ErrorAction SilentlyContinue }
            $gw = $null
            $port = $candidate
            $gatewayReused = $true
            break
        }
        if ($gw -and -not $gw.HasExited) { Stop-Process -Id $gw.Id -Force -ErrorAction SilentlyContinue }
        $gw = $null
    }
}

try {
    if (-not $port) {
        # 原因の実物 (EADDRINUSE 等) を画面にも出す。ログを開かないと分からない状態にしない。
        $hint = ''
        try {
            $lastLines = @(Get-Content -LiteralPath $gatewayOut -Tail 3 -ErrorAction Stop)
            if ($lastLines.Count -gt 0) { $hint = " Gateway が出したメッセージ: " + ($lastLines -join ' / ') + "." }
        } catch {}
        if ($env:DS_GATEWAY_PORT) {
            throw "送信検査 Gateway を起動できないため、OpenCode は起動しません（fail-closed）。指定されたポート $($env:DS_GATEWAY_PORT) を他のプログラムが使っている可能性があります。$hint 確認先: $gatewayErr"
        }
        throw "送信検査 Gateway を起動できないため、OpenCode は起動しません（fail-closed）。ポート 8788〜8797 をすべて他のプログラムが使っている可能性があります。$hint 確認先: $gatewayErr"
    }
    # そのポートを握っているのが自分たちの gateway であることを最後に確かめる。
    # 自分で立てた場合は子プロセスの生存で足りる (他プロセスが占有していれば bind 失敗で即終了)。
    if ($gatewayReused -and (Get-OurGatewayPid -Port $port -GatewayJs $gatewayJs) -le 0) {
        throw "送信検査 Gateway を確認できないため、OpenCode は起動しません（fail-closed）。確認先: $gatewayErr"
    }
    if ($gatewayReused) {
        Write-Host "稼働中の送信検査 Gateway をそのまま使います (127.0.0.1:$port)。"
    } elseif ("$port" -ne '8788') {
        Write-Host "ポート 8788 は他のプログラムが使っていたため、送信検査 Gateway は 127.0.0.1:$port で動かします。"
    }

    # 実キーは Gateway 子プロセスだけが読み、OpenCode の環境には渡さない。
    # 一覧は opencode-config.js が持つ (Mac 版と 1 か所で共有するため)。ここで先に消すのは、
    # 消す前に設定を作ると「鍵があるので MCP を登録したのに、その鍵が MCP へ届かない」状態に
    # なるため。検索・画像読取は %USERPROFILE%\.ai-safety\gemini-api-key.txt
    # (「6_AIコーチのキーを登録」が書く場所) だけを見る。
    $secretEnvRaw = (& $node.Source $configJs '--print-secret-env')
    if ($LASTEXITCODE -ne 0 -or -not $secretEnvRaw) { throw 'OpenCode 安全設定を生成できませんでした。' }
    $secretEnvNames = @(([string]$secretEnvRaw).Trim() -split '\s+' | Where-Object { $_ })
    $coachKeyFile = Join-Path $env:USERPROFILE '.ai-safety\gemini-api-key.txt'
    if (($env:GEMINI_API_KEY -or $env:GOOGLE_API_KEY) -and -not (Test-Path -LiteralPath $coachKeyFile -PathType Leaf)) {
        Write-Warning '環境変数の Gemini キーは OpenCode へ渡しません (AI から見えてしまうため)。検索と画像読み取りを使うときは「6_AIコーチのキーを登録」で登録してください。'
    }
    foreach ($secretName in $secretEnvNames) {
        Remove-Item -LiteralPath "Env:\$secretName" -ErrorAction SilentlyContinue
    }
    # deny 床そのものを決めるポリシーの置き場を、環境変数で差し替えられないようにする。
    # 無害な正規表現だけのポリシーを指されると、決定的 deny 床が丸ごと消える。
    Remove-Item Env:\AI_SAFE_POLICY, Env:\AI_SAFE_ROOT -ErrorAction SilentlyContinue

    # プロジェクト固有の設定は無効化し、隔離した設定ディレクトリからBouncerプラグインだけを読む。
    $env:OPENCODE_DISABLE_PROJECT_CONFIG = '1'
    Remove-Item Env:\OPENCODE_PURE -ErrorAction SilentlyContinue
    # 強制設定を後から丸ごと無効化できる環境変数を先に消す。
    # OPENCODE_PERMISSION と OPENCODE_TEST_MANAGED_CONFIG_DIR は OPENCODE_CONFIG_CONTENT より
    # 後にマージされるため、外から仕込まれていると deny 床がそのまま外れる（1.18.4 実測）。
    Remove-Item Env:\OPENCODE_PERMISSION, Env:\OPENCODE_CONFIG, Env:\OPENCODE_CONFIG_DIR, Env:\OPENCODE_TEST_MANAGED_CONFIG_DIR -ErrorAction SilentlyContinue
    $env:XDG_CONFIG_HOME = Join-Path $Workspace '.ai-safety\opencode-runtime\xdg-config'
    $env:AI_SAFE_LOG_DIR = $logDir
    New-Item -ItemType Directory -Force -Path $env:XDG_CONFIG_HOME | Out-Null

    # --- 日本語ハーネスの配置 -------------------------------------------------
    # OPENCODE_DISABLE_PROJECT_CONFIG=1 では作業フォルダの .opencode\ は一切読まれず、
    # 作業フォルダ側 AGENTS.md の探索も止まる。一方、設定ディレクトリ直下の AGENTS.md は
    # instructions の指定と関係なく無条件で読み込まれる (1.18.4 実測)。そこで
    # 「隔離設定ディレクトリ側」にパッケージ同梱のハーネス一式を毎回置き直す。
    #   - AGENTS.md         … 日本語の指示書本体 (設定ディレクトリ直下 = 無条件で読まれる)
    #   - command(s)\*.md   … 日本語スラッシュコマンド (1.18.4 は単数・複数どちらも読む)
    #   - agents\*.md       … 追加エージェント (読み取り専用「せんせい」等)
    #   - skills\<名前>\    … 配布スキル (hearing-ladder 等)
    # 同梱物の名前を決め打ちせず、配布元にある物をそのまま写す (将来 1 本増えても配線不要)。
    # 毎回置き直すので、ここを書き換えられてもパッケージ側の内容が必ず勝つ。
    # 中身が無いときは警告だけ出して続行する (保護には影響しないため止めない)。
    $ocConfigDir = Join-Path $env:XDG_CONFIG_HOME 'opencode'
    $harnessSrc = Join-Path $Workspace '.ai-safety\opencode-harness'
    $skillsSrc = Join-Path $Workspace '.ai-safety\dist-skills'
    # 消す前に「本当に自分が作った隔離設定ディレクトリか」を完全一致で確かめる。
    # 前方一致だけで済ませると、環境変数の細工で受講者の作業フォルダを消しかねない。
    $expectedConfigDir = Join-Path $Workspace '.ai-safety\opencode-runtime\xdg-config\opencode'
    if (-not $ocConfigDir.Equals($expectedConfigDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '設定ディレクトリの場所が想定外のため、OpenCode は起動しません (fail-closed)。'
    }
    New-Item -ItemType Directory -Force -Path $ocConfigDir | Out-Null

    # --- OpenCode が読む場所を毎回まっさらにする -------------------------------------
    # 「配布物にある名前だけ置き直す」方式だと、配布物に無い綴り (単数形の agent\ command\、
    # mode\、skill\、themes\) へ仕込まれた定義が次の起動でも生き残る (1.18.4 のバイナリ実測:
    # {agent,agents}/**/*.md ・ {command,commands}/**/*.md ・ {mode,modes}/*.md ・
    # {plugin,plugins}/*.{ts,js} ・ skill\ と skills\ ・ themes\*.json を読む)。読む場所を
    # 先に消してから配布物を置き直せば、綴りの取りこぼしが構造的に起きない。
    # 消すのは上で場所を完全一致で確かめた隔離設定ディレクトリの中だけ。node_modules /
    # package.json / bun.lock は OpenCode がプラグインの依存を入れる場所なので残す
    # (毎回消すと起動のたびにダウンロードが走り、教室の PC では実用にならない)。
    foreach ($known in @('agent', 'agents', 'command', 'commands', 'mode', 'modes', 'plugin', 'plugins', 'skill', 'skills', 'themes')) {
        $knownPath = Join-Path $ocConfigDir $known
        if (Test-Path -LiteralPath $knownPath) { Remove-Item -LiteralPath $knownPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # config.json も消す (1.18.4 実測: 設定ディレクトリ直下の config.json も設定として読む。
    # opencode.json5 / .opencoderc / config.jsonc は読まないので、増やすのはこの 1 本だけ)。
    foreach ($knownFile in @('AGENTS.md', 'opencode.json', 'opencode.jsonc', 'config.json')) {
        $knownFilePath = Join-Path $ocConfigDir $knownFile
        if (Test-Path -LiteralPath $knownFilePath) { Remove-Item -LiteralPath $knownFilePath -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path -LiteralPath $harnessSrc -PathType Container) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $harnessSrc -Force -ErrorAction SilentlyContinue)) {
            # plugin\ だけは写さない。設定ディレクトリの plugin は無条件で実行されるので、
            # 動くコードは「ランチャーが明示的に渡す Bouncer 監視プラグイン 1 本」に限る。
            if ($entry.Name -in @('plugin', 'plugins')) {
                Write-Warning "配布物の $($entry.Name) は安全のため配置しません。"
                continue
            }
            $entryDest = Join-Path $ocConfigDir $entry.Name
            if ($entry.PSIsContainer) {
                if (Test-Path -LiteralPath $entryDest) { Remove-Item -LiteralPath $entryDest -Recurse -Force }
                Copy-Item -LiteralPath $entry.FullName -Destination $entryDest -Recurse -Force
            } else {
                Copy-Item -LiteralPath $entry.FullName -Destination $entryDest -Force
            }
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ocConfigDir 'AGENTS.md') -PathType Leaf)) {
        Write-Warning "日本語の指示書が見つからないため配置をとばしました: $(Join-Path $harnessSrc 'AGENTS.md')"
    }

    if (Test-Path -LiteralPath $skillsSrc -PathType Container) {
        $skillsDest = Join-Path $ocConfigDir 'skills'
        New-Item -ItemType Directory -Force -Path $skillsDest | Out-Null
        foreach ($skill in @(Get-ChildItem -LiteralPath $skillsSrc -Directory -Force -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path -LiteralPath (Join-Path $skill.FullName 'SKILL.md') -PathType Leaf)) { continue }
            $skillDest = Join-Path $skillsDest $skill.Name
            if (Test-Path -LiteralPath $skillDest) { Remove-Item -LiteralPath $skillDest -Recurse -Force }
            Copy-Item -LiteralPath $skill.FullName -Destination $skillDest -Recurse -Force
        }
    } else {
        Write-Warning "配布スキルが見つからないため配置をとばしました: $skillsSrc"
    }

    # --- 設定ディレクトリのショートカット (シンボリックリンク) を禁じる ---------------
    # opencode 1.18.4 は command / agent / mode を symlink:true で走査する = リンクの先に
    # ある .md も読む。リンクを 1 本置かれるだけで「配置し直した安全なファイルを見ている
    # つもりが、まったく別の場所のファイルを読ませられる」形になる。ただし node_modules は
    # OpenCode が管理する依存キャッシュで、.bin に通常のリンクが作られる。実ディレクトリの
    # node_modules の中だけは走査せず、node_modules 自体がリンクなら検査対象に残す。
    $configScanEntries = @()
    foreach ($entry in @(Get-ChildItem -LiteralPath $ocConfigDir -Force -ErrorAction SilentlyContinue)) {
        $isReparsePoint = (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
        if ($entry.Name -eq 'node_modules' -and $entry.PSIsContainer -and -not $isReparsePoint) { continue }
        $configScanEntries += $entry
        if ($entry.PSIsContainer -and -not $isReparsePoint) {
            $configScanEntries += @(Get-ChildItem -LiteralPath $entry.FullName -Recurse -Force -ErrorAction SilentlyContinue)
        }
    }
    $linkHits = @($configScanEntries |
        Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint })
    if ($linkHits.Count -gt 0) {
        foreach ($hit in $linkHits) { Write-Warning "対象: $($hit.FullName)" }
        throw '設定フォルダにショートカット (シンボリックリンク) が置かれていたため、OpenCode は起動しません (fail-closed)。「導入(インストール)」をやり直してください。それでも出る場合は講師に連絡してください。'
    }

    # --- スラッシュコマンドの中の「シェル実行」を禁じる (fail-closed) ---------------
    # コマンド .md の本文に書かれた !`コマンド` は、テンプレート展開時に受講者のシェルへ
    # そのまま渡されて実行される (1.18.4 のバイナリ内 /!`([^`]+)`/g → shell 実行を確認)。
    # これはツール呼び出しを経ないので permission の確認も、承認モニターの決定的 deny 床も
    # 通らない = 安全機構を丸ごと迂回する任意コード実行になる。配布物にこの書き方は無いので、
    # 「配置後の実ファイル」を見て 1 つでもあれば起動しない (配置後の書き換えも拾う)。
    # 走査は OpenCode 自身の依存キャッシュ node_modules を除く設定ディレクトリ全体にかける。
    # node_modules の JavaScript には通常のテンプレートリテラル末尾として !` が現れるため、
    # コマンド定義と同じ検査をすると誤検出になる。opencode が読むのは command(s) / agent(s) /
    # mode(s) だが、フォルダ名を並べて数え上げる書き方は取りこぼす (mode を書き忘れる、
    # 大文字の Commands を見落とす、といった形)。配布物のどのファイルにもこの書き方は
    # 無いので、依存キャッシュ以外を全部見て 1 件でもあれば止める。読めなかったファイルも同じ扱い。
    $shellExpansionHits = @()
    foreach ($definitionFile in @($configScanEntries | Where-Object { -not $_.PSIsContainer })) {
        try {
            $body = [System.IO.File]::ReadAllText($definitionFile.FullName)
        } catch {
            $shellExpansionHits += $definitionFile.FullName
            continue
        }
        if ($body.Contains('!' + [char]96)) { $shellExpansionHits += $definitionFile.FullName }
    }
    if ($shellExpansionHits.Count -gt 0) {
        foreach ($hit in $shellExpansionHits) { Write-Warning "対象: $hit" }
        throw 'コマンド定義に「確認なしでコマンドを実行する書き方」が含まれていたため、OpenCode は起動しません (fail-closed)。「導入(インストール)」をやり直してください。それでも出る場合は講師に連絡してください。'
    }

    $configArgs = @($configJs, '--port', $port, '--monitor-plugin', $monitorPlugin)
    if ($WebSearch) {
        $env:OPENCODE_ENABLE_EXA = '1'
        $configArgs += '--websearch'
        Write-Host 'Web検索を有効にしました。検索語は外部サービスへ送信され、実行前に確認が出ます。'
    } else {
        Remove-Item Env:\OPENCODE_ENABLE_EXA -ErrorAction SilentlyContinue
    }
    # 合言葉は provider の apiKey として設定に埋め込む (gateway 側で照合される)。
    # opencode-config.js へは環境変数で渡し、生成直後に消す (引数にすると ps に出る)。
    $env:DS_GATEWAY_TOKEN = $gatewayToken
    try {
        $env:OPENCODE_CONFIG_CONTENT = (& $node.Source @configArgs)
    } finally {
        Remove-Item Env:\DS_GATEWAY_TOKEN -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0 -or -not $env:OPENCODE_CONFIG_CONTENT) { throw 'OpenCode 安全設定を生成できませんでした。' }

    # 消すだけでなく「安全な値で上書き」して二重化する。環境変数側が最後にマージされるので、
    # 将来マージ順が変わっても最小限の deny 床（削除・昇格・公開・外部通信・外部フォルダ）は残る。
    $enforced = (& $node.Source $configJs '--print-permission-env')
    if ($LASTEXITCODE -ne 0 -or -not $enforced) { throw 'OpenCode 安全設定を生成できませんでした。' }
    $env:OPENCODE_PERMISSION = $enforced


    $watchdog = $null
    $resolvedFile = Join-Path $logDir 'opencode-resolved-config.json'
    $failedResolvedFile = Join-Path $logDir 'opencode-resolved-config.failed.txt'
    # OpenCode は「起動したフォルダ」が作業対象になる。指定されたフォルダへ移ってから起動する。
    Push-Location $Project
    try {
        # --- 本体を出す前に「安全プラグインが本当に載るか」を実物で確かめる -----------
        # `opencode debug config` はプラグインを実際に読み込む (1.18.4 実測: プラグインの
        # 中でファイルを書かせて確認)。そこでこれを本体より先に 1 回だけ同期実行し、
        #   (1) 解決済み設定で deny 床が生きているか
        #   (2) プラグインが ready マーカーを書いたか (= 決定的 deny 床が載ったか)
        # の両方を確かめてから本体を起動する。以前はどちらも「起動してから 30 秒後に
        # 気づく」形だったため、無防備な OpenCode がそのまま動き続けていた。
        # 検証結果はファイル経由で渡す（PowerShell 5.1 はネイティブコマンドの標準入力を
        # 既定 ASCII で流すため、日本語ユーザー名などが混ざると壊れて誤検知になる）。
        $readyMarker = Join-Path $logDir 'opencode-monitor-ready.json'
        Remove-Item -LiteralPath $readyMarker -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $failedResolvedFile -Force -ErrorAction SilentlyContinue
        $epoch = New-Object System.DateTime(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        $probeSince = [string][long]([System.DateTime]::UtcNow - $epoch).TotalMilliseconds

        $resolved = (& $openCode debug config 2>$null | Out-String)
        if (-not $resolved -or -not $resolved.Trim()) {
            throw '安全設定を確認できないため、OpenCode は起動しません（fail-closed）。OpenCode が古い可能性があります。最新版に更新してから、もう一度お試しください。'
        }
        # 解決済み設定には provider の apiKey (= gateway の合言葉) が含まれる。検証は
        # permission / share / agent しか見ないので、ディスクへ書く前に伏せる。
        $resolvedSafe = $resolved.Replace($gatewayToken, 'REDACTED')
        [System.IO.File]::WriteAllText($resolvedFile, $resolvedSafe, (New-Object System.Text.UTF8Encoding($false)))
        & $node.Source $configJs '--verify-resolved' $resolvedFile
        $verified = ($LASTEXITCODE -eq 0)
        if (-not $verified) {
            Move-Item -LiteralPath $resolvedFile -Destination $failedResolvedFile -Force -ErrorAction SilentlyContinue
            Write-Warning ("診断ファイル: " + $failedResolvedFile)
            throw '安全設定が有効になっていないため、OpenCode は起動しません（fail-closed）。診断ファイルを講師へ共有してください（Gatewayの合言葉は伏せてあります）。'
        }
        Remove-Item -LiteralPath $resolvedFile -Force -ErrorAction SilentlyContinue

        # 終了コードだけでなく合図の 1 行も要求する。何かの理由で検査そのものが走らなかった
        # とき、「黙って 0 で終わった」を「確認できた」と取り違えないため。
        $readySignal = (& $node.Source $monitorPlugin '--verify-ready' '--not-before' $probeSince | Out-String)
        if ($LASTEXITCODE -ne 0 -or -not $readySignal.Contains('BOUNCER_READY_OK')) {
            throw '危険なコマンドを止める安全プラグインが読み込まれないため、OpenCode は起動しません（fail-closed）。「導入(インストール)」をやり直してから、もう一度お試しください。'
        }

        # 見張り: 本体のセッションでもプラグインが読み込まれたかを ready マーカーで確かめ、
        # 読み込まれていなければ監視画面の履歴に警告を残す（TUI は全画面なので画面出力では気づけない）。
        # 上の確認で書かれたマーカーを消してから始めるので、今回のセッション分だけを見る。
        Remove-Item -LiteralPath $readyMarker -Force -ErrorAction SilentlyContinue
        $watchdog = Start-Process -FilePath $node.Source -ArgumentList @($monitorPlugin, '--watchdog', '--timeout-ms', '30000') -PassThru -WindowStyle Hidden

        Set-Content -NoNewline -Encoding ascii -LiteralPath $coachMarker -Value 'opencode-deepseek'
        Write-Host 'Bouncer送信検査: 有効 / モデル: DeepSeek V4 Pro / 補助: V4 Flash'
        Write-Host ('変更操作は確認、外部フォルダは禁止、Web検索は' + $(if ($WebSearch) { '許可時のみ' } else { '無効' }) + 'です。')
        Write-Host '危険なコマンド（まとめて削除・鍵の読み出し・ネットから拾った実行）は確認なしで止まります。'

        # -Resume のときは前回のセッションを開き直す。会話は OpenCode 自身がローカルに
        # 保存しているので、前の窓が落ちても続きから戻れる。
        if ($Resume) {
            Write-Host '前回の続きから開きます（新しく始めるときは「続きから」ではないボタンを使ってください）。'
            & $openCode '--continue'
        } else {
            & $openCode
        }
    } finally {
        Pop-Location
        if ($watchdog -and -not $watchdog.HasExited) { Stop-Process -Id $watchdog.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $resolvedFile -Force -ErrorAction SilentlyContinue
    }
    exit $LASTEXITCODE
} finally {
    if ($gw -and -not $gw.HasExited) { Stop-Process -Id $gw.Id -Force -ErrorAction SilentlyContinue }
    # coach マーカーは d-claude と OpenCode が同じパスを共有する。並行起動時に片方の終了で
    # もう片方のバナーが消えないよう、「自分が書いた値のままのときだけ」消す。
    try {
        if ((Get-Content -LiteralPath $coachMarker -Raw -ErrorAction Stop).Trim() -eq 'opencode-deepseek') {
            Remove-Item -LiteralPath $coachMarker -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    Remove-Item Env:\OPENCODE_CONFIG_CONTENT, Env:\OPENCODE_ENABLE_EXA, Env:\OPENCODE_DISABLE_PROJECT_CONFIG, Env:\OPENCODE_PURE, Env:\XDG_CONFIG_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:\OPENCODE_PERMISSION, Env:\DS_GATEWAY_PORT -ErrorAction SilentlyContinue
}
