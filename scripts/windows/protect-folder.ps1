# protect-folder.ps1 — 好きなフォルダを「安全な作業フォルダ」にする (卒業後の実務用)。
#
# 卒業後は my-ai-workspace 以外のフォルダでも AI を使いたくなる。このスクリプトは
# 選んだフォルダに対して install.ps1 を通し、ワークスペース側の保護一式
# (安全ルール・ガード・安全ランチャー・スタートフォルダ・説明書・信頼ダイアログの登録) を
# まるごと入れる。install.ps1 本体を呼ぶので、既存の安全策 (パッケージ自身は対象にできない /
# 既存ファイルはバックアップ / docs 同期 / 権限の絞り込み / .claude.json の
# hasTrustDialogAccepted 登録) はすべてそのまま通る。
#
# 使い方:
#   protect-folder.ps1                    ... フォルダ選択ダイアログを出す
#   protect-folder.ps1 -Path <フォルダ>    ... ダイアログを出さずにそのフォルダを対象にする
#
# 危険な選択 (ドライブ直下・ユーザーフォルダ直下・Windows / Program Files 等・
# デスクトップ / ドキュメント などの大箱) は警告して中止する。
param([string]$Path = '', [switch]$Yes)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-PackageRoot([string]$root) {
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $root "policy\safety-policy.json")) -and
           (Test-Path -LiteralPath (Join-Path $root "workspace-template")) -and
           (Test-Path -LiteralPath (Join-Path $root "scripts\windows\install.ps1"))
}

# ワークスペース側には install.ps1 の実体はあるが、コピー元のパッケージ (configs / policy /
# workspace-template) が無い。install が残す package-source.txt を辿ってパッケージ本体を探す。
$packageRoot = ''
if ($env:AI_SAFE_PACKAGE_ROOT -and (Test-PackageRoot $env:AI_SAFE_PACKAGE_ROOT)) {
    $packageRoot = [System.IO.Path]::GetFullPath($env:AI_SAFE_PACKAGE_ROOT)
}
if (-not $packageRoot) {
    $cand = [System.IO.Path]::GetFullPath((Join-Path $here "..\.."))
    if (Test-PackageRoot $cand) { $packageRoot = $cand }
}
if (-not $packageRoot) {
    $srcFile = Join-Path $here "..\..\package-source.txt"
    if (Test-Path -LiteralPath $srcFile) {
        $cand = (Get-Content -LiteralPath $srcFile -TotalCount 1).Trim()
        if (Test-PackageRoot $cand) { $packageRoot = [System.IO.Path]::GetFullPath($cand) }
    }
}
if (-not $packageRoot) {
    Write-Host "エラー: 安全パッケージ本体のフォルダが見つかりませんでした。"
    Write-Host ""
    Write-Host "  このボタンは、安全パッケージ (ZIP を展開したフォルダ) の中身を新しいフォルダへ入れます。"
    Write-Host "  パッケージを移動・削除した場合は場所が分からなくなります。"
    Write-Host ""
    Write-Host "  → 安全パッケージのフォルダを開き、その中の"
    Write-Host "       scripts\windows\protect-folder.ps1"
    Write-Host "     を直接実行してください (フォルダ選択ダイアログが出ます)。"
    exit 2
}
$installPs1 = Join-Path $packageRoot "scripts\windows\install.ps1"

# ---- 対象フォルダを決める -------------------------------------------------
$target = $Path
if ([string]::IsNullOrWhiteSpace($target)) {
    Write-Host "安全にしたいフォルダを選んでください (選択ダイアログを開きます)..."
    $picked = ''
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.BrowseForFolder(0, "AI が安全に使えるようにするフォルダを選んでください", 0)
        if ($folder -ne $null -and $folder.Self -ne $null) { $picked = $folder.Self.Path }
    } catch {
        $picked = ''
    }
    if ([string]::IsNullOrWhiteSpace($picked)) {
        Write-Host "中止しました (フォルダが選ばれませんでした)。"
        exit 0
    }
    $target = $picked
}

if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    Write-Host "エラー: フォルダが見つかりません: $target"
    exit 2
}
$target = ([System.IO.Path]::GetFullPath($target)).TrimEnd('\')

# ---- 危険な選択を止める ---------------------------------------------------
$profileDir = ($env:USERPROFILE).TrimEnd('\')
$denyReason = ''
$targetLower = $target.ToLowerInvariant()

if ($target -match '^[A-Za-z]:$' -or $target -match '^[A-Za-z]:\\$') {
    $denyReason = 'ドライブ直下です'
} elseif ($targetLower -eq $profileDir.ToLowerInvariant()) {
    $denyReason = 'ユーザーフォルダそのものです'
} elseif ($targetLower -eq $packageRoot.ToLowerInvariant() -or $targetLower.StartsWith(($packageRoot.ToLowerInvariant() + '\'))) {
    $denyReason = '安全パッケージのフォルダ (またはその中) です'
} else {
    $systemRoots = @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:SystemDrive) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }
    foreach ($r in $systemRoots) {
        if ($r -match '^[a-z]:$') { continue }
        if ($targetLower -eq $r -or $targetLower.StartsWith($r + '\')) { $denyReason = 'システムが使うフォルダです'; break }
    }
    if (-not $denyReason) {
        # 一時領域 (%TEMP% / %TMP% / C:\Temp)。再起動やクリーンアップで中身が消えるうえ、
        # サンドボックスが一時領域への書き込みを常に許すため、ここを「守られた作業フォルダ」に
        # しても保護の意味が無くなる。
        $tempRoots = @($env:TEMP, $env:TMP, (Join-Path $env:SystemDrive 'Temp'), (Join-Path $env:WINDIR 'Temp')) |
            Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }
        foreach ($t in $tempRoots) {
            if ($t -match '^[a-z]:$') { continue }
            if ($targetLower -eq $t -or $targetLower.StartsWith($t + '\')) { $denyReason = '一時フォルダ (消える場所) です'; break }
        }
    }
    if (-not $denyReason) {
        # C:\Users 全体
        $usersRoot = (Split-Path -Parent $profileDir)
        if ($usersRoot -and $targetLower -eq $usersRoot.ToLowerInvariant()) { $denyReason = 'すべてのユーザーを含むフォルダです' }
    }
    if (-not $denyReason) {
        # ユーザーフォルダ直下の「大箱」(この中に何でも入っている)
        $bigBoxes = @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos', 'OneDrive',
                      'AppData', 'デスクトップ', 'ドキュメント', 'ダウンロード', 'ピクチャ', 'ミュージック', 'ビデオ')
        foreach ($b in $bigBoxes) {
            if ($targetLower -eq (Join-Path $profileDir $b).ToLowerInvariant()) {
                $denyReason = "ユーザーフォルダ直下の「$b」フォルダ全体です"
                break
            }
        }
    }
    if (-not $denyReason) {
        # 対象がユーザーフォルダ全体を含む
        if ($profileDir.ToLowerInvariant().StartsWith($targetLower + '\')) {
            $denyReason = 'ユーザーフォルダ全体を含むフォルダです'
        }
    }
}

if ($denyReason) {
    Write-Host ""
    Write-Host "[!] このフォルダは対象にできません。"
    Write-Host "    選ばれた場所: $target"
    Write-Host "    理由        : $denyReason"
    Write-Host ""
    Write-Host "    ここを作業フォルダにすると、AI が「守るべきもの」と「作業対象」を区別できなくなり、"
    Write-Host "    保護そのものが意味を失います (大事なファイルを丸ごと触れる状態になります)。"
    Write-Host ""
    Write-Host "    → 案件ごとに新しいフォルダを 1 つ作って、そこを選んでください。"
    Write-Host "       例: $profileDir\Documents\仕事\A社サイト改修"
    exit 1
}

# ---- 確認 -----------------------------------------------------------------
Write-Host "このフォルダを「AI が安全に使えるフォルダ」にします。"
Write-Host ""
Write-Host "  対象: $target"
Write-Host ""
Write-Host "入れるもの:"
Write-Host "  ・安全ルール (危険コマンドの禁止・秘密ファイルの読み取り禁止)"
Write-Host "  ・安全ガード (実行前に止める仕組み)"
Write-Host "  ・安全ランチャー (Claude / Codex / agy / OpenCode を安全な設定で起動する)"
Write-Host "  ・スタートフォルダ (番号付きのボタン) と説明書"
Write-Host "  ・このフォルダを Claude が「信頼済み」として扱う登録"
Write-Host ""
Write-Host "既にあるファイルは消しません (同名のものは控えを取ってから置き換えます)。"

$skipConfirm = $Yes -or ($env:AI_SAFE_ASSUME_YES -eq "1")
# 対話できない実行方法 (サービス・パイプ等) のときは、確認を飛ばして install を走らせるのでは
# なく中止する。確認を省きたい場合だけ -Yes か AI_SAFE_ASSUME_YES=1 を明示してもらう。
if (-not $skipConfirm -and -not [Environment]::UserInteractive) {
    Write-Host ""
    Write-Host "中止しました (確認を取れない実行方法です)。"
    Write-Host "  対話できる画面から実行するか、確認を省く場合は -Yes を付けてください。"
    exit 1
}
if (-not $skipConfirm) {
    Write-Host ""
    $ans = Read-Host "このフォルダを安全にしますか？ [y/N]"
    if ($ans -notmatch '^(y|Y|yes|YES)$') {
        Write-Host "中止しました。何も変更していません。"
        exit 0
    }
}

# ---- install 本体を通す ---------------------------------------------------
Write-Host ""
& powershell -NoProfile -ExecutionPolicy Bypass -File $installPs1 -Platform win -Workspace $target
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "うまくいきませんでした (上のメッセージを確認してください)。"
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "完了しました。このフォルダでできるようになったこと:"
Write-Host ""
Write-Host "  $target"
Write-Host ""
Write-Host "  ・「スタート」フォルダのボタンから、安全な設定のまま AI を起動できます"
Write-Host "      4_AIを起動する (メニューで Codex / Claude / OpenCode / AntiGravity を選択)"
Write-Host "  ・このフォルダの外へは書き込めません (作業対象の外を壊さない)"
Write-Host "  ・再帰削除・.env の読み取り・勝手な外部送信は止まります"
Write-Host "  ・秘密 (API キー等) が画面や送信内容に出るときは伏せ字になります"
Write-Host "  ・Claude の「このフォルダを信頼しますか？」は登録済みなので聞かれません"
Write-Host ""
Write-Host "  まずは「スタート」フォルダを開いて、「4_AIを起動する」から始めてください。"
Write-Host "------------------------------------------------------------"
