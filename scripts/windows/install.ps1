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

$homeSafety = Join-Path $HOME ".ai-safety"
$backupDir = Join-Path $homeSafety ("backups\" + (Get-Date -Format "yyyyMMdd-HHmmss"))

Write-Host ("Installing for platform: " + $Platform)

# H6: verify distribution integrity against docs\tested_versions.md hash table.
# Mismatch warns and asks for confirmation. Set AI_SAFETY_STRICT=1 to hard-fail in non-interactive runs.
function Test-DistributionHash([string]$RelPath) {
    $absPath = Join-Path $packageRoot ($RelPath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $absPath)) { return }
    $versionsFile = Join-Path $packageRoot "docs\tested_versions.md"
    if (-not (Test-Path -LiteralPath $versionsFile)) { return }
    $expected = $null
    foreach ($line in Get-Content -LiteralPath $versionsFile) {
        if ($line -match ("^\|\s*" + [regex]::Escape($RelPath) + "\s*\|\s*([0-9a-fA-F]{64})\s*\|")) {
            $expected = $Matches[1].ToLower()
            break
        }
    }
    if (-not $expected) { return }
    $actual = (Get-FileHash -LiteralPath $absPath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        Write-Warning ("SHA-256 mismatch for " + $RelPath)
        Write-Warning ("  expected: " + $expected)
        Write-Warning ("  actual:   " + $actual)
        if ([Environment]::UserInteractive -and $Host.UI.RawUI) {
            $yn = Read-Host "Continue anyway? [y/N]"
            if ($yn -notmatch '^[yY]') { throw "Aborted by user due to hash mismatch." }
        } else {
            Write-Warning "Non-interactive shell: continuing with mismatch (set AI_SAFETY_STRICT=1 to abort)."
            if ($env:AI_SAFETY_STRICT -eq '1') { throw "Hash mismatch with AI_SAFETY_STRICT=1." }
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
Test-DistributionHash "configs/gemini/policies/safety.toml"
Test-DistributionHash "workspace-template/aiexclude.template"

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

Copy-Item -LiteralPath (Join-Path $packageRoot "policy\safety-policy.json") -Destination (Join-Path $Workspace ".ai-safety\policy\safety-policy.json") -Force

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
    if (Test-Path -LiteralPath $winDest) {
        Remove-Item -LiteralPath $winDest -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $winDest | Out-Null
    Copy-Item -Path (Join-Path $packageRoot "scripts\windows\*") -Destination $winDest -Recurse -Force
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
    Copy-Item -Path (Join-Path $startSrc "*") -Destination $startDest -Recurse -Force
    $htmlSrc = Join-Path $packageRoot "スタート.html"
    if (Test-Path -LiteralPath $htmlSrc) {
        Copy-Item -LiteralPath $htmlSrc -Destination (Join-Path $startDest "スタート.html") -Force
    }
    # 受講者が同名ファイル（.command と .bat）で迷わないよう、当該 OS 用だけ残す。
    if ($Platform -eq 'win') {
        Get-ChildItem -LiteralPath $startDest -Filter *.command -ErrorAction SilentlyContinue | Remove-Item -Force
    } elseif ($Platform -eq 'mac') {
        Get-ChildItem -LiteralPath $startDest -Filter *.bat -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    Write-Host "スタートフォルダを配置しました: $startDest"
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
    $setupCmds = Join-Path $packageRoot "scripts\windows\setup-commands.ps1"
    if (Test-Path -LiteralPath $setupCmds) {
        try {
            & $setupCmds -Workspace $Workspace
        } catch {
            Write-Warning ("ターミナルコマンドの PATH 登録に失敗しました(スキップ): " + $_.Exception.Message)
            Write-Host "  後で手動登録するには: powershell -ExecutionPolicy Bypass -File `"$Workspace\.ai-safety\hooks\windows\setup-commands.ps1`" -Workspace `"$Workspace`""
        }
    }
}

if ($InstallGlobalClaudeSettings) {
    $globalSrc = Join-Path $packageRoot "configs\claude\settings.windows.json"
    $globalTarget = Join-Path $HOME ".claude\settings.json"
    # M16: 既存の global Claude 設定は他プロジェクトでも使われている可能性が高い。
    # バックアップは取るが、上書き前に必ず diff を見せて y/n 確認する。
    if (Test-Path -LiteralPath $globalTarget) {
        $srcHash = (Get-FileHash -LiteralPath $globalSrc -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash -LiteralPath $globalTarget -Algorithm SHA256).Hash
        if ($srcHash -eq $dstHash) {
            Write-Host "Global Claude settings.json already matches package version; skipping."
        } else {
            Write-Host ("Existing global Claude settings found: " + $globalTarget)
            Write-Host "----- diff (current -> package) -----"
            $diff = Compare-Object `
                -ReferenceObject (Get-Content -LiteralPath $globalTarget) `
                -DifferenceObject (Get-Content -LiteralPath $globalSrc)
            if ($diff) { $diff | Format-Table -AutoSize | Out-Host }
            Write-Host "-------------------------------------"
            $canPrompt = [Environment]::UserInteractive -and $Host.UI -and $Host.UI.RawUI
            if ($canPrompt) {
                $yn = Read-Host "Overwrite global ~/.claude/settings.json? [y/N]"
                if ($yn -match '^[yY]$') {
                    Copy-WithBackup $globalSrc $globalTarget
                } else {
                    Write-Host "Skipped global Claude settings install."
                }
            } else {
                Write-Warning "Non-interactive shell: skipped global Claude settings install (set AI_SAFETY_STRICT=1 to force overwrite)."
                if ($env:AI_SAFETY_STRICT -eq '1') {
                    Copy-WithBackup $globalSrc $globalTarget
                }
            }
        }
    } else {
        Copy-WithBackup $globalSrc $globalTarget
    }
}

Write-Host "AI Safety package installed."
Write-Host ("Workspace: " + $Workspace)
Write-Host ("Backups: " + $backupDir)
Write-Host "Next: powershell -ExecutionPolicy Bypass -File .ai-safety\hooks\windows\doctor.ps1"
