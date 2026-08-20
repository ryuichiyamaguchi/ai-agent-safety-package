param(
    [ValidateSet('mac','win','both')]
    [string]$Platform = 'win',
    [string]$Workspace = '',
    [switch]$InstallGlobalClaudeSettings
)

$ErrorActionPreference = "Stop"

# B-3: workspace 既定値を安全なデフォルトに。空・相対パスは $env:USERPROFILE\Documents\my-ai-workspace へ。
# CWD が ZIP 展開直後のパッケージフォルダ ($PSScriptRoot の 2 階層上) だった場合も同様に安全デフォルトへ。
$packageRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))

if ([string]::IsNullOrWhiteSpace($Workspace)) {
    $Workspace = Join-Path $env:USERPROFILE "Documents\my-ai-workspace"
    Write-Host "INFO: -Workspace not specified. Using default: $Workspace"
} else {
    # 相対パスを絶対パスに展開（CWD 基準）
    if (-not [System.IO.Path]::IsPathRooted($Workspace)) {
        $Workspace = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Workspace))
    }
}

$Workspace = [System.IO.Path]::GetFullPath($Workspace)

# B-3: ZIP 展開フォルダ自身 (= packageRoot) を workspace に指定した場合は安全停止。
if ($Workspace -eq $packageRoot) {
    throw "エラー: workspace にパッケージフォルダ自身を指定しないでください。" +
          "`n例: powershell -File scripts\windows\install.ps1 -Workspace `"$env:USERPROFILE\Documents\my-ai-workspace`""
}

# B-2: workspace の親ディレクトリが存在しない場合でも自動作成する。
New-Item -ItemType Directory -Force -Path $Workspace | Out-Null

$homeSafety = if ($env:AI_SAFE_HOME_ROOT) { $env:AI_SAFE_HOME_ROOT } else { Join-Path $HOME ".ai-safety" }
$backupDir = Join-Path $homeSafety ("backups\" + (Get-Date -Format "yyyyMMdd-HHmmss"))

Write-Host ("Installing for platform: " + $Platform)

# H6/B: verify distribution integrity against docs\tested_versions.md hash table.
# ハッシュ不一致は既定で中止する（何もコピーする前に throw で exit 非0）。Test-DistributionHash 群は
# 全コピー処理より前に呼ぶので、中止時はワークスペースを一切変更しない。開発者/講師が意図的に
# policy.json 等を変更したときだけ、明示 opt-out AI_SAFE_ALLOW_HASH_MISMATCH=1 で続行できる（警告は出す）。
# 旧 AI_SAFETY_STRICT=1 は「既定で中止」に統合され不要になった（既定が常に strict）。
# docs\tested_versions.md は BOM なし UTF-8 で、日本語ファイル名の行を含む。
# Windows PowerShell 5.1 の Get-Content は -Encoding 未指定だと既定 ANSI（日本語環境では
# CP932）として読むため、日本語パスの行が壊れて「一覧に無い」「ハッシュ行が拾えない」と
# 誤判定し、日本語名のコマンドファイルが検証されないまま配置される。
# この表を読むときは必ず -Encoding UTF8 を指定すること（PS 5.1 / PS 7 とも BOM なし
# UTF-8 を正しく復号する）。
$versionsFile = Join-Path $packageRoot "docs\tested_versions.md"

# 検証表そのものが欠けていると、以下のハッシュ検証が 1 件残らずスキップされる
# （＝改ざんに気付けないまま全部配置してしまう）。「表が無い＝検証できない＝配布物が
# 壊れている」ので既定で中止する。開発者/講師が承知の上で進めるときだけ
# AI_SAFE_ALLOW_HASH_MISMATCH=1 で警告に落とせる。
function Assert-VersionsTable {
    if (Test-Path -LiteralPath $versionsFile) { return }
    if ($env:AI_SAFE_ALLOW_HASH_MISMATCH -eq '1') {
        Write-Warning "改ざん検知の一覧 docs\tested_versions.md がありません。AI_SAFE_ALLOW_HASH_MISMATCH=1 が設定されているため、検証せずに続行します。"
        return
    }
    throw ("配布物が壊れています。改ざん検知の一覧 docs\tested_versions.md が見つかりません。`n" +
           "  この表が無いと配布ファイルの改ざん検知が一切できないため、インストールを中止しました。`n" +
           "  パッケージを配布元から取り直してください。`n" +
           "  （講師が承知の上で進める場合のみ AI_SAFE_ALLOW_HASH_MISMATCH=1 を設定して再実行）")
}
Assert-VersionsTable

function Test-DistributionHash([string]$RelPath) {
    $absPath = Join-Path $packageRoot ($RelPath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $absPath)) { return }
    if (-not (Test-Path -LiteralPath $versionsFile)) { return }
    $expected = $null
    foreach ($line in Get-Content -LiteralPath $versionsFile -Encoding UTF8) {
        if ($line -match ("^\|\s*" + [regex]::Escape($RelPath) + "\s*\|\s*([0-9a-fA-F]{64})\s*\|")) {
            $expected = $Matches[1].ToLower()
            break
        }
    }
    if (-not $expected) { return }
    $actual = (Get-FileHash -LiteralPath $absPath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        Write-Warning ("配布ファイルのハッシュが一致しません: " + $RelPath)
        Write-Warning ("  期待値: " + $expected)
        Write-Warning ("  実際:   " + $actual)
        if ($env:AI_SAFE_ALLOW_HASH_MISMATCH -eq '1') {
            Write-Warning "  AI_SAFE_ALLOW_HASH_MISMATCH=1 が設定されているため、警告のまま続行します（開発者/講師のカスタマイズ用）。"
        } else {
            throw ("配布ファイルのハッシュ不一致のためインストールを中止しました: " + $RelPath + "`n" +
                   "  配布が壊れているか改変された可能性があります。`n" +
                   "  講師が意図的に変更した場合は docs\tested_versions.md のハッシュを更新するか、環境変数 AI_SAFE_ALLOW_HASH_MISMATCH=1 を設定して再実行してください。")
        }
    }
}

Test-DistributionHash "policy/safety-policy.json"
switch ($Platform) {
    'mac' {
        Test-DistributionHash "configs/codex/hooks.mac.json"
        Test-DistributionHash "configs/claude/settings.mac.json"
        Test-DistributionHash "configs/gemini/settings.mac.json"
        Test-DistributionHash "configs/codex/config.mac.toml"
    }
    'win' {
        Test-DistributionHash "configs/codex/hooks.windows.json"
        Test-DistributionHash "configs/claude/settings.windows.json"
        Test-DistributionHash "configs/gemini/settings.windows.json"
        Test-DistributionHash "configs/codex/config.windows.toml"
        Test-DistributionHash "configs/codex/safe.config.toml"
    }
    'both' {
        Test-DistributionHash "configs/codex/hooks.mac.json"
        Test-DistributionHash "configs/codex/hooks.windows.json"
        Test-DistributionHash "configs/claude/settings.mac.json"
        Test-DistributionHash "configs/claude/settings.windows.json"
        Test-DistributionHash "configs/gemini/settings.mac.json"
        Test-DistributionHash "configs/gemini/settings.windows.json"
        Test-DistributionHash "configs/codex/config.mac.toml"
        Test-DistributionHash "configs/codex/safe.config.toml"
        Test-DistributionHash "configs/codex/config.windows.toml"
    }
}
# 「必ず検証対象であるべき」ファイル用。表に行が無い = そのファイルだけ改ざん検知が
# 効かない状態なので、黙って素通しさせない。扱いは 2 段階にする。
#   (a) AI に読ませる指示書 (opencode-harness / dist-opencode / dist-skills 配下) は
#       実質コード相当で、余分な .md が 1 枚混じるだけで無検証のままモデル指示として
#       有効になってしまう。ここは登録漏れも**中止**する (fail-closed)。講師が承知の上で
#       進めるときだけ AI_SAFE_ALLOW_UNLISTED_HARNESS=1 で続行できる。
#   (b) それ以外の一般ファイルは従来どおり**警告のみ**で続行する。受講者の導入を
#       止めないほうを優先し、登録漏れはリリース前のテストで落とす
#       (scripts/common/test/opencode-harness.test.js が「同梱物に未登録が無いこと」を検査)。
$hashListingRequiredPrefixes = @(
    'workspace-template/opencode-harness/',
    'workspace-template/dist-opencode/',
    'workspace-template/dist-skills/'
)

function Test-DistributionHashListed([string]$RelPath) {
    $absPath = Join-Path $packageRoot ($RelPath -replace '/', '\')
    if ((Test-Path -LiteralPath $absPath) -and (Test-Path -LiteralPath $versionsFile)) {
        $listed = $false
        foreach ($line in Get-Content -LiteralPath $versionsFile -Encoding UTF8) {
            if ($line.Contains("| " + $RelPath + " |")) { $listed = $true; break }
        }
        if (-not $listed) {
            $mustBeListed = $false
            foreach ($prefix in $hashListingRequiredPrefixes) {
                if ($RelPath.StartsWith($prefix)) { $mustBeListed = $true; break }
            }
            if ($mustBeListed -and $env:AI_SAFE_ALLOW_UNLISTED_HARNESS -ne '1') {
                throw ("このファイルは改ざん検知の一覧に登録されていません: " + $RelPath + "`n" +
                       "  AI に読ませる指示書は実質コード相当のため、未検証のまま配置せずに中止しました。`n" +
                       "  講師向け: docs\tested_versions.md にハッシュ行を追加してください。`n" +
                       "  （承知の上で進める場合のみ AI_SAFE_ALLOW_UNLISTED_HARNESS=1 を設定して再実行）")
            }
            Write-Warning ("このファイルは改ざん検知の一覧に登録されていません: " + $RelPath)
            Write-Warning "      講師向け: docs\tested_versions.md にハッシュ行を追加してください。"
        }
    }
    Test-DistributionHash $RelPath
}

# v1.17.0: 秘密の金庫・マスキング・PC 全体設定・フォルダ保護・長時間おまかせモードの実体も
# 改ざん検知の対象に入れる。これらは「安全装置そのもの」なので、設定ファイルだけ守っても足りない。
# 表に行が無いファイルは素通しする実装なので、片 OS 分しか入っていない配布でも壊れない。
foreach ($sec in @(
    'scripts/common/secret-store.js',
    'scripts/common/secret-migrate.js',
    'scripts/common/secret-patterns.js',
    'scripts/common/clipboard-mask.js',
    'scripts/common/apply-global-guard.js',
    'scripts/common/apply-global-codex.js',
    'scripts/common/apply-global-agy.js',
    'scripts/common/apply-global-opencode.js',
    'scripts/common/apply-global-deny.js',
    'scripts/macos/apply-global-guard.sh',
    'scripts/macos/uninstall-global-guard.sh',
    'scripts/macos/protect-folder.sh',
    'scripts/macos/launch-claude-longrun.sh',
    'scripts/windows/apply-global-guard.ps1',
    'scripts/windows/uninstall-global-guard.ps1',
    'scripts/windows/protect-folder.ps1',
    'scripts/windows/launch-claude-longrun.ps1'
)) {
    Test-DistributionHash $sec
}

Test-DistributionHash "configs/gemini/policies/safety.toml"
Test-DistributionHash "workspace-template/aiexclude.template"
Test-DistributionHashListed "workspace-template/dist-skills/hearing-ladder/SKILL.md"
# OpenCode 用の日本語ハーネス (AGENTS.md / スラッシュコマンド / 追加エージェント)。
# モデルに読ませる指示書 = 実質コード相当なので、同梱ファイルは丸ごとハッシュ検証対象にする。
# 配布元フォルダ名は制作途中で opencode-harness / dist-opencode の両方が使われたため、
# 存在するほうを採用する (配置先の名前は opencode-harness に正規化する)。
$harnessSrcRoot = $null
foreach ($harnessCandidate in @('opencode-harness', 'dist-opencode')) {
    $candidatePath = Join-Path $packageRoot ("workspace-template\" + $harnessCandidate)
    if (Test-Path -LiteralPath $candidatePath -PathType Container) { $harnessSrcRoot = $candidatePath; break }
}
if ($harnessSrcRoot) {
    foreach ($harnessFile in @(Get-ChildItem -LiteralPath $harnessSrcRoot -Recurse -File -Filter *.md -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $rel = $harnessFile.FullName.Substring($packageRoot.Length).TrimStart('\', '/').Replace('\', '/')
        Test-DistributionHashListed $rel
    }
}

function Copy-WithBackup([string]$Source, [string]$Dest) {
    $destDir = Split-Path -Parent $Dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    if (Test-Path -LiteralPath $Dest) {
        $relativeName = ($Dest -replace "[:\\\/]+", "_")
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        Copy-Item -LiteralPath $Dest -Destination (Join-Path $backupDir $relativeName) -Force
    }
    Copy-Item -LiteralPath $Source -Destination $Dest -Force
}

New-Item -ItemType Directory -Force -Path $homeSafety | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Workspace ".ai-safety\hooks") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Workspace ".ai-safety\policy") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Workspace ".ai-safety\cards") | Out-Null
# 利用者が自分でプラグインを置く場所 (v1.15.0〜)。`.ai-safety` は AI の書き込み禁止パスなので
# AI にはこのフォルダを作れず、ここに置けるのは人だけ。隠しフォルダの下なので受講者が
# エクスプローラーで作るのは難しく、こちらで用意しておく (中身は空のまま)。
$pluginsDir = Join-Path $Workspace ".ai-safety\plugins"
New-Item -ItemType Directory -Force -Path $pluginsDir | Out-Null
# 置き方の説明を 1 枚だけ置く。ランチャーは .js / .ts しか見ないので .txt は読み込まれない。
# 既にあるときは触らない (利用者が書き足しているかもしれないため)。
$pluginsReadme = Join-Path $pluginsDir "README.txt"
if (-not (Test-Path -LiteralPath $pluginsReadme)) {
    $pluginsReadmeText = @"
このフォルダは、OpenCode で使うプラグインを自分で置く場所です。

・ここに .js または .ts のファイルを置くと、次に統合ランチャーから OpenCode を
  起動したときに読み込みます。
・このフォルダの直下だけを見ます。中にフォルダを作って入れても読み込みません。
・初めて置いたとき、中身を変えたときは、起動が一度止まって名前を表示し、
  Enter を押すまで先に進みません (顔ぶれが同じなら次からは聞きません)。
・置いていないときは、これまでと同じ静かな起動になります。

【重要】ここに置いたコードは、承認モニターの確認を通りません。
「このコマンドを実行していいですか」の確認画面が出ないだけでなく、
見守りの仕組みそのものを止めることもできます。
中身を自分で確かめたものだけを置いてください。

うまく起動しなくなったときは、まずこのフォルダを疑ってください。
プラグインの書き方が誤っていると、OpenCode はプラグインの読み込み全体を中止し、
見守りプラグインも載らないため、安全のため起動を止めます。
「導入をやり直す」ではこのフォルダは消えません。中身を別の場所へ移してから
起動し直してください。

詳しくは説明書の「10_OpenCode_DeepSeekを安全に使う」の
「自分で入れたプラグインを使う」を読んでください。

"@
    # メモ帳でそのまま読めるよう UTF-8 (BOM 付き) で書き出す。
    [System.IO.File]::WriteAllText($pluginsReadme, $pluginsReadmeText, (New-Object System.Text.UTF8Encoding($true)))
}

Copy-Item -LiteralPath (Join-Path $packageRoot "policy\safety-policy.json") -Destination (Join-Path $Workspace ".ai-safety\policy\safety-policy.json") -Force

# コピー元パッケージの場所を残す。「新しい作業フォルダを安全にする」ボタンは、
# ワークスペース側から実行されたときにこれを辿ってパッケージ本体 (configs / policy /
# workspace-template) を見つける。見つからなければボタン側が案内して止まる。
Set-Content -LiteralPath (Join-Path $Workspace ".ai-safety\package-source.txt") -Value $packageRoot -Encoding UTF8 -Force

# agent-monitor 解説カード一式を .ai-safety\cards\ に配置する。
$cardsSrc = Join-Path $packageRoot "configs\safety\cards"
$cardsDest = Join-Path $Workspace ".ai-safety\cards"
if (Test-Path -LiteralPath $cardsSrc) {
    if (Test-Path -LiteralPath $cardsDest) {
        Remove-Item -LiteralPath $cardsDest -Recurse -Force
    }
    Copy-Item -LiteralPath $cardsSrc -Destination $cardsDest -Recurse -Force
}

if ($Platform -in 'win','both') {
    # B-4: PS 5.1 と 7 で Copy-Item -Recurse の挙動差を回避。
    # 宛先フォルダを先に削除して作り直し、中身 (*) を明示コピーする。
    $winDest = Join-Path $Workspace ".ai-safety\hooks\windows"
    # 更新を fetch-update 経由で「このフォルダの中から」実行していると、フォルダが使用中で
    # 削除できず更新が中断する。削除は best-effort(-EA SilentlyContinue)にし、上書きコピーで
    # 更新する。実行中の updater 自身のファイル(fetch-update.*)は上書きできないことがあるが
    # 飛ばして続行し、他のガード/ランチャーは確実に更新する(updater 自身は次回起動で反映)。
    if (Test-Path -LiteralPath $winDest) {
        Remove-Item -LiteralPath $winDest -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $winDest | Out-Null
    Copy-Item -Path (Join-Path $packageRoot "scripts\windows\*") -Destination $winDest -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Platform -in 'mac','both') {
    # B-4: mac 側も同様に明示コピー。
    $macDest = Join-Path $Workspace ".ai-safety\hooks\macos"
    if (Test-Path -LiteralPath $macDest) {
        Remove-Item -LiteralPath $macDest -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $macDest | Out-Null
    Copy-Item -Path (Join-Path $packageRoot "scripts\macos\*") -Destination $macDest -Recurse -Force
    # Foreign-OS hooks become read-only to shrink attack surface (H3).
    $aclPath = Join-Path $Workspace ".ai-safety\hooks\macos"
    if (Test-Path -LiteralPath $aclPath) {
        Get-ChildItem -Path $aclPath -Recurse -File | ForEach-Object {
            $acl = Get-Acl $_.FullName
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'Read',
                'Allow'
            )
            $acl.SetAccessRule($rule)
            Set-Acl -Path $_.FullName -AclObject $acl
        }
    }
}

# DeepSeek 送信検査 Gateway（クロスプラットフォーム・Node 実装）を配置
$commonDest = Join-Path $Workspace ".ai-safety\hooks\common"
if (Test-Path -LiteralPath $commonDest) {
    Remove-Item -LiteralPath $commonDest -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $commonDest | Out-Null
Copy-Item -Path (Join-Path $packageRoot "scripts\common\*") -Destination $commonDest -Recurse -Force

# 旧「最大保護モード」で使っていたローカル検査 Gateway（ローカル LLM 必須）は v1.17.0 で
# 廃止した。受講生の PC ではほぼ動かせないのにメニューに出ていたため。既存の作業フォルダに
# 残っている古い配置はバックアップしてから片付ける。
$legacyBouncer = Join-Path $Workspace ".ai-safety\bouncer"
if (Test-Path -LiteralPath $legacyBouncer) {
    $relativeName = ($legacyBouncer -replace "[:\\\/]+", "_")
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Copy-Item -LiteralPath $legacyBouncer -Destination (Join-Path $backupDir $relativeName) -Recurse -Force
    Remove-Item -LiteralPath $legacyBouncer -Recurse -Force
}

# Defensive cleanup: remove stale foreign-OS hook dirs on single-platform install.
if ($Platform -eq 'win') {
    $staleMac = Join-Path $Workspace ".ai-safety\hooks\macos"
    if (Test-Path -LiteralPath $staleMac) { Remove-Item -LiteralPath $staleMac -Recurse -Force }
}
if ($Platform -eq 'mac') {
    $staleWin = Join-Path $Workspace ".ai-safety\hooks\windows"
    if (Test-Path -LiteralPath $staleWin) { Remove-Item -LiteralPath $staleWin -Recurse -Force }
}

Copy-WithBackup (Join-Path $packageRoot "configs\claude\settings.windows.json") (Join-Path $Workspace ".claude\settings.json")
Copy-WithBackup (Join-Path $packageRoot "configs\codex\config.windows.toml") (Join-Path $Workspace ".codex\config.toml")
# codex 0.135: safe.config.toml を workspace .codex\ に配置する。
# launcher (launch-codex-safe.ps1) がこれを $CODEX_HOME へコピーして `--profile safe` に使う。
$safeConfigSrc = Join-Path $packageRoot "configs\codex\safe.config.toml"
if (Test-Path -LiteralPath $safeConfigSrc) {
    Copy-WithBackup $safeConfigSrc (Join-Path $Workspace ".codex\safe.config.toml")
}
Copy-WithBackup (Join-Path $packageRoot "configs\codex\hooks.windows.json") (Join-Path $Workspace ".codex\hooks.json")
Copy-WithBackup (Join-Path $packageRoot "configs\gemini\settings.windows.json") (Join-Path $Workspace ".gemini\settings.json")
Copy-WithBackup (Join-Path $packageRoot "configs\gemini\policies\safety.toml") (Join-Path $Workspace ".gemini\policies\safety.toml")
Copy-WithBackup (Join-Path $packageRoot "workspace-template\aiexclude.template") (Join-Path $Workspace ".aiexclude")

# 各agentのプロジェクト指示。利用者が既に編集している場合は上書きしない。
foreach ($guide in @("AGENTS.md", "CLAUDE.md", "GEMINI.md")) {
    $guideSrc = Join-Path $packageRoot ("workspace-template\" + $guide)
    $guideDest = Join-Path $Workspace $guide
    if ((Test-Path -LiteralPath $guideSrc) -and -not (Test-Path -LiteralPath $guideDest)) {
        Copy-Item -LiteralPath $guideSrc -Destination $guideDest -Force
    }
}

# 配布スキルを workspace の .claude\skills\ に配置。d-claude / claude が起動時に
# ${workspace}\.claude\skills 配下を読み込むので、ここに置けば受講者もそのまま使える。
# リポジトリ側は dist-skills\ に置く（.gitignore が .claude/ を除外するため）。
# スキル単位で処理: 同名の既存スキル（ユーザーが手を入れた版も含む）は backup へ退避してから
# 入れ替える（Copy-WithBackup と同じ思想）。同梱していない他スキルには触れない。
# ※ かつて .opencode\skills\ にも同じものを置いていたが、OpenCode 統合ランチャーは
#   OPENCODE_DISABLE_PROJECT_CONFIG=1 で起動するためプロジェクトの .opencode\ は
#   スキャンされない (プローブスキルで実測)。死にコードなので廃止し、OpenCode 用は
#   下の .ai-safety\dist-skills → (起動時に) 隔離設定ディレクトリ側へ一本化した。
$skillsSrc = Join-Path $packageRoot "workspace-template\dist-skills"
if (Test-Path -LiteralPath $skillsSrc) {
    $skillsDest = Join-Path $Workspace ".claude\skills"
    New-Item -ItemType Directory -Force -Path $skillsDest | Out-Null
    Get-ChildItem -LiteralPath $skillsSrc -Directory -Force | ForEach-Object {
        $skillDestDir = Join-Path $skillsDest $_.Name
        if (Test-Path -LiteralPath $skillDestDir) {
            $relativeName = ($skillDestDir -replace "[:\\\/]+", "_")
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            Copy-Item -LiteralPath $skillDestDir -Destination (Join-Path $backupDir $relativeName) -Recurse -Force
            Remove-Item -LiteralPath $skillDestDir -Recurse -Force
        }
        Copy-Item -LiteralPath $_.FullName -Destination $skillDestDir -Recurse -Force

    }
    Write-Host "配布スキルを配置しました: $skillsDest"

    # OpenCode 統合ランチャー用の配布元。起動時に隔離設定ディレクトリ
    # ($XDG_CONFIG_HOME\opencode\skills\) へ毎回コピーされる。受講者が触る場所ではないので
    # .ai-safety 配下 (パッケージ管理領域) に置き、丸ごと入れ替える。
    $distSkillsDest = Join-Path $Workspace ".ai-safety\dist-skills"
    if (Test-Path -LiteralPath $distSkillsDest) {
        $relativeName = ($distSkillsDest -replace "[:\\\/]+", "_")
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        Copy-Item -LiteralPath $distSkillsDest -Destination (Join-Path $backupDir $relativeName) -Recurse -Force
        Remove-Item -LiteralPath $distSkillsDest -Recurse -Force
    }
    Copy-Item -LiteralPath $skillsSrc -Destination $distSkillsDest -Recurse -Force
}

# OpenCode 用の日本語ハーネス一式 (AGENTS.md / command / agents) を .ai-safety 配下に配置する。
# 起動時にランチャーが隔離設定ディレクトリへ毎回コピーするため、ここが配布元になる。
if ($harnessSrcRoot) {
    $harnessDest = Join-Path $Workspace ".ai-safety\opencode-harness"
    if (Test-Path -LiteralPath $harnessDest) {
        $relativeName = ($harnessDest -replace "[:\\\/]+", "_")
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        Copy-Item -LiteralPath $harnessDest -Destination (Join-Path $backupDir $relativeName) -Recurse -Force
        Remove-Item -LiteralPath $harnessDest -Recurse -Force
    }
    Copy-Item -LiteralPath $harnessSrcRoot -Destination $harnessDest -Recurse -Force
    Write-Host "OpenCode 用の日本語ハーネスを配置しました: $harnessDest"
}

# A-1: .gitignore.template を workspace ルートに .gitignore としてコピーする。
# 既存の .gitignore は上書きせず、auth.json / .codex / .claude 等の必須エントリを追記する。
$gitignoreTemplate = Join-Path $packageRoot "workspace-template\.gitignore.template"
$gitignoreDest = Join-Path $Workspace ".gitignore"
if (Test-Path -LiteralPath $gitignoreTemplate) {
    if (Test-Path -LiteralPath $gitignoreDest) {
        # 既存 .gitignore に必須エントリが欠落していれば追記する
        $existing = Get-Content -LiteralPath $gitignoreDest -Raw
        $required = @("auth.json", "*.codex.auth*", ".codex/", ".claude/", ".codex-safe/")
        $missingEntries = $required | Where-Object { $existing -notmatch [regex]::Escape($_) }
        if ($missingEntries.Count -gt 0) {
            $appendBlock = "`n# AI safety package required entries (A-1 auto-appended by install.ps1)`n" + ($missingEntries -join "`n") + "`n"
            Add-Content -LiteralPath $gitignoreDest -Value $appendBlock -Encoding UTF8
            Write-Host ("Appended " + $missingEntries.Count + " missing safety entries to existing .gitignore")
        }
    } else {
        Copy-Item -LiteralPath $gitignoreTemplate -Destination $gitignoreDest -Force
        Write-Host "Created .gitignore from workspace-template/.gitignore.template"
    }
}

# 受講者向けスタートフォルダ（番号ラッパー + 案内 HTML）を workspace に配置。
# ファイルシステム構造とは別に「ここを見てポチポチやれば使える」入口を用意する。
$startSrc = Join-Path $packageRoot "workspace-template\スタート"
if (Test-Path -LiteralPath $startSrc) {
    $startDest = Join-Path $Workspace "スタート"
    New-Item -ItemType Directory -Force -Path $startDest | Out-Null
    # v1.16.0 の番号再編で名前が変わった旧ボタンを掃除する（旧新併存による番号重複の防止）。
    # 消すのは「パッケージが過去に配布した既知の旧名」だけに限定し、受講者の自作ファイルには触らない。
    $legacyStartNames = @(
        "0_Bouncer統合版を起動.command", "0_Bouncer統合版を起動.bat",
        "6_最新版に更新.command", "6_最新版に更新.bat",
        "7_困ったとき診断.bat",
        "7_野良d-claudeを退治.command", "7_野良d-claudeを退治.bat",
        "8_PowerShellを開く.bat",
        "9_作業ウィンドウを開く.bat",
        "（上級）5_モニターをコンソールで見る.command", "（上級）5_モニターをコンソールで見る.bat",
        "（上級）6_ステータスラインを入れる.command", "（上級）6_ステータスラインを入れる.bat",
        "（上級）7_危険コマンドをClaude全体で禁止.command", "（上級）7_危険コマンドをClaude全体で禁止.bat",
        "（上級）8_グローバル禁止を解除.command", "（上級）8_グローバル禁止を解除.bat",
        "（上級）9_DeepSeekキーを削除.command", "（上級）9_DeepSeekキーを削除.bat",
        "（上級）10_ccmuxを入れる.command", "（上級）10_ccmuxを入れる.bat",
        "（上級）11_Bufferのキーを登録.command", "（上級）11_Bufferのキーを登録.bat",
        "（上級）12_プラグインの置き場を開く.command", "（上級）12_プラグインの置き場を開く.bat",
        "（上級）5_危険コマンドをClaude全体で禁止.command", "（上級）5_危険コマンドをClaude全体で禁止.bat",
        "（上級）6_グローバル禁止を解除.command", "（上級）6_グローバル禁止を解除.bat"
    )
    foreach ($legacyName in $legacyStartNames) {
        $legacyPath = Join-Path $startDest $legacyName
        if (Test-Path -LiteralPath $legacyPath) {
            Remove-Item -LiteralPath $legacyPath -Force
            Write-Host ("旧ボタンを削除しました: スタート\" + $legacyName)
        }
    }
    Copy-Item -Path (Join-Path $startSrc "*") -Destination $startDest -Recurse -Force
    $htmlSrc = Join-Path $packageRoot "スタート.html"
    if (Test-Path -LiteralPath $htmlSrc) {
        # workspace 配置（スタート\スタート.html）では説明書が ..\docs\ にあるため、
        # コピー時にリンクだけ書き換える。パッケージ直下の スタート.html は docs/ のままで正しい。
        $htmlDest = Join-Path $startDest "スタート.html"
        $htmlText = [System.IO.File]::ReadAllText($htmlSrc)
        $htmlText = $htmlText.Replace('href="docs/', 'href="../docs/')
        [System.IO.File]::WriteAllText($htmlDest, $htmlText, (New-Object System.Text.UTF8Encoding($false)))
    }
    # 受講者が同名ファイル（.command と .bat）で迷わないよう、当該 OS 用だけ残す。
    if ($Platform -eq 'win') {
        Get-ChildItem -LiteralPath $startDest -Filter *.command -ErrorAction SilentlyContinue | Remove-Item -Force
    } elseif ($Platform -eq 'mac') {
        Get-ChildItem -LiteralPath $startDest -Filter *.bat -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    Write-Host "スタートフォルダを配置しました: $startDest"
}

# 受講者向け説明書 (docs/) を workspace\docs\ に同期する。スタート.html や各ボタンの
# 案内が参照する説明書を、受講者が手元（ワークスペース）で開けるようにするのが目的。
# ・受講者向けのみ同期し、開発者向けの _dev\ と _archive\ は持ち込まない
# ・「パッケージ由来のファイルだけ」を上書き・削除の対象にする。前回配布した一覧
#   （マニフェスト）に載っていて今回の配布に無いファイルだけを消すので、受講者が
#   docs\ 内に置いた自作メモには触らない
# ・上書き前に既存 docs\ を丸ごと控え（backupDir）に取る（Copy-WithBackup と同じ思想）
$docsSrc = Join-Path $packageRoot "docs"
if (Test-Path -LiteralPath $docsSrc) {
    $docsDest = Join-Path $Workspace "docs"
    $docsManifest = Join-Path $Workspace ".ai-safety\docs-manifest.txt"
    if (Test-Path -LiteralPath $docsDest) {
        $relativeName = ($docsDest -replace "[:\\\/]+", "_")
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        Copy-Item -LiteralPath $docsDest -Destination (Join-Path $backupDir $relativeName) -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $docsDest | Out-Null
    # 今回配布するファイル一覧（docs\ からの相対パス。_dev / _archive は除外）
    $docsSrcFull = (Get-Item -LiteralPath $docsSrc).FullName
    $docsNewList = @()
    Get-ChildItem -LiteralPath $docsSrc -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($docsSrcFull.Length).TrimStart('\', '/')
        $relSlash = $rel -replace '\\', '/'
        if ($relSlash -like "_dev/*" -or $relSlash -like "_archive/*") { return }
        $destPath = Join-Path $docsDest $rel
        $destDir = Split-Path -Parent $destPath
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        }
        Copy-Item -LiteralPath $_.FullName -Destination $destPath -Force
        $docsNewList += $relSlash
    }
    # 前回パッケージが配ったのに今回の配布に無いファイルだけを掃除する（古い説明書の残留防止）。
    if (Test-Path -LiteralPath $docsManifest) {
        $oldEntries = Get-Content -LiteralPath $docsManifest -Encoding UTF8 | Where-Object { $_ }
        foreach ($oldRel in $oldEntries) {
            if ($docsNewList -notcontains $oldRel) {
                $stalePath = Join-Path $docsDest ($oldRel -replace '/', '\')
                if (Test-Path -LiteralPath $stalePath -PathType Leaf) {
                    Remove-Item -LiteralPath $stalePath -Force
                    Write-Host ("旧説明書を削除しました: docs\" + $oldRel)
                }
            }
        }
    }
    Set-Content -LiteralPath $docsManifest -Value ($docsNewList -join "`n") -Encoding UTF8
    Write-Host "説明書を配置しました: $docsDest"
}

# 動作確認済みツール版の表 (SSOT)。「8_AIツールを最新版に更新」が参照する。
$toolVersionsSrc = Join-Path $packageRoot "configs\tested-tool-versions.json"
if (Test-Path -LiteralPath $toolVersionsSrc) {
    Copy-Item -LiteralPath $toolVersionsSrc -Destination (Join-Path $Workspace ".ai-safety\tested-tool-versions.json") -Force
}

# Zed 等のターミナルから「一発」で起動できる短命名ショートカット (.cmd) を workspace 直下に配置。
# .bat の中身を貼るのではなく、これを `.\codex-safe.cmd` 等で実行 or ダブルクリックする。
# %~dp0 で自分の場所からワークスペースを特定するので cwd に依存しない。
# Windows のみ (mac は ~/.zshrc の codex-safe 等エイリアスで同等)。
if ($Platform -eq 'win') {
    $shimPlaced = @()
    foreach ($shim in @("codex-safe.cmd", "claude-safe.cmd", "agy-safe.cmd", "monitor.cmd", "d-claude.cmd")) {
        $shimSrc = Join-Path $packageRoot ("workspace-template\" + $shim)
        if (Test-Path -LiteralPath $shimSrc) {
            Copy-Item -LiteralPath $shimSrc -Destination (Join-Path $Workspace $shim) -Force
            $shimPlaced += $shim
        }
    }
    if ($shimPlaced.Count -gt 0) {
        Write-Host ("ターミナル用ショートカットを配置しました (" + ($shimPlaced -join " / ") + ")")
        Write-Host "  Zed 等のターミナルでは  .\monitor.cmd  と  .\codex-safe.cmd  を実行してください。"
    }

    # さらに PATH 登録して `codex-safe` / `monitor` を `.\` 無し・どのフォルダからでも使えるようにする。
    # 失敗してもインストール本体は止めない(PATH 登録は付加価値)。
    if ($env:AI_SAFE_TEST_MODE -ne '1') {
        $setupCmds = Join-Path $packageRoot "scripts\windows\setup-commands.ps1"
        if (Test-Path -LiteralPath $setupCmds) {
            try {
                & $setupCmds -Workspace $Workspace
            } catch {
                Write-Warning ("ターミナルコマンドの PATH 登録に失敗しました(スキップ): " + $_.Exception.Message)
                Write-Host "  後で手動登録するには: powershell -ExecutionPolicy Bypass -File `"$Workspace\.ai-safety\hooks\windows\setup-commands.ps1`" -Workspace `"$Workspace`""
            }
        }

        # 既存PCに残った npm グローバル版や PowerShell プロファイル関数の d-claude は
        # 正規シムより優先されることがある。更新ボタンだけで直せるよう、削除ではなく
        # バックアップ退避/コメントアウトを自動実行する。
        $cleanupDClaude = Join-Path $packageRoot "scripts\windows\野良d-claudeを退治.ps1"
        if (Test-Path -LiteralPath $cleanupDClaude) {
            try {
                & $cleanupDClaude -Workspace $Workspace -Yes
            } catch {
                Write-Warning ("野良 d-claude の自動退避に失敗しました(スキップ): " + $_.Exception.Message)
                Write-Host "  必要なら後で スタート\10_野良d-claudeを退治.bat を実行してください。"
            }
        }
    } else {
        Write-Host "TEST MODE: PATH登録と既存d-claudeの整理をスキップしました。"
    }
}

if ($InstallGlobalClaudeSettings) {
    $globalSrc = Join-Path $packageRoot "configs\claude\settings.windows.json"
    $globalTarget = Join-Path $HOME ".claude\settings.json"
    $denyJs = Join-Path $packageRoot "scripts\common\apply-global-deny.js"
    # A案 (2026-07): settings を丸ごとコピーせず、permissions.deny だけを union マージする。
    # 丸ごとコピーは hook が ${CLAUDE_PROJECT_DIR}\.ai-safety を探し、そのフォルダが無い場所で
    # 全 Bash が exit2 ブロックになる落とし穴があったため廃止。既存の hooks/env/allow/ask は不変。
    if (Get-Command node -ErrorAction SilentlyContinue) {
        Write-Host "Merging package deny rules into global ~/.claude/settings.json (既存の hooks/env は不変)..."
        node $denyJs $globalSrc $globalTarget
        if ($LASTEXITCODE -ne 0) { Write-Warning "global deny merge failed (skipped)." }
    } else {
        Write-Warning "node not found; skipped global Claude deny merge (Node.js が必要です)."
    }
}

# --- %USERPROFILE%\.ai-safety の権限を締める（mac の chmod 700/600 と対称） -----
# ここには API キーの平文ファイル（gemini-api-key.txt など）と AI の実行ログが置かれる。
# mac 側は install.sh が chmod 700/600 を掛け直す。Windows に chmod は無いので、
# 継承を切って「現在のユーザーだけがフル制御」の ACL に落とす（icacls の /inheritance:r と
# /grant:r）。既定でもユーザープロファイル配下は他ユーザーから読めないが、フォルダを
# 別の場所から移動・コピーしてきた場合に緩い ACL が付いたまま残ることがあるため明示する。
# 失敗しても導入は止めない（権限の締め直しは追加の保険であって、保護の本体ではない）。
$aiSafeHome = Join-Path $env:USERPROFILE ".ai-safety"
if ((Test-Path -LiteralPath $aiSafeHome) -and ($IsWindows -ne $false)) {
    try {
        $me = "$env:USERDOMAIN\$env:USERNAME"
        & icacls "$aiSafeHome" /inheritance:r /grant:r ("{0}:(OI)(CI)F" -f $me) /T /C /Q 2>&1 | Out-Null
        Write-Host ("権限を締めました: " + $aiSafeHome + "（現在のユーザーだけがアクセスできる ACL）")
    } catch {
        Write-Warning ("権限の締め直しに失敗しました(スキップ): " + $_.Exception.Message)
    }
}

# --- 秘密の自動移行（受講生の操作ゼロ / v1.17.0） ---------------------------
# 旧平文の API キーを OS の金庫（DPAPI）へ移す。各キーごとに冪等で、
# 「金庫へ書く → 読み戻して一致を検証 → 一致したときだけ平文を削除」の順に進む。
# 一致しなければ平文はそのまま残し、次回もう一度試す。
$secretMigrate = Join-Path $Workspace '.ai-safety\hooks\common\secret-migrate.js'
if ((Test-Path -LiteralPath $secretMigrate -PathType Leaf) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "登録済みのキーを金庫（DPAPI）へ移します..."
    try { & node $secretMigrate } catch { Write-Warning ("キーの移行をスキップしました: " + $_.Exception.Message) }
}

# --- 作業フォルダを「信頼済み」にする（v1.17.0） ---------------------------
# Claude Code は初回に対話で信頼ダイアログを承認するまで、そのフォルダの
# permissions.allow を丸ごと無視する（mac 実測で確認）。受講者はボタンから
# 起動するため承認の機会が無く、意図した許可設定が効かないまま使うことになる。
# そこで install が %USERPROFILE%\.claude.json に承認済みを記録する。
# 対象は「このスクリプトが今セットアップした作業フォルダ」だけ。
$claudeJson = Join-Path $env:USERPROFILE '.claude.json'
if (Get-Command node -ErrorAction SilentlyContinue) {
    $env:AI_SAFE_CLAUDE_JSON = $claudeJson
    $env:AI_SAFE_WORKSPACE = $Workspace
    $env:AI_SAFE_BACKUP_DIR = $backupDir
    $trustScript = @'
const fs = require("fs");
const path = require("path");
const file = process.env.AI_SAFE_CLAUDE_JSON;
const ws = process.env.AI_SAFE_WORKSPACE;
const backupDir = process.env.AI_SAFE_BACKUP_DIR;
let data = {};
if (fs.existsSync(file)) {
  const raw = fs.readFileSync(file, "utf8");
  try {
    data = JSON.parse(raw);
  } catch (e) {
    process.exit(3);
  }
  try { fs.copyFileSync(file, path.join(backupDir, "claude.json")); } catch (e) {}
}
if (!data.projects || typeof data.projects !== "object") data.projects = {};
if (!data.projects[ws] || typeof data.projects[ws] !== "object") data.projects[ws] = {};
if (data.projects[ws].hasTrustDialogAccepted === true) process.exit(1);
data.projects[ws].hasTrustDialogAccepted = true;
const tmp = file + ".ai-safety-tmp";
fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n");
fs.renameSync(tmp, file);
process.exit(0);
'@
    $trustFile = Join-Path $env:TEMP ("ai-safety-trust-" + [System.Guid]::NewGuid().ToString("N") + ".js")
    try {
        Set-Content -LiteralPath $trustFile -Value $trustScript -Encoding UTF8
        & node $trustFile
        $trustRc = $LASTEXITCODE
        if ($trustRc -eq 0) {
            Write-Host "作業フォルダを Claude の信頼済みに登録しました（許可設定が最初から有効になります）。"
        } elseif ($trustRc -eq 1) {
            # すでに登録済み。何も言わない。
        } elseif ($trustRc -eq 3) {
            Write-Host ("注意: " + $claudeJson + " を読めなかったため、信頼済み登録をスキップしました。")
            Write-Host "      Claude を1回ふつうに起動して、信頼の確認に「はい」と答えてください。"
        } else {
            Write-Host "注意: 信頼済み登録に失敗しました。Claude を1回ふつうに起動して、"
            Write-Host "      信頼の確認に「はい」と答えてください。"
        }
    } catch {
        Write-Warning ("信頼済み登録をスキップしました: " + $_.Exception.Message)
    } finally {
        Remove-Item -LiteralPath $trustFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "AI Safety package installed."
Write-Host ("Workspace: " + $Workspace)
Write-Host ("Backups: " + $backupDir)
Write-Host "Next: powershell -ExecutionPolicy Bypass -File .ai-safety\hooks\windows\doctor.ps1"
