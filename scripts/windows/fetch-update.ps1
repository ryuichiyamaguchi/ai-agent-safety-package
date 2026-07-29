# fetch-update.ps1 — GitHub の最新 Release を取得して安全パッケージを更新する。
#
# 受講者は同梱の .bat をダブルクリックするだけ:
#   1. GitHub の「最新 Release」から配布 ZIP と .sha256 を取得
#   2. SHA-256 を照合してから展開（改ざん/破損を弾く）
#   3. 展開したパッケージの install.ps1 を workspace に対して実行（既存は backup 経由で保護）
#
# 取得先は GitHub 固定リダイレクト releases/latest/download/<固定名>（API を叩かない）。
# Release には固定名 ai-agent-safety-package.zip(+.sha256) を必ず添付する。
param(
    [string]$Workspace = (Join-Path $HOME "Documents\my-ai-workspace")
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ★自己ロック回避: この updater は workspace の .ai-safety\hooks\windows\ の中から実行される
#   ことがある。その場合、後で install.ps1 がそのフォルダを削除/更新しようとすると「使用中」で
#   失敗する。作業ディレクトリを一時フォルダへ移し、workspace フォルダを掴まないようにする。
try { Set-Location -LiteralPath ([System.IO.Path]::GetTempPath()) } catch {}

$repo  = "ryuichiyamaguchi/ai-agent-safety-package"
$asset = "ai-agent-safety-package.zip"
$base  = "https://github.com/$repo/releases/latest/download"

function Die([string]$msg) {
    Write-Host ""
    Write-Host ("【中止】" + $msg) -ForegroundColor Red
    Write-Host "このウィンドウを閉じて、もう一度お試しください。"
    exit 1
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-safe-update-" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $zipPath = Join-Path $tmp "pkg.zip"
    $shaPath = Join-Path $tmp "pkg.zip.sha256"

    Write-Host "最新版をダウンロードしています…"
    try {
        Invoke-WebRequest -Uri ("$base/$asset")        -OutFile $zipPath -UseBasicParsing
        Invoke-WebRequest -Uri ("$base/$asset.sha256") -OutFile $shaPath -UseBasicParsing
    } catch {
        Die "配布 ZIP を取得できませんでした（ネットワーク/最新 Release を確認してください）。"
    }

    # 2. SHA-256 照合（.sha256 の先頭トークン == 実ファイルのハッシュ）。
    $expected = ((Get-Content -LiteralPath $shaPath -Raw).Trim() -split "\s+")[0]
    $actual   = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
    if (-not $expected) { Die "チェックサムが空でした。" }
    if ($expected.ToLower() -ne $actual) { Die "チェックサムが一致しません（ダウンロード破損 or 改ざんの疑い）。中止します。" }
    Write-Host "チェックサム照合 OK。展開します…"

    # 3. 展開して**厳格に**パッケージルートを特定する。配布 ZIP は単一のトップ階層フォルダを
    # 持つ前提。トップが 1 個でなければ中止。installer は固定サブパスの通常ファイルのみ許可
    # （symlink/reparse point 経由で展開外の未検証ファイルを実行させない）。
    $unz = Join-Path $tmp "unz"
    try { Expand-Archive -LiteralPath $zipPath -DestinationPath $unz -Force } catch { Die "展開に失敗しました。" }
    $topDirs = @(Get-ChildItem -LiteralPath $unz -Directory -Force)
    if ($topDirs.Count -ne 1) { Die ("配布物の構造が想定と異なります（トップ階層フォルダが " + $topDirs.Count + " 個）。中止します。") }
    $pkgRoot = $topDirs[0].FullName
    $installerPath = Join-Path $pkgRoot "scripts\\windows\\install.ps1"
    $installerItem = Get-Item -LiteralPath $installerPath -ErrorAction SilentlyContinue
    if (-not $installerItem -or $installerItem.PSIsContainer) { Die "展開後に install.ps1 が見つかりませんでした。" }
    if (($installerItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Die "install.ps1 がリンク（reparse point）のため中止します。" }
    $packagePolicy = Join-Path $pkgRoot "policy\safety-policy.json"
    try {
        $packageVersion = (Get-Content -LiteralPath $packagePolicy -Raw -Encoding UTF8 | ConvertFrom-Json).packageVersion
    } catch {
        Die "配布物のバージョン情報を読み取れませんでした。"
    }
    if (-not $packageVersion) { Die "配布物のバージョン情報が空でした。" }

    # 4. install 実行（内部で backup → コピー → doctor。既存設定は上書き前に backup される）。
    Write-Host "パッケージを更新しています…（既存の設定はバックアップされます）"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installerPath -Workspace $Workspace
    if ($LASTEXITCODE -ne 0) { Die "インストールでエラーが発生しました。" }

    $installedPolicy = Join-Path $Workspace ".ai-safety\policy\safety-policy.json"
    try {
        $installedVersion = (Get-Content -LiteralPath $installedPolicy -Raw -Encoding UTF8 | ConvertFrom-Json).packageVersion
    } catch {
        Die "更新後のバージョン情報を読み取れませんでした。"
    }
    if ($installedVersion -ne $packageVersion) {
        Die "更新後の版を確認できませんでした（予定: v$packageVersion / 実際: v$installedVersion）。"
    }

    Write-Host ""
    Write-Host "✅ 更新が完了しました。ターミナルを開き直してからお使いください。" -ForegroundColor Green
    Write-Host "   更新された版: v$installedVersion" -ForegroundColor Green
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
