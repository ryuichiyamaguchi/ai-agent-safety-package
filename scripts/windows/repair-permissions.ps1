# repair-permissions.ps1 — %USERPROFILE%\.ai-safety のアクセス権を「本人が必ず読み書きできる」状態へ直す。
#
# ● なぜ必要か（v1.17.2 で判明した重大不具合）
#   v1.17.1 までの install.ps1 は、導入の最後に次を実行していた:
#       icacls <.ai-safety> /inheritance:r /grant:r "$env:USERDOMAIN\$env:USERNAME:(OI)(CI)F" /T
#   `/inheritance:r` は継承 ACL を全部消し、そのうえで「USERDOMAIN\USERNAME」という**文字列**に
#   フル制御を与える。ところがこの名前は環境によって解決できない:
#     ・Microsoft アカウント（表示名とローカルアカウント名が違う）
#     ・AzureAD / Entra 参加 PC（正しくは AzureAD\... で USERDOMAIN は別の値）
#     ・ドメイン参加・改名後・USERDOMAIN が期待と違う値になっている PC
#   名前の解決に失敗すると「継承は消えたが誰にも権限が付いていない」フォルダが残り、
#   **利用者本人ですら読み書きできなくなる**。実機では
#     ・gemini.dpapi が作れない（書き込み権限が無い）
#     ・deepseek.dpapi はあるのに読めない（権限が壊れる前に書かれた）
#     ・診断が「PC を替えた可能性」と誤診する（実際は権限の問題）
#   が同時に起きた。非エンジニアには自力で回復できないため、専用の修復口を用意する。
#
# ===========================================================================
#  ★ 実機（受講者の Windows）で確認した結果 — ここが本ファイルの一番大事な記録
# ===========================================================================
#  ● 成功した唯一の方法（コマンドプロンプト cmd で実行）:
#        icacls "%USERPROFILE%\.ai-safety" /reset /T /C /Q
#    実行後 `type "%USERPROFILE%\.ai-safety\deepseek.dpapi"` で暗号化された鍵が読め、
#    **回復を確認済み。鍵は無傷**だった。
#    /reset は「親フォルダから継承される既定の権限へ戻すだけ」なので、
#      ・SID の書式（* の前置）を気にしなくてよい
#      ・特権（SeSecurityPrivilege）が要らない
#      ・所有権を取り直す必要がない
#    /T = 配下も一括 / /C = エラーが出ても続行 / /Q = 成功メッセージを抑制。
#
#  ● 失敗した方法（すべて実機で確認済み。二度と同じ轍を踏まないための記録）:
#    (1) icacls ... /grant "<SID>:(OI)(CI)F"
#        → 「アカウント名とセキュリティ ID の間のマッピングは実行されませんでした」
#          icacls に SID を渡すときは **`*` の前置が必須**（`/grant "*<SID>:(OI)(CI)F"`）。
#          `*` が無いと icacls は SID 文字列を「アカウント名」として解決しようとして失敗する。
#          この一文字の落とし穴があるため、案内文では SID を使う形を受講者に出さない。
#    (2) takeown /F <path> /R /D Y
#        → **「アクセスが拒否されました」が大量発生**。そもそも不要だった。
#          所有権を変えられていないケース（install.ps1 は所有権を触っていない）では
#          所有者は WRITE_DAC を暗黙に持つので、takeown を通す必要がまったく無い。
#          しかも標準ユーザーは SeTakeOwnershipPrivilege を持たないので、
#          本当に所有権を失っている場合でも takeown は通らない。既定では絶対に呼ばない。
#    (3) Get-Acl → SetAccessRuleProtection → Set-Acl
#        → `Set-Acl : プロセスにはこの操作に必要な 'SeSecurityPrivilege' 特権が
#           与えられていません。[Set-Acl], PrivilegeNotHeldException`
#          Get-Acl / Set-Acl はセキュリティ記述子を広く取得・書き戻すため、そこに
#          **SACL（監査情報）** が含まれると SeSecurityPrivilege が要求される。
#          この特権は**フォルダの所有者であっても既定では持っていない**（管理者が
#          明示的に昇格して初めて有効になる種類の特権）。「所有者だから大丈夫」は成り立たない。
#          → **`Get-Acl` / `Set-Acl` コマンドレットは絶対に使わないこと。**
#    (4) GetAccessControl([AccessControlSections]::Access) + SetAccessControl
#        → **未検証**（(1)〜(3) の失敗のあと icacls /reset で解決したため、実機で試す前に
#          問題が消えた）。理屈のうえでは DACL だけを扱うので SeSecurityPrivilege を要求せず
#          通るはずだが、**実機で確かめられていない**。よって本スクリプトでは
#          **第一の手段にはせず、icacls /reset が使えない・効かない場合の第二の手段**に置く。
#          mac の pwsh では「型とメソッドが結線できること」だけを -SelfTest で実測している。
#
#  ● 管理者権限（UAC 昇格）は要求しない。受講者が管理者アカウントでも、昇格を求める作りは
#    「怖くて押せない」ボタンになるため避ける。SeSecurityPrivilege 無しで完結することが要件。
#
# ● この版の方針
#   1. **第一の手段は `icacls "<path>" /reset /T /C /Q`**（実機で成功した唯一の方法）。
#      親から継承される権限へ戻すだけなので、名前解決も SID の書式も特権も所有権も関係ない。
#   2. 第二の手段は **DACL だけ**を扱う .NET API
#      （GetAccessControl([AccessControlSections]::Access) / SetAccessControl）。
#      Get-Acl / Set-Acl は使わない（上の (3)）。ファイルは FileInfo、フォルダは DirectoryInfo と
#      型が違う点に注意（継承フラグもフォルダにしか意味が無い）。
#   3. takeown は**既定では呼ばない**（上の (2)）。所有権ごと失った例外的なケースのために
#      `-Takeown` を明示指定したときだけ実行する。install からも診断からも渡さない。
#   4. **継承は消さない**。`/inheritance:r` は失敗時の被害が大きすぎるうえ、%USERPROFILE% 配下は
#      既定で他の標準ユーザーから読めない。守りたいのは「別の場所から持ってきたフォルダに
#      Everyone:F のような緩い ACE が残る」形だけなので、**広すぎる付与（Everyone /
#      Authenticated Users / BUILTIN\Users / Guests / ANONYMOUS）の明示 ACE だけを外す**。
#      SYSTEM と Administrators は残す（消しても管理者は所有権を取れるので防御にならず、
#      壊れたときの回復手段だけが減る）。
#   5. 変更のたびに**本人が実際に読み書きできることを検証**し、できなければ**直前の状態へ戻す**。
#      「締めたが誰も入れない」状態のまま先へ進ませないことがこの修正の要点。
#
# ● 手順（fail-safe の順番）
#   0. まず現状を検証する。**すでに読み書きできるなら権限には一切触らない**
#      （install から呼ばれる通常ケースはここで終わる＝ install が権限を壊す余地が無い）。
#   1. 壊れているときだけ: 現在の DACL を SDDL で控える → `icacls /reset /T /C /Q`
#      → 検証（テストファイルを作る/書く/読む/消す＋既存 *.dpapi を実際に読む）
#   2. まだ駄目なら: DACL だけを扱う .NET API で継承を戻し、自分の SID にフル制御を付ける → 再検証
#   3. `-Takeown` が明示されたときだけ: 所有権を取り直して 1 と 2 をやり直す
#   4. それでも駄目なら控えへ戻し、cmd 用のコピペコマンドとエクスプローラー手順を出して終了
#   5. 通ったら、広すぎる明示 ACE だけを外す → 再検証 → 失敗したら外す前へ戻す
#
# 使い方:
#   repair-permissions.ps1                       ... %USERPROFILE%\.ai-safety を直す
#   repair-permissions.ps1 -Path <フォルダ>       ... 対象を明示する
#   repair-permissions.ps1 -Quiet -NoTakeown     ... install から呼ぶときの形（静かに・takeown なし）
#   repair-permissions.ps1 -CheckOnly            ... 直さずに現状の可否だけ見る（診断から呼ぶ）
#   repair-permissions.ps1 -Takeown              ... 所有権ごと失った例外時だけの最後の手段
#
# 終了コード: 0=アクセスできる / 1=直せなかった / 2=元に戻した（変更なし） / 3=対象が無い
param(
    [string]$Path = '',
    [string]$Workspace = '',
    [switch]$Quiet,
    # -NoTakeown は v1.17.2 以降 **既定の挙動**（takeown を呼ばない）。
    # install.ps1 / .bat が渡してくる互換のために受け付け続ける。-Takeown より強い。
    [switch]$NoTakeown,
    # 所有権ごと失っている例外的なケースだけの最後の手段。既定では絶対に走らない。
    [switch]$Takeown,
    [switch]$CheckOnly,
    [switch]$SelfTest,
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = "Continue"

function Say([string]$s) { if (-not $Quiet) { Write-Host $s } }
function SayOK([string]$s) { if (-not $Quiet) { Write-Host ("  [OK] " + $s) -ForegroundColor Green } }
function SayWarn([string]$s) { if (-not $Quiet) { Write-Host ("  [注意] " + $s) -ForegroundColor Yellow } else { Write-Warning $s } }
function SayBad([string]$s) { if (-not $Quiet) { Write-Host ("  [問題] " + $s) -ForegroundColor Red } else { Write-Warning $s } }

# 広すぎる付与（この明示 ACE だけを外す。継承 ACE と SYSTEM / Administrators は触らない）
$broadSids = @(
    'S-1-1-0',        # Everyone
    'S-1-5-11',       # Authenticated Users
    'S-1-5-7',        # ANONYMOUS LOGON
    'S-1-5-32-545',   # BUILTIN\Users
    'S-1-5-32-546'    # BUILTIN\Guests
)

$ACCESS_ONLY = [System.Security.AccessControl.AccessControlSections]::Access

# ===========================================================================
#  DACL だけを扱う層（SeSecurityPrivilege を要求しないための要 = 第二の手段）
# ===========================================================================
# ⚠️ ここは実機**未検証**の経路である（上の失敗リスト (4)）。第一の手段は icacls /reset。
# .NET Framework（Windows PowerShell 5.1）では GetAccessControl / SetAccessControl は
# FileInfo / DirectoryInfo の**インスタンスメソッド**。
# .NET Core（PowerShell 7）では System.IO.FileSystemAclExtensions の**拡張メソッド**で、
# PowerShell は C# の拡張メソッドをインスタンス呼び出しに解決しない。
# どちらの実行環境でも動くよう、両方を反射で探して呼ぶ。どちらも無い場合だけ、
# セクションを明示できるコンストラクタ（DirectorySecurity/FileSecurity(path, sections)）で読む。
# いずれの経路でも渡すセクションは Access（DACL）だけで、SACL には一切触れない。
function Get-AiSafeAclExtensionType {
    $t = [Type]::GetType('System.IO.FileSystemAclExtensions, System.IO.FileSystem.AccessControl')
    if ($null -eq $t) { $t = [Type]::GetType('System.IO.FileSystemAclExtensions') }
    return $t
}

# ファイルは FileInfo、フォルダは DirectoryInfo。型が違うと ACL のクラスも
# （FileSecurity / DirectorySecurity）変わるので、必ずここで作り分ける。
function Get-FsItem([string]$ItemPath) {
    if (Test-Path -LiteralPath $ItemPath -PathType Container) {
        return (New-Object System.IO.DirectoryInfo $ItemPath)
    }
    return (New-Object System.IO.FileInfo $ItemPath)
}

# DACL だけを取得する。Get-Acl は使わない（SACL が混ざって PrivilegeNotHeldException になる）。
function Get-DaclOnly([System.IO.FileSystemInfo]$Item) {
    $mi = $Item.GetType().GetMethod('GetAccessControl', [type[]]@([System.Security.AccessControl.AccessControlSections]))
    if ($null -ne $mi) { return $mi.Invoke($Item, @($ACCESS_ONLY)) }
    $t = Get-AiSafeAclExtensionType
    if ($null -ne $t) {
        $sm = $t.GetMethod('GetAccessControl', [type[]]@($Item.GetType(), [System.Security.AccessControl.AccessControlSections]))
        if ($null -ne $sm) { return $sm.Invoke($null, @($Item, $ACCESS_ONLY)) }
    }
    if ($Item -is [System.IO.DirectoryInfo]) {
        return (New-Object System.Security.AccessControl.DirectorySecurity($Item.FullName, $ACCESS_ONLY))
    }
    return (New-Object System.Security.AccessControl.FileSecurity($Item.FullName, $ACCESS_ONLY))
}

# DACL だけを書き戻す。Set-Acl は使わない（同上）。
# ObjectSecurity は「変更されたセクション」だけを永続化するため、Access しか触っていない
# オブジェクトを渡せば DACL だけが書かれ、SeSecurityPrivilege は要求されない。
function Set-DaclOnly([System.IO.FileSystemInfo]$Item, [object]$Acl) {
    $mi = $Item.GetType().GetMethod('SetAccessControl', [type[]]@($Acl.GetType()))
    if ($null -ne $mi) { [void]$mi.Invoke($Item, @($Acl)); return }
    $t = Get-AiSafeAclExtensionType
    if ($null -ne $t) {
        $sm = $t.GetMethod('SetAccessControl', [type[]]@($Item.GetType(), $Acl.GetType()))
        if ($null -ne $sm) { [void]$sm.Invoke($null, @($Item, $Acl)); return }
    }
    throw "この PowerShell ではアクセス権の書き戻し方法が見つかりませんでした（SetAccessControl が使えません）。"
}

# 反射越しの例外は TargetInvocationException に包まれる。利用者に見せるのは中身の方。
function Get-InnerMessage($ErrorRecord) {
    $ex = $ErrorRecord.Exception
    while ($null -ne $ex.InnerException) { $ex = $ex.InnerException }
    $msg = [string]$ex.Message
    if ($ex -is [System.Security.AccessControl.PrivilegeNotHeldException] -or $msg -match 'SeSecurityPrivilege') {
        $msg += "（監査情報 SACL を触ろうとしています。このスクリプトは DACL だけを扱う実装なので、" +
                "ここに出た場合は実装のバグです。この画面をそのまま講師に送ってください）"
    }
    return $msg
}

# 控え（巻き戻し用）も Access セクションだけを SDDL 文字列で保存する。
# オブジェクトをそのまま持ち回すと「変更済み」フラグが立たず書き戻しが無視されるため、
# 復元時は SetSecurityDescriptorSddlForm(..., Access) で明示的に Access だけを差し戻す。
function Get-DaclSddl([System.IO.FileSystemInfo]$Item) {
    try { return (Get-DaclOnly $Item).GetSecurityDescriptorSddlForm($ACCESS_ONLY) } catch { return $null }
}

function Restore-Dacl([System.IO.FileSystemInfo]$Item, [string]$Sddl) {
    if ([string]::IsNullOrWhiteSpace($Sddl)) { return $false }
    try {
        $acl = Get-DaclOnly $Item
        $acl.SetSecurityDescriptorSddlForm($Sddl, $ACCESS_ONLY)
        Set-DaclOnly $Item $acl
        return $true
    } catch {
        return $false
    }
}

# ---- 受講者に見せる回復手順（実機で成功が確認された形だけを出す） -----------
# ⚠️ ここに **PowerShell の 2 行**（$sid を取って icacls /grant "*$sid:..."）を書かないこと。
#    実機では `/grant "<SID>:..."` が「アカウント名とセキュリティ ID の間のマッピングは
#    実行されませんでした」で失敗した（* の前置漏れが起きやすい）。/reset なら SID が要らない。
# ⚠️ **cmd（コマンドプロンプト）で実行**と必ず明記すること。PowerShell では
#    `%USERPROFILE%` が展開されず、そのままの文字列としてフォルダを探しに行って失敗する。
function Show-RecoveryHint {
    Say ""
    Say "  ● 直し方 (A) コマンドプロンプト（cmd）を開いて、次の 1 行をそのまま貼り付けて実行:"
    Say ""
    Say '        icacls "%USERPROFILE%\.ai-safety" /reset /T /C /Q'
    Say ""
    Say "     ※ 必ず「コマンドプロンプト（cmd）」で実行してください。"
    Say "        PowerShell では %USERPROFILE% が展開されないため、この行は動きません。"
    Say "     ※ 管理者として実行する必要はありません。"
    Say ""
    Say "  ● 直し方 (B) エクスプローラーだけで直す（コマンドが苦手な方向け）:"
    Say "        1. エクスプローラーのアドレス欄に %USERPROFILE% と入れて開く"
    Say "        2. .ai-safety を右クリック → プロパティ"
    Say "        3. セキュリティ タブ → 詳細設定"
    Say "        4. 「継承の有効化」を押す"
    Say "        5. 「子オブジェクトのアクセス許可エントリすべてを、このオブジェクトからの"
    Say "           継承可能なアクセス許可エントリで置き換える」にチェック"
    Say "        6. OK で閉じる"
    Say ""
    Say "  ● どちらも金庫の中身（API キー）は消しません。キーの作り直しは不要です。"
    Say ""
}

# ---- -SelfTest: この PowerShell で第二の手段（DACL 層）が本当に呼べるかを確かめる ----
# mac の開発機では Windows の ACL を実際に操作できない。だが .NET の型と
# メソッド解決は mac の pwsh でも同じように行われるので、「DACL だけを扱う層が
# この実行環境で結線できるか」だけは実測できる。構文検査より一段深い確認として、
# 回帰テスト (scripts/common/test/acl-permissions.test.js) がこのモードを呼ぶ。
#
# ⚠️ ここが 2 系統ある理由（実測で確認済み）:
#   Windows PowerShell 5.1 (.NET Framework) … FileInfo/DirectoryInfo の**インスタンスメソッド**
#   PowerShell 7 (.NET Core)                … FileSystemAclExtensions の**拡張メソッド**
#   PowerShell は C# の拡張メソッドをインスタンス呼び出しに解決しないため、
#   `$di.GetAccessControl(...)` と書くと PowerShell 7 では
#   「メソッド 'GetAccessControl' が見つかりません」で落ちる。だから反射で両方を探す。
if ($SelfTest) {
    $ng = 0
    function Probe([string]$Name, [bool]$Ok) {
        if ($Ok) { SayOK ($Name + ": 呼べます") } else { SayBad ($Name + ": 呼べません"); $script:ng++ }
    }
    Probe "AccessControlSections::Access" ($null -ne $ACCESS_ONLY)
    foreach ($pair in @(
        @{ T = [System.IO.DirectoryInfo]; S = [System.Security.AccessControl.DirectorySecurity]; N = 'DirectoryInfo' },
        @{ T = [System.IO.FileInfo];      S = [System.Security.AccessControl.FileSecurity];      N = 'FileInfo' }
    )) {
        $ext = Get-AiSafeAclExtensionType
        $getOk = ($null -ne $pair.T.GetMethod('GetAccessControl', [type[]]@([System.Security.AccessControl.AccessControlSections])))
        if (-not $getOk -and $null -ne $ext) {
            $getOk = ($null -ne $ext.GetMethod('GetAccessControl', [type[]]@($pair.T, [System.Security.AccessControl.AccessControlSections])))
        }
        if (-not $getOk) {
            $getOk = ($null -ne $pair.S.GetConstructor([type[]]@([string], [System.Security.AccessControl.AccessControlSections])))
        }
        Probe ($pair.N + ".GetAccessControl(Access のみ)") $getOk

        $setOk = ($null -ne $pair.T.GetMethod('SetAccessControl', [type[]]@($pair.S)))
        if (-not $setOk -and $null -ne $ext) {
            $setOk = ($null -ne $ext.GetMethod('SetAccessControl', [type[]]@($pair.T, $pair.S)))
        }
        Probe ($pair.N + ".SetAccessControl") $setOk

        Probe ($pair.N + " の SDDL 取得(Access のみ)") ($null -ne $pair.S.GetMethod('GetSecurityDescriptorSddlForm', [type[]]@([System.Security.AccessControl.AccessControlSections])))
        Probe ($pair.N + " の SDDL 復元(Access のみ)") ($null -ne $pair.S.GetMethod('SetSecurityDescriptorSddlForm', [type[]]@([string], [System.Security.AccessControl.AccessControlSections])))
    }
    Probe "FileSystemAccessRule(SID, 権限, 継承, 伝播, 許可)" ($null -ne [System.Security.AccessControl.FileSystemAccessRule].GetConstructor([type[]]@(
        [System.Security.Principal.IdentityReference],
        [System.Security.AccessControl.FileSystemRights],
        [System.Security.AccessControl.InheritanceFlags],
        [System.Security.AccessControl.PropagationFlags],
        [System.Security.AccessControl.AccessControlType])))
    if ($ng -eq 0) { Say "DACL 層はこの PowerShell で結線できます（SACL には触りません）。"; exit 0 }
    SayBad ("結線できない項目が " + $ng + " 件あります。この PowerShell ではアクセス権を直せません。")
    exit 1
}

# mac / Linux の PowerShell では ACL の概念が無い。何もせず正常終了する
# （install.sh 側は chmod 700/600 とその検証で同じ役目を果たす）。
if ($IsWindows -eq $false) {
    Say "Windows ではないため、アクセス権の修復は不要です（mac は chmod 700/600 側で担保）。"
    exit 0
}


$up = $env:USERPROFILE
if (-not $up) { $up = $HOME }
if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Join-Path $up ".ai-safety" }

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Say ("対象のフォルダがありません（まだ作られていないだけの可能性が高い）: " + $Path)
    exit 3
}

# ---- 現在のユーザーの SID（第二の手段でだけ使う） ---------------------------
# 文字列 "$env:USERDOMAIN\$env:USERNAME" は環境によって解決できない。SID は必ず一致する。
# ただし **icacls に SID を渡すときは `*` の前置が要る**（実機で確認した失敗 (1)）。
# 本スクリプトは icacls には SID を渡さない（/reset しか使わない）ので、この落とし穴を踏まない。
$meSid = $null
try {
    $meSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
} catch {
    SayBad ("現在のユーザーの SID を取得できませんでした: " + $_.Exception.Message)
    exit 1
}
$meName = ''
try { $meName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $meName = '' }
Say ("対象: " + $Path)
Say ("あなた: " + $meName + "  (SID: " + $meSid.Value + ")")

$sw = [System.Diagnostics.Stopwatch]::StartNew()
function Test-Deadline { return ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) }

# ---- 検証: 本人が実際に読み書きできるか ------------------------------------
# 権限は「付けたつもり」では意味が無い。テストファイルを作って書いて読んで消し、
# さらに既存の金庫ファイルを実際に読めるところまで見る。
function Test-SelfAccess([string]$Dir) {
    $probe = Join-Path $Dir (".perm-check-" + [guid]::NewGuid().ToString('N') + ".tmp")
    $ok = $false
    try {
        $token = [guid]::NewGuid().ToString('N')
        [System.IO.File]::WriteAllText($probe, $token)
        $back = [System.IO.File]::ReadAllText($probe)
        $null = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction Stop | Select-Object -First 1)
        $ok = ($back -eq $token)
    } catch {
        $ok = $false
    }
    try { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } } catch { }
    return $ok
}

# 既存ファイル（とくに *.dpapi = 金庫）が実際に読めるか。フォルダに入れても
# ファイル単位で権限が壊れている形を、これで捕まえる。
function Test-ExistingFilesReadable([string]$Dir) {
    $unreadable = @()
    try {
        $files = @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction Stop |
                   Where-Object { $_.Name -like '*.dpapi' -or $_.Name -like '*.txt' -or $_.Name -like '*.key' })
    } catch {
        return @('(一覧を取得できません) ' + $Dir)
    }
    foreach ($f in $files) {
        try { $null = [System.IO.File]::ReadAllBytes($f.FullName) }
        catch { $unreadable += $f.FullName }
    }
    return $unreadable
}

function Test-AllAccess([string]$Dir) {
    if (-not (Test-SelfAccess $Dir)) { return $false }
    $bad = @(Test-ExistingFilesReadable $Dir)
    return ($bad.Count -eq 0)
}

# ---- 現状確認だけ（診断から呼ぶ形） ----------------------------------------
if ($CheckOnly) {
    if (Test-AllAccess $Path) {
        SayOK ("アクセスできます: " + $Path)
        exit 0
    }
    SayBad ("あなた自身がこのフォルダを読み書きできません: " + $Path)
    Show-RecoveryHint
    exit 1
}

# ===========================================================================
#  第一の手段: icacls /reset （実機で成功が確認された唯一の方法）
# ===========================================================================
# 「親フォルダから継承される既定の権限へ戻す」だけの操作。明示 ACE を消して継承を復活させる。
#   /T = 配下も一括 / /C = 途中でエラーが出ても続行 / /Q = 成功メッセージを抑制
# 名前解決・SID の書式・SeSecurityPrivilege・所有権のいずれにも依存しない。
# 出力は日本語 Windows ではロケール依存なので**解析しない**。成否は必ず検証側で判定する
# （/C を付けている以上、終了コードも「全部成功した」の意味にならない）。
function Invoke-IcaclsReset([int]$TimeoutMs) {
    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("icacls-reset-" + [guid]::NewGuid().ToString('N') + ".log")
    $errFile = $outFile + '.err'
    try {
        $p = Start-Process -FilePath "icacls.exe" `
                           -ArgumentList @(('"' + $Path + '"'), '/reset', '/T', '/C', '/Q') `
                           -NoNewWindow -PassThru `
                           -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            SayWarn "アクセス権の初期化（icacls /reset）が時間内に終わりませんでした。中断しました。"
            return $false
        }
        return $true
    } catch {
        SayWarn ("アクセス権の初期化（icacls /reset）を実行できませんでした: " + $_.Exception.Message)
        return $false
    } finally {
        foreach ($f in @($outFile, $errFile)) {
            try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch { }
        }
    }
}

# ===========================================================================
#  第二の手段: DACL だけを扱う .NET API（実機未検証。icacls が使えないときの保険）
# ===========================================================================
function Invoke-GrantSelf([System.IO.FileSystemInfo]$RootItem) {
    $acl = $null
    try {
        $acl = Get-DaclOnly $RootItem
    } catch {
        SayBad ("アクセス権の情報を読めませんでした: " + (Get-InnerMessage $_))
        return $false
    }
    try {
        # 第 1 引数 $false = 継承を保護しない（＝継承を復活させる）
        # 第 2 引数 $true  = いま明示されている ACE はそのまま残す
        $acl.SetAccessRuleProtection($false, $true)
        # 継承フラグはフォルダにだけ意味がある。ファイルには None を渡すこと。
        $inherit = [System.Security.AccessControl.InheritanceFlags]::None
        if ($RootItem -is [System.IO.DirectoryInfo]) {
            $inherit = ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit)
        }
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $meSid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
        Set-DaclOnly $RootItem $acl
        return $true
    } catch {
        SayBad ("アクセス権を付け直せませんでした: " + (Get-InnerMessage $_))
        return $false
    }
}

# 配下の「継承を切られた」ファイル/フォルダを継承へ戻す（旧 install の /T の後始末）。
# icacls /reset /T が通っていればここは何も直さない（保険としてだけ走る）。
function Repair-Children([string]$Root) {
    $fixed = 0
    $skipped = 0
    $errors = @()
    $hitDeadline = $false
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        if (Test-Deadline) { $hitDeadline = $true; break }
        $dir = [string]$queue.Dequeue()
        $entries = @()
        try { $entries = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop) } catch { $skipped++; continue }
        foreach ($entry in $entries) {
            if (Test-Deadline) { $hitDeadline = $true; break }
            # 接合点・シンボリックリンクの先は追わない（別の場所の権限を巻き添えにしないため）。
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            try {
                $cAcl = Get-DaclOnly $entry
                if ($cAcl.AreAccessRulesProtected) {
                    # $false, $false = 継承を復活させ、継承から複製された明示 ACE は捨てる
                    # （旧 install が付けた「解決できない名前」の孤立 ACE もここで消える）。
                    $cAcl.SetAccessRuleProtection($false, $false)
                    Set-DaclOnly $entry $cAcl
                    $fixed++
                }
            } catch {
                $skipped++
                if ($errors.Count -lt 3) { $errors += ($entry.FullName + ": " + (Get-InnerMessage $_)) }
            }
            if ($entry.PSIsContainer) { $queue.Enqueue($entry.FullName) }
        }
    }
    return [pscustomobject]@{ Fixed = $fixed; Skipped = $skipped; Errors = $errors; HitDeadline = $hitDeadline }
}

# ---- 最後の手段の準備: 所有権を取り戻す ------------------------------------
# ⚠️ 実機では `takeown /F <path> /R /D Y` は **「アクセスが拒否されました」が大量発生**し、
#    しかも不要だった（icacls /reset だけで直った）。既定では絶対に呼ばない。
#    所有権ごと失った例外的なケースのために -Takeown を明示したときだけ走る。
function Invoke-Takeown([int]$TimeoutMs) {
    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("takeown-" + [guid]::NewGuid().ToString('N') + ".log")
    try {
        $p = Start-Process -FilePath "takeown.exe" `
                           -ArgumentList @('/F', ('"' + $Path + '"'), '/R', '/D', 'Y') `
                           -NoNewWindow -PassThru `
                           -RedirectStandardOutput $outFile -RedirectStandardError ($outFile + '.err')
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            SayWarn "所有権の取り直し（takeown）が時間内に終わりませんでした。中断しました。"
            return $false
        }
        return ($p.ExitCode -eq 0)
    } catch {
        SayWarn ("所有権の取り直し（takeown）を実行できませんでした: " + $_.Exception.Message)
        return $false
    } finally {
        foreach ($f in @($outFile, ($outFile + '.err'))) {
            try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch { }
        }
    }
}

# ===========================================================================
#  本編
# ===========================================================================
$rootItem = Get-FsItem $Path

Say ""
Say "1) いまの状態を確かめます（テストファイルの読み書き＋既存の金庫ファイルの読み取り）..."
$accessOk = Test-AllAccess $Path

if ($accessOk) {
    # ★ 壊れていないときは権限に**一切触らない**。
    #    install.ps1 から呼ばれる通常ケースはここで終わるので、
    #    「導入が権限を壊す」経路そのものが存在しない。
    SayOK "すでにあなた自身が読み書きできます。アクセス権には触りません。"
} else {
    SayBad "あなた自身がこのフォルダを読み書きできません。修復します。"

    # 控えを取る（戻せるようにしてから触る）。読めない状態なら控えは取れない＝巻き戻し不可。
    # ただし以降の操作は「継承を復活させて緩める」方向しか行わないので、
    # 巻き戻せないこと自体が受講者の不利益にはならない。
    $beforeSddl = Get-DaclSddl $rootItem
    if ($null -eq $beforeSddl) {
        SayWarn "変更前のアクセス権を控えられませんでした（読めない状態のため）。巻き戻しは継承の復活で代替します。"
    }

    Say ""
    Say "2) アクセス権を初期化します（icacls /reset。親フォルダから継承される権限へ戻します）..."
    if (Invoke-IcaclsReset 60000) {
        $accessOk = Test-AllAccess $Path
        if ($accessOk) { SayOK "初期化で回復しました。" } else { SayWarn "初期化だけでは回復しませんでした。" }
    }

    if (-not $accessOk) {
        Say ""
        Say "3) 別の方法で、あなた自身にフル制御を付け直します（付与先は名前ではなく SID / 対象は DACL だけ）..."
        if (Invoke-GrantSelf $rootItem) { $accessOk = Test-AllAccess $Path }
    }

    # -Takeown を明示したときだけの最後の手段。既定では走らない。
    if (-not $accessOk -and $Takeown -and -not $NoTakeown) {
        SayWarn "まだ読み書きできません。所有権を取り戻してからもう一度試します（-Takeown 指定時のみ）..."
        if (Invoke-Takeown 60000) {
            if (Invoke-IcaclsReset 60000) { $accessOk = Test-AllAccess $Path }
            if (-not $accessOk -and (Invoke-GrantSelf $rootItem)) { $accessOk = Test-AllAccess $Path }
        }
    }

    if (-not $accessOk) {
        SayBad "アクセス権を直せませんでした。安全のため、変更前の状態へ戻します。"
        $restored = Restore-Dacl $rootItem $beforeSddl
        if ($restored) { Say "  変更前の状態へ戻しました（何も変わっていません）。" }
        else { SayWarn "  変更前の状態へ戻せませんでした。この画面をそのまま講師に送ってください。" }
        Show-RecoveryHint
        exit 1
    }
    SayOK "あなた自身が読み書きできることを確認しました。"

    # 配下の後始末（icacls /reset /T が通っていれば何も残らない）。
    Say ""
    Say "4) フォルダの中身（ログ・金庫ファイル）に取り残しがないか確認します..."
    $childResult = Repair-Children $Path
    if ($childResult.HitDeadline) {
        SayWarn ("時間切れのため途中で止めました（" + $TimeoutSeconds + " 秒）。もう一度実行すると続きから直せます。")
    }
    Say ("   直した項目: " + $childResult.Fixed + " / さわれなかった項目: " + $childResult.Skipped)
    # 失敗は握り潰さない。何が足りなかったのかを日本語で必ず出す。
    foreach ($e in $childResult.Errors) { SayWarn ("   さわれなかった理由の例: " + $e) }
}

# ---- 広すぎる明示 ACE だけを外す（ここだけが「締める」操作） ----------------
# icacls /reset が通っていれば明示 ACE 自体が残っていないので、通常はここで何もしない。
# 別の場所からコピーしてきたフォルダに Everyone:F などが残っている形だけを外す。
Say ""
Say "5) 他の人に開きすぎている設定があれば外します..."
$safeSddl = Get-DaclSddl $rootItem
$removed = @()
try {
    $acl = Get-DaclOnly $rootItem
    foreach ($ace in @($acl.Access)) {
        if ($ace.IsInherited) { continue }
        if ($ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        $aceSid = $null
        try { $aceSid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $aceSid = $null }
        if ($null -ne $aceSid -and ($broadSids -contains $aceSid)) {
            if ($acl.RemoveAccessRuleSpecific($ace)) { $removed += ([string]$ace.IdentityReference) }
        }
    }
    if ($removed.Count -gt 0) {
        Set-DaclOnly $rootItem $acl
        if (Test-AllAccess $Path) {
            SayOK ("他の人向けの開きすぎた設定を外しました: " + ($removed -join ', '))
        } else {
            SayWarn "外したあとで読み書きできなくなったため、外す前の状態へ戻しました。"
            if (-not (Restore-Dacl $rootItem $safeSddl)) {
                SayBad "戻せませんでした。この画面をそのまま講師に送ってください。"
                Show-RecoveryHint
                exit 1
            }
        }
    } else {
        SayOK "開きすぎた設定はありませんでした。"
    }
} catch {
    SayWarn ("開きすぎた設定の整理に失敗しました（アクセスの可否には影響しません）: " + (Get-InnerMessage $_))
    $null = Restore-Dacl $rootItem $safeSddl
}

# ---- 最終確認 --------------------------------------------------------------
Say ""
if (Test-AllAccess $Path) {
    SayOK ("完了しました。あなた自身がこのフォルダを読み書きできます: " + $Path)
    $stillBad = @(Test-ExistingFilesReadable $Path)
    if ($stillBad.Count -gt 0) {
        SayWarn ("ただし次のファイルはまだ読めません: " + ($stillBad -join ', '))
    }
    exit 0
}
SayBad "最終確認で読み書きできませんでした。外す前の状態へ戻します。"
$null = Restore-Dacl $rootItem $safeSddl
Show-RecoveryHint
exit 2
