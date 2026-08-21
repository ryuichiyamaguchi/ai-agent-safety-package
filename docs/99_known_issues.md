# 既知の問題

本パッケージで把握している既知の問題と回避策。

## d-claude で「選択したモデルに問題があります（deepseek-v4-flash）」と出る（原因は**モデル名ではない**）

**症状**:

```
There's an issue with the selected model (deepseek-v4-flash).
It may not exist or you may not have access to it. Run /model to pick a different model.
```

**このメッセージの本当の意味**（2026-08-21・mac 実機で Claude Code 2.1.236 を実走して確定）:

- Claude Code は **`POST /v1/messages` が HTTP 404 を返したときだけ** この文言を出します。本文の形は問いません（Anthropic 形式のエラーでも `{"error":"Not Found"}` でも同じ）。
- **401 では出ません。** `/v1/models` を 404 にしても、モデル一覧に別の ID しか無くても出ません。まっさらな設定で起動した Claude Code は `/v1/models` を**そもそも叩きません**（実測: 起動時に飛ぶのは `HEAD /api/hello` と `POST /v1/messages?beta=true` だけ）。
- つまりこれは「モデル名が間違っている」ではなく「**送り先が 404 を返した**」の意味です。`deepseek-v4-flash` は正しい ID で、DeepSeek の Anthropic 互換エンドポイントは 200 を返します（実キーで実測。`deepseek-v4-pro` も 200）。

**確かめ方（切り分けの順番）**:

1. 送信検査 Gateway のイベントログを見る: `~/.ai-safety/logs/ds-gateway-events.jsonl`（Windows は `%USERPROFILE%\.ai-safety\logs\`）。
   上流が 4xx/5xx を返していれば `{"event":"upstream_error","status":404,...}` の行が残ります（v1.17.3〜）。
   - **`upstream_error` の行がある** → 送り先（DeepSeek）が 404 を返しています。行の `path` と `body` が実際の理由です。
   - **`upstream_error` の行が 1 本も無い** → その 404 は Gateway を通っていません。Claude Code が **Gateway ではない別の宛先**（本家 `api.anthropic.com` など）へ送っています。`ANTHROPIC_BASE_URL` が `http://127.0.0.1:<ポート>` になっているか、古い Gateway がポートを掴んでいないかを確認してください。
2. 古い Gateway が残っている疑いがあるときは、上の「更新後、Windows で〜」の回復方法（再起動、または 8788 番の taskkill）と同じ手順で止めてから起動し直します。

**v1.17.3 で入れたもの**: ds-gateway が上流の 4xx/5xx を必ず `upstream_error` としてログに残し、404 のときは「Claude Code はこれをモデルの問題として表示しますが、実際は送り先が 404 を返しています」と画面にも出すようにしました。**現象そのものを直す修正ではありません**（パッケージ側のコードは mac 実機・実キーで端から端まで 200 で通ることを確認済み）。受講者の環境で再発したときに、原因が 1 分で切り分けられるようにするための変更です。

## ★重大: 更新後、Windows で OpenCode / d-claude が起動しなくなる（v1.17.3・v1.17.3 で修正）

**症状**（受講者の Windows 実機で確認）:

「OpenCode を安全に起動」または「d-claude を安全に起動」を押すと、黒い画面に次が出て止まる。

```
node.exe : gateway-token: not reusable (fingerprint-mismatch)
発生場所 C:\Users\<名前>\Documents\my-ai-workspace\.ai-safety\hooks\windows\opencode\launch-opencode-deepseek.ps1:158 文字:5
+     & $NodePath $GatewayTokenJs '--probe' '--gateway' $GatewayJs '--p ...
    + CategoryInfo          : NotSpecified: (gateway-token: ...print-mismatch):String) [], RemoteException
    + FullyQualifiedErrorId : NativeCommandError
問題が起きました。
```

**誰が当たるか**: **v1.17.3 に更新する前から送信検査 Gateway が動いていた Windows の人全員**。
更新前に一度も起動していない、またはパソコンを再起動した直後なら症状は出ません。

**原因**: 更新で送信検査 Gateway（`ds-gateway.js`）の中身が変わったため、動いたままの古い Gateway が
「中身が古いので使い回さない」と判定されました。**ここまでは正常な動き**で、本来は古いほうを止めて
新しく立て直すだけです。ところがその判定理由が「エラー扱いの出力」になっており、Windows に標準で入っている
PowerShell 5.1 はそれを本物のエラーに変換してしまうため、起動そのものが止まっていました。

**あなたのデータ・APIキー・設定は何も壊れていません。**

### 回復方法（受講者向け・どちらか 1 つ）

1. **パソコンを再起動する**（いちばん簡単・確実）
2. 古い Gateway だけを止める。**コマンドプロンプト（cmd）** を開いて、次の 1 行をそのまま貼り付けて実行する:

```
for /f "tokens=5" %a in ('netstat -ano ^| findstr :8788 ^| findstr LISTENING') do taskkill /F /PID %a
```

> ※ PowerShell ではなく **コマンドプロンプト（cmd）** で実行してください。書き方が違うため、
> PowerShell に貼ると動きません。「該当のプロセスが見つかりません」と出た場合は、
> すでに止まっているので、そのまま起動し直して大丈夫です。

そのあと、いつもどおり「OpenCode を安全に起動」または「d-claude を安全に起動」を押してください。

### v1.17.3 での修正

- ランチャー側: 外部コマンド（node / opencode / codex など）の呼び出しを `Invoke-NativeQuiet` に統一し、
  **成否は必ず終了コードで判定する**ようにした。情報メッセージが 1 行出ただけで止まることはなくなる。
  同じ書き方が残っていた他のランチャー・診断・隔離ドリルも横断で直した
- `gateway-token.js` 側: 「使い回せない」は正常系なので**何も出力せず終了コードだけで表す**ようにした
  （理由を見たいときは `--probe --verbose`）。本当の異常はこれまでどおりエラー出力に出し、起動を止める
- 更新直後に古い Gateway が 8788 番を掴んだまま残らないよう、記録されたポートは立て直しの前に必ず止める
- 回帰テスト（`scripts/common/test/windows-native-stderr.test.js`）で、危険な書き方が再び入らないよう機械的に固定した

## ★重大: Windows で自分の `.ai-safety` フォルダに入れなくなる（v1.17.3 以前・v1.17.3 で修正）

**症状**（受講者の Windows 実機で確認）:

- 「10_困ったとき診断」に `Get-Content : パス 'C:\Users\<名前>\.ai-safety\deepseek.dpapi' へのアクセスが拒否されました。`
  （`UnauthorizedAccessException`）が出る
- 診断が **「金庫のファイルを復号できません（PC を替えた／Windows を入れ直した可能性）→ キーを作り直して登録し直してください」** と表示する
- AIコーチ（Gemini）のキーが金庫に入らず、平文のキーファイルだけが残る
- 「金庫への書き込みに失敗した記録はありません」と出るのに、金庫が作られていない

**原因**: v1.17.3 までの `scripts/windows/install.ps1` は、導入の最後に次を実行していました。

```
icacls "%USERPROFILE%\.ai-safety" /inheritance:r /grant:r "%USERDOMAIN%\%USERNAME%:(OI)(CI)F" /T
```

`/inheritance:r` は**継承 ACL を全部消し**、そのうえで `USERDOMAIN\USERNAME` という**文字列**に権限を与えます。
ところがこの名前は環境によって解決できません。

- Microsoft アカウント（表示名とローカルアカウント名が違う）
- AzureAD / Entra 参加 PC（正しくは `AzureAD\...` で `USERDOMAIN` は別の値）
- ドメイン参加・アカウント改名後・`USERDOMAIN` が期待と違う値になっている PC

名前の解決に失敗すると **「継承は消えたが、誰も権限を持たないフォルダ」** が残り、**利用者本人ですら
読み書きできなくなります**。上の症状はすべてこれ 1 つで説明できます（金庫を新しく作れない ＝ 書き込み不可、
既存の金庫が読めない ＝ 権限が壊れる前に書かれていた、診断の誤診 ＝ アクセス拒否を復号失敗と取り違えていた）。

**金庫の中身は消えていません。キーの作り直しは不要です。**

### 回復方法（受講者向け・どれか 1 つ）★実機で成功を確認済み

1. **「スタート」フォルダの `14_フォルダのアクセス権を直す` を実行する**（おすすめ・ボタン 1 つ）
2. **コマンドプロンプト（cmd）** を開いて、次の 1 行をそのまま貼り付けて実行する:

```
icacls "%USERPROFILE%\.ai-safety" /reset /T /C /Q
```

> **必ず「コマンドプロンプト（cmd）」で実行してください。**
> PowerShell では `%USERPROFILE%` が展開されないため、この行は動きません。
> **管理者として実行する必要はありません。**
>
> `/reset` は「親フォルダから継承される既定の権限へ戻す」だけの操作です。だから
> SID の書き方も、特権も、所有権も関係ありません。`/T` で配下も一括、`/C` はエラーが出ても続行、
> `/Q` は成功メッセージの抑制です。
>
> 実行後に `type "%USERPROFILE%\.ai-safety\deepseek.dpapi"` を実行して、
> 暗号化された文字列が表示されれば回復しています（**鍵は無傷です**）。

3. **エクスプローラーだけで直す**（コマンドが苦手な方向け・上と同じことをします）:

   `%USERPROFILE%` を開く → `.ai-safety` を右クリック → プロパティ → セキュリティ → 詳細設定
   → 「継承の有効化」→「子オブジェクトのアクセス許可エントリすべてを、このオブジェクトからの
   継承可能なアクセス許可エントリで置き換える」にチェック → OK

### ★実機で失敗した方法（同じ轍を踏まないための記録・案内に書き戻さないこと）

受講者の Windows 実機で次を順に試し、**すべて失敗**しました。上の `/reset` だけが通りました。

| 試した方法 | 実機での結果 |
|---|---|
| `icacls ... /grant "<SID>:(OI)(CI)F"` | `アカウント名とセキュリティ ID の間のマッピングは実行されませんでした`。**icacls に SID を渡すには `*` の前置が必須**（`/grant "*<SID>:..."`）。この一文字を落としやすいので、受講者向けの案内では SID を使う形を出さない |
| `takeown /F ... /R /D Y` | **「アクセスが拒否されました」が大量発生**。そもそも不要だった（install は所有権を触っていないので、所有者は WRITE_DAC を暗黙に持つ。標準ユーザーは SeTakeOwnershipPrivilege を持たないので、本当に所有権を失っていても通らない） |
| `Get-Acl` → `SetAccessRuleProtection` → `Set-Acl` | `SeSecurityPrivilege` 特権が無く `PrivilegeNotHeldException`（次節） |
| `GetAccessControl([AccessControlSections]::Access)` + `SetAccessControl` | **未検証**。`/reset` で解決したため実機で試す前に問題が消えた。理屈上は DACL だけを扱うので通るはずだが確認できていない |

### 2 度目の失敗: `Set-Acl` は標準ユーザーでは動かない（SeSecurityPrivilege）

最初の修正は `Get-Acl` → `SetAccessRuleProtection` → `Set-Acl` という素直な実装でしたが、
受講者の Windows 実機で次のエラーになり、**修復処理そのものが動きませんでした**。

```
Set-Acl : プロセスにはこの操作に必要な 'SeSecurityPrivilege' 特権が与えられていません。
    + CategoryInfo          : PermissionDenied: (...) [Set-Acl], PrivilegeNotHeldException
```

原因は、`Get-Acl` / `Set-Acl` コマンドレットがセキュリティ記述子を広く取得・書き戻すため、
そこに **SACL（監査情報）** が含まれると **`SeSecurityPrivilege` 特権**が要求されることです。
この特権は **フォルダの所有者であっても既定では持っていません**（管理者が明示的に昇格して初めて有効になる種類の特権）。
つまり「所有者だから大丈夫」は成り立ちません。

**この経路は第一の手段からは外し、`icacls /reset` のフォールバック（第二の手段）にしました。**
第一の手段が実機で成功した `icacls /reset` である以上、`Get-Acl`/`Set-Acl` へ戻る理由はどこにもありません。
第二の手段でも SACL には一切触れず、DACL（アクセス権）だけを明示して扱います。

- 取得: `GetAccessControl([AccessControlSections]::Access)`
- 書き戻し: `SetAccessControl(...)`（Access セクションしか変更していないので DACL だけが書かれる）
- 控え・復元も Access セクションだけを SDDL 文字列でやり取りする
- **`Get-Acl` / `Set-Acl` コマンドレットは使いません**（使った瞬間に SACL が混ざって同じエラーに戻る）
- **管理者権限（UAC 昇格）は要求しません。** SeSecurityPrivilege 無しで完結することが要件です

なお、`GetAccessControl` / `SetAccessControl` の提供形態は実行環境で違います。

| 実行環境 | 提供形態 |
|---|---|
| Windows PowerShell 5.1（.NET Framework） | `FileInfo` / `DirectoryInfo` の**インスタンスメソッド** |
| PowerShell 7（.NET Core） | `System.IO.FileSystemAclExtensions` の**拡張メソッド** |

PowerShell は C# の拡張メソッドをインスタンス呼び出しに解決しないため、`$di.GetAccessControl(...)` と
書くと **PowerShell 7 では「メソッドが見つかりません」で落ちます**（mac の pwsh 7 で実測確認済み）。
そのため実装は両方を反射で探します。`repair-permissions.ps1 -SelfTest` を実行すると、
その PowerShell で DACL 層が結線できるかを確認できます。

**同じ誤りが他に 2 箇所ありました**（今回あわせて修正）。

| 箇所 | 内容 |
|---|---|
| `install.ps1` の mac フック読み取り専用化 | `Get-Acl`/`Set-Acl` ＋ 名前ベースの付与。しかも `try/catch` が無く `$ErrorActionPreference = "Stop"` なので、失敗すると**導入全体が途中で止まる**（`-Platform mac`/`both` のときのみ実行される経路） |
| `lib/SafetyPolicy.ps1` の `Set-AuditLogAcl` | 監査ログを本人だけに絞る処理。`Get-Acl`/`Set-Acl` ＋ 名前ベース ＋ 継承ルールの全削除。実機では毎回 `PrivilegeNotHeldException` で失敗しており、**この絞り込みは一度も効いていなかった**うえ、フックが動くたびに警告を出していた |

### v1.17.3 での修正

- **修復の第一の手段を `icacls "<フォルダ>" /reset /T /C /Q` にしました**（実機で成功が確認された唯一の方法）。
  親フォルダから継承される既定の権限へ戻すだけなので、名前解決も SID の書式も
  `SeSecurityPrivilege` も所有権も関係しません。
- **第二の手段**として、DACL だけを扱う .NET API（`GetAccessControl([AccessControlSections]::Access)` /
  `SetAccessControl`）で継承を復活させ、現在のユーザーの **SID** にフル制御を付ける経路を残しました。
  `Get-Acl` / `Set-Acl` コマンドレットは使いません（上の「2 度目の失敗」参照）。
  この経路は**実機未検証**です。
- **`takeown` は既定で実行しません。** 実機では「アクセスが拒否されました」が大量発生し、しかも不要でした。
  `-Takeown` を明示指定したときだけ走る最後の手段として残してあります
  （`install.ps1` も `14_フォルダのアクセス権を直す` も渡しません）。
- **すでに読み書きできる場合は、アクセス権に一切触りません。** 導入時（`install.ps1` から呼ばれる通常ケース）は
  この分岐で終わるため、**導入が権限を壊す経路そのものが存在しません**。
- **`/inheritance:r`（継承の全削除）をやめました。** `%USERPROFILE%` 配下は既定で他の標準ユーザーから
  読めないため、継承削除で増える安全性はごくわずかである一方、失敗時の被害（本人が締め出される）が
  大きすぎます。代わりに **Everyone / Authenticated Users / BUILTIN\Users / Guests / ANONYMOUS への
  明示的な許可だけ**を外します（別の場所からコピーしてきたフォルダに緩い ACE が残る形はこれで消えます）。
- **権限を変えるたびに、本人が実際に読み書きできることを検証**します（テストファイルを作る → 書く →
  読み返す → 消す ＋ 既存の `*.dpapi` を実際に読む）。**検証に失敗したら変更前の ACL へ戻します。**
  「締めたが誰も入れない」状態で先へ進みません。
- 実体は `scripts/windows/repair-permissions.ps1` に集約し、導入時（`install.ps1` から `-Quiet -NoTakeown`）と
  修復ボタン（`14_フォルダのアクセス権を直す`）が**同じコード**を通ります。
- 受講者に見せるコマンドは、診断・`doctor`・`14_…bat`・本ドキュメント・`docs/13_…`・`スタート.html` の
  すべてで `icacls "%USERPROFILE%\.ai-safety" /reset /T /C /Q` に統一し、
  **「コマンドプロンプト（cmd）で実行する」**と明記しました（PowerShell では `%USERPROFILE%` が展開されません）。
  コマンドが苦手な人向けに**エクスプローラーでの手順**も併記しています。
- 診断（`診断.ps1`）と `doctor.ps1` が **アクセス拒否と復号失敗を区別**するようになりました。
  アクセス拒否のときは「PC を替えた可能性」ではなく権限の問題として、修復手順を表示します。
- mac 側（`install.sh` の `chmod 700/600`）は SID の名前解決を伴わないので同型の事故は起きませんが、
  同じ原則をそろえるため、締めたあとに読み書きを検証し、失敗したら 755 へ戻して警告します。

**回帰テスト**: `scripts/common/test/acl-permissions.test.js`

### まだ確認できていないこと（**実機確認が必要**）

mac の開発機では Windows の ACL を再現できないため、以下は **Windows 実機での確認が必要**です。
上のテストはコードの形（SID を使う／検証する／失敗時に戻す／`/inheritance:r` を使わない）を固定しているだけです。

**確認済み（実機）**: `icacls "%USERPROFILE%\.ai-safety" /reset /T /C /Q` を cmd で実行 → 回復。
`type "%USERPROFILE%\.ai-safety\deepseek.dpapi"` で暗号化された鍵が読め、**鍵は無傷**でした。

**未確認**:

- 壊れた実機で `14_フォルダのアクセス権を直す` **ボタン**を押して回復すること
  （成功が確認できているのは、同じ `icacls /reset` を手で叩いた場合）
- **第二の手段（`GetAccessControl`/`SetAccessControl`）が実機で通ること**。
  `-SelfTest` は「型とメソッドが結線できる」ことしか測れず、実際の書き戻しが
  `SeSecurityPrivilege` 無しで通るかは実機でしか分からない
- Windows PowerShell 5.1（ボタンが使う `powershell.exe`）と PowerShell 7 の**両方**で動くこと
  （5.1 はインスタンスメソッド、7 は拡張メソッドという別経路を通るため）
- 継承を切られた**配下のファイル・フォルダ**（旧 `/T` の後始末）が `/reset /T` で継承へ戻ること
- Microsoft アカウント / AzureAD 参加 / ローカルアカウントのそれぞれで、新規導入時に
  「権限を整えました（読み書きできることを検証済み）」が出ること
- 所有権まで失っているケースの `-Takeown`（実機では takeown 自体がアクセス拒否だったため、
  このフォールバックが役に立つ場面は確認できていない）
- 修復後に「10_困ったとき診断」の `■ 4` / `■ 5` が正しい結果へ変わること

## Windows で「なぜ止まったのか」の日本語が化けていた（修正済み・実機での最終確認待ち）

**症状**: 日本語 Windows で、安全ガード（hook）が出す日本語のメッセージが読めない文字列になる。とくに
**「AI Safety Guard BLOCKED: …」＝ なぜ止まったのかを伝える一番大事なメッセージ**が読めなくなっていました。

**原因**: Claude Code / Codex は hook の出力を **UTF-8** として読みます。一方 PowerShell 5.1 の
`[Console]::OutputEncoding` は日本語 Windows では既定が **CP932** なので、日本語が CP932 のバイト列のまま出て、
受け取り側が UTF-8 として解釈するため化けていました。

**修正**: 日本語を書き出す前に `[Console]::OutputEncoding` を **UTF-8（BOM なし）** へ切り替えるようにしました
（`scripts/windows/lib/SafetyPolicy.ps1` の `Set-AiSafeConsoleUtf8` と、6 本の `guard-*.ps1`）。
承認ダイアログの理由（`permissionDecisionReason`）は標準出力に出る JSON なので、そちらも同じ切り替えで直ります。

- BOM 付きにすると JSON の先頭が壊れるため、必ず BOM なしにしています。
- **`install.ps1` / `doctor.ps1` / `launch-*.ps1` / `open-monitor.ps1` / `secret-scan.ps1` は、
  わざと変えていません。** これらは `.bat` が `chcp 932` した本物のコンソールへ出すので、
  UTF-8 を強制すると逆に化けます。

**確認できていること**（mac 上で CP932 を再現して実測）:

- 修正前の状態（CP932 のまま）だと「危」が `8a eb` として出て、UTF-8 として不正になる ＝ 文字化けを再現
- 修正後は `65001` に切り替わり、「危」が `e5 8d b1` ＝ 妥当な UTF-8 で出る。標準出力に BOM も付かない
- 回帰テスト: `scripts/common/test/windows-hook-encoding.test.js`

**まだ確認できていないこと**: 上の実測は macOS の PowerShell 7 で CP932 を模したものです。
**日本語 Windows の PowerShell 5.1 実機**で、実際に Claude Code の画面に日本語が正しく出ることは未確認です。

## Gemini CLI → Antigravity CLI 並立対応（v1.3.0 時点）

Google から **Gemini CLI を 2026-06-18 で廃止し、後継の Antigravity CLI（`agy`）へ移行する**と発表されました（Pro / Ultra / 無料ティアが対象。Enterprise / Workspace は対象外）。

**本パッケージ v1.3.0 では Gemini CLI と Antigravity CLI の両方をサポート**します（並立）:

| CLI | launcher | 状態 |
|---|---|---|
| Gemini CLI 0.41.2 | `launch-gemini-safe.{sh,ps1}` | 廃止期限 2026-06-18 まで利用可 |
| Antigravity CLI (`agy`) | `launch-agy-safe.{sh,ps1}` | **v1.3.0 で新規追加** |

### Q: どちらを使えばよい？

A: **既に `agy` を入れている人は `agy` 用 launcher を、Gemini CLI のままの人は Gemini CLI 用 launcher を使ってください。** 廃止期限まで両方をサポートします。新規受講者は `agy` を推奨します（公式の継続サポート対象）。

### Q: `agy` の安全装置はどこまで効くか？

A: 以下は本パッケージ launcher 経由で**確実に効きます**:

- `--sandbox` フラグによる terminal restriction（OS レベルのファイル書き込み制限）
- `--add-dir <workspace>` による作業ディレクトリ明示
- agy 1.0.1 以降の `proceed-in-sandbox` tool permission mode（サンドボックス内のターミナルコマンドのみ自動承認、サンドボックスを抜けようとした時のみ手動承認）

一方、以下は**受講者が手動設定する必要があります**（agy が user-level の設定ファイルしか持たないため、launcher で強制できない）:

- `allow_access_gitignore` / `allow_edit_gitignore` を `false` に（`.gitignore` 記載ファイルへの AI アクセスをブロック）
- `allow_auto_run_commands` を `false` に（自動コマンド実行を抑止）

→ `configs/agy/recommended-settings.json` に推奨値があります。agy 起動後、画面右下の `/settings` を開いて 1 つずつ ON/OFF を合わせてください。launcher が初回起動時にヒントを表示します。

### Q: agy でも「見守りモニター」のコーチ解説は出る？

A: **いいえ。コーチ解説・追問は `claude` / `codex` 専用です。** agy は hook（フック）の注入点を持たない別系統のため、agy 起動中はモニターに安全イベントもコーチ解説も表示されません。agy は「OS 隔離（`--sandbox`）＋手動設定」で守る設計、claude / codex は「hook によるブロック＋コーチ解説」で守る設計、と**別物**として理解してください（3 エンジン全部で同じ見守りができるわけではありません）。agy のサンドボックスによるブロック（作業ディレクトリ外への書込・脱出の阻止）は launcher 経由で効きます。

### Q: PromptArmor が報告した `cat .env → webhook.site` の経路は防げる？

A: **本パッケージの推奨設定を完全に適用した場合のみ防げます。** 具体的には:

1. `launch-agy-safe.*` 経由で起動（`--sandbox` 強制）
2. `/settings` で `allow_access_gitignore` を `false`、`allow_auto_run_commands` を `false`
3. agy の **Secure Mode** を **手動で ON**（agy `/settings` 内）

これらを全て守らなかった場合、PromptArmor 報告の exfil シナリオは agy のデフォルト設定下では成立します。Secure Mode は最強の防御層なので、講座運用では受講者全員に ON にさせる方針を推奨します。

### Q: Gemini CLI と Antigravity CLI を同じ PC に入れても OK？

A: 同居可能です。両者は別バイナリ（Gemini CLI は npm 経由、agy は Go バイナリで `~/.local/bin/agy` 等）、設定ディレクトリも分離されています（`~/.gemini/settings.json` vs `~/.gemini/antigravity-cli/settings.json`）。本パッケージの launcher も `launch-gemini-safe.*` と `launch-agy-safe.*` が別ファイルなので衝突しません。

### Q: 廃止期限（2026-06-18）以降はどうする？

A: 本パッケージは v1.3.x の間 Gemini CLI launcher を残しますが、廃止期限後は Google の API 側で Gemini CLI が動かなくなる可能性が高いため、**全員 `agy` に移行する想定**です。v1.4 以降で `launch-gemini-safe.*` を削除する予定（タイミングは v1.3.x のリリースノートで案内）。

---

## Windows

### ExecutionPolicy の変更が許可されない端末（学校 PC など）

通常運用では、最初に一度だけ以下を実行しておけばパッケージ内のスクリプトは素の `powershell -File ...` で動きます。

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

ただし組織のグループポリシーによっては `Set-ExecutionPolicy` 自体が拒否される場合があります。その場合の**最終手段の回避策**として、その都度以下のように `-ExecutionPolicy Bypass` を明示する運用も可能です。

```powershell
powershell -ExecutionPolicy Bypass -File <スクリプトパス>
```

**重要**：これは「自分が中身を確認した、信頼できるスクリプト」だけに使うこと。**他人から渡された `.ps1` に対して `-Bypass` を付けない**原則は守ってください（詳しくは `docs/01_学校PCで使う.md` のコラム「`-ExecutionPolicy Bypass` は使わない」参照）。

### Codex CLI の Windows サンドボックスが効かない

`codex sandbox windows` が `elevated`（Admin 必要）モードでしか強力に動かないケース。`unelevated` は弱い。

→ hook 層で同等の防御を行うため、サンドボックス単独で守られない場合も hook で塞がる。`doctor` で確認可能。

### codex の Windows サンドボックスが一部環境で起動しない

codex-cli 0.135.0 で `codex sandbox windows` が `CreateProcessAsUserW failed: 2` で失敗し、`doctor` の「codex windows sandbox blocks outside write」drill が FAIL する場合があります。

これは **codex CLI 自身のサンドボックス機能の問題**で、本パッケージの PreToolUse フックガードは正常に機能しています（`doctor` の guard drill 1〜7 は全 PASS）。codex の defense-in-depth が一段減るだけで、ガードによる保護は維持されます。

回避策・原因は調査中（codex バージョン依存の可能性）。

### Windows Defender SmartScreen の警告

未署名 `.ps1` / `.cmd` をダウンロード元タグ付きで実行しようとすると警告が出ることがある。

回避：
1. ZIP をプロパティから「ブロック解除」する（**v1.4.1 から `docs/01` のステップ 0.5 に必須手順として明記**）
2. または「詳細情報 → 実行」で初回のみ許可
3. 講師 PC で事前に動作確認した版を配布する

詳しい手順は [01_学校PCで使う.md のステップ 0.5](01_学校PCで使う.md) を参照。

### PowerShell に `@echo off` のエラーが出る

`@echo off`、`if not exist`、`%~dp0`、`%TARGET%` などのエラーが PowerShell に出る場合、`.bat` ファイルの中身を PowerShell に貼り付けています。`.bat` は CMD 用なので、PowerShell では文法エラーになります。

回避：
1. まずは `.bat` の中身を貼らず、ファイルとしてダブルクリックする
2. `.bat` がセキュリティで止められる場合は、展開したフォルダ（`スタート.html` がある場所）で PowerShell を開く
3. 次の 1 行を貼る

```powershell
if (Test-Path ".\scripts\windows\install.ps1") { Get-ChildItem -LiteralPath . -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue; powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\windows\install.ps1" -Workspace "$env:USERPROFILE\Documents\my-ai-workspace" } else { Write-Host "スタート.html があるフォルダで PowerShell を開き直してください" }
```

### ZIP 解凍で日本語ファイル名が文字化け

回避：Windows 標準の「すべて展開」を使う。Lhaplus 等の古いツールは UTF-8 ZIP を扱えないことがある。

このパッケージはファイル名をすべて ASCII にしているので、内容上の文字化けは発生しないはず。

## macOS

### `.command` ファイルが「開発元が未確認」で開けない

回避：
1. Finder で `.command` を右クリック →「開く」を選択
2. 警告ダイアログで「開く」をクリック
3. 一度許可すれば、次回からは普通に動く

### ZIP 解凍で実行権限が落ちる

回避：

```bash
chmod +x ~/Downloads/ai-agent-safety-package-v1/scripts/macos/*.sh
chmod +x ~/Downloads/ai-agent-safety-package-v1/scripts/macos/lib/*.sh
```

または、install スクリプトを `bash` で明示的に起動する。

```bash
bash scripts/macos/install.sh ~/Documents/my-ai-workspace
```

### Apple Silicon Mac で Codex CLI が動かない

`codex` コマンドが `command not found` または起動失敗。

回避：Rosetta 経由で再インストール。

```bash
arch -x86_64 npm install -g @openai/codex
```

それでも動かない場合、Codex CLI を諦めて別の AI（Claude 課金があれば Claude Code、無課金なら agy や OpenCode + DeepSeek）に切り替えてください（[00_はじめに.md](00_はじめに.md) の課金状況別の表を参照）。

### Seatbelt サンドボックスの既知バグ

特定のシンボリックリンク経由でサンドボックスを抜けるバグが報告されている。

→ hook 層で同等の防御を行うため、Seatbelt 単独で守られない場合も hook で塞がる。

## 共通

### 「fail closed」の挙動

hook スクリプトが何らかの理由（PowerShell 不在、bash 不在、policy.json 破損等）で起動できない場合、**操作は全てブロック**される設計（fail closed）。

→ 安全側に倒すための仕様。回避が必要ならスクリプトを修復してから使う。`doctor` で原因を特定できる。

### 業務プロジェクトを上書きインストールした場合

既存の `.claude/`、`.codex/`、`.gemini/` 設定は `~/.ai-safety/backups/<timestamp>/` にバックアップされる。

復旧：`restore.ps1` または `restore.sh` を使う。

### AGI Cockpit から Codex を使うと、このパッケージの保護が乗らない

AGI Cockpit（複数の AI を 1 画面で使えるアプリ）から **Codex** を起動すると、このパッケージの hook・環境変数フィルタは**適用されません**（Cockpit はパッケージの launcher を経由しないため）。Codex 自身のネイティブサンドボックスと Cockpit の承認 UI だけが働く状態になります。

→ **Codex はスタートフォルダの「2_セーフCodexを起動」から使ってください。** Claude は Cockpit 経由でも、作業フォルダを my-ai-workspace にすれば保護が効きます（実測済み）。詳しくは [11_AGI-Cockpitで使う.md](11_AGI-Cockpitで使う.md)。

### CLI メジャーアップデート後に hook が動かない

Codex / Claude / Gemini CLI が hook の仕様を変更した場合に発生する可能性。

回避：`update-safety.ps1` / `update-safety.sh` を実行して、互換性チェック付きで再インストール。

それでも直らない場合、講師に連絡（CLI バージョン情報を `collect-status` で添付）。

## レポートしたい問題があれば

- GitHub Issues（リポジトリの Issues ページ）
- または講師の連絡先まで

具体的な再現手順、エラーメッセージ、`collect-status` の出力ファイルを添えると修正が早いです。

---

## PC 内の「謎ファイル」FAQ

AIツールをインストールすると、気づかないうちに大きなフォルダが増えていることがあります。
見慣れないフォルダ・ファイルを見つけたときの判断材料をまとめました。

> **注意**: 以下の整理手順は **PC 上で自分（人間）が** 実行するものです。**AI エージェント（Codex / Claude / Gemini）に「このコマンドを実行して」と投げないでください**。AI に削除コマンドを任せると、判断ミスで重要なファイルまで巻き込まれる事故が起きえます（policy 層で `rm -rf` 系はブロックする設計ですが、運用上 AI に任せない方針です）。また、生 `rm -rf` の代わりに `mv ... ~/.Trash/`（Mac）/「ごみ箱に移動」（Windows エクスプローラ）を使えば、誤削除しても復元できます。

### Q1: `~/.claude/` や `~/.codex/` というフォルダがある。マルウェア？

**A: 正常です。削除不要。**

これらは Claude Code CLI・Codex CLI の本体データです。

| フォルダ | サイズ目安 | 内容 |
|---|---|---|
| `~/.claude/` | 約 1.6GB | Claude Code CLI の実行ファイル・設定・ログ |
| `~/.codex/` | 約 1.6GB | Codex CLI の実行ファイル・設定・ログ |

（Windows の場合: `%USERPROFILE%\.claude\`、`%USERPROFILE%\.codex\`）

CLIをアンインストールすれば消えます。使い続けるなら残しておいて問題ありません。

---

### Q2: `~/Library/Application Support/Claude/` が 20GB 以上ある

**A: Claude デスクトップアプリの Cowork / Local Agent Mode を使うと、Linux の仮想マシン（VM）が自動でインストールされます。**

その VM のディスクイメージが 15〜20GB を占めており、これが正体です。マルウェアではありません。

- **使っている場合**: そのままで OK。AI に安全に作業させるための「隔離された部屋」です。
- **使っていない場合**: Claude デスクトップアプリの「設定 → 開発者 → Cowork の削除」から VM だけを削除できます。アプリ本体は残ります。

---

### Q3: `~/Library/Caches/` の中に `Sparkle` や `ShipIt` というフォルダが 800MB ある

**A: 自動アップデーター（Sparkle）の遺物です。削除して OK です。**

Claude・Codex・その他の Mac アプリが自動更新に使うフレームワークが残したキャッシュです。
削除してもアプリの動作に影響はありません。

```bash
# Finder で開いて確認してから削除する場合（安全）
open ~/Library/Caches/

# ターミナルで直接整理する場合（Trash 経由なら誤削除時に復元できる）
mv ~/Library/Caches/com.anthropic.claudefordesktop/Sparkle ~/.Trash/
mv ~/Library/Caches/com.openai.Codex/Sparkle ~/.Trash/
```

> 上のコマンドは `rm -rf` ではなく `mv ... ~/.Trash/`（ゴミ箱への移動）にしています。間違えても Finder のゴミ箱から戻せます。完全に削除したくなったら、最後にゴミ箱を空にしてください。

---

### Q4: `/private/tmp/` に `claude-*` や `codex-*` で始まるファイルが溜まっている

**A: CLI 起動時に作られる一時的な連絡用ファイル（IPC ファイル）です。3日以上前のものは削除 OK です。**

Claude Code CLI や Codex CLI が起動中に使う「プロセス同士の連絡メモ」のようなものです。
通常は CLI 終了時に自動削除されますが、強制終了した場合などに残ることがあります。

```bash
# 3日以上前の claude-* / codex-* 一時ファイルを確認
find /private/tmp -maxdepth 1 \( -name 'claude-*' -o -name 'codex-*' \) -mtime +3

# 確認して問題なければ削除
find /private/tmp -maxdepth 1 \( -name 'claude-*' -o -name 'codex-*' \) -mtime +3 -delete
```

---

### Q5: `/var/folders/` の中にも `claude-*` や `codex-*` があった

**A: macOS が自動管理する「ユーザー専用の一時領域」です。macOS が自動削除するので放置で OK です。**

`/var/folders/XX/XXXXXXXXXXXXXXXX/T/` のような深い場所にあるのは、macOS が各ユーザーに割り当てる一時フォルダです。数KB〜数十KB のファイルが多く、macOS の起動サイクルで自動的に整理されます。手動で削除しても構いませんが、しなくても問題ありません。

---

### Q6: ディスク容量を節約したい。安全に消せるものは何か？

**A: 以下の順番で確認・削除してください。**

#### 確認コマンド（削除なし・安全）

```bash
# CLI 本体の使用量を確認
du -sh ~/.claude ~/.codex 2>/dev/null

# Claude デスクトップアプリの VM を確認
du -sh ~/Library/Application\ Support/Claude 2>/dev/null

# Sparkle キャッシュを確認
du -sh ~/Library/Caches/com.anthropic.claudefordesktop 2>/dev/null
```

#### 削除の優先順位（上から安全度が高い）

1. **`/private/tmp/` の古い一時ファイル**（3日以上前）→ Q4 の手順で削除
2. **Sparkle / ShipIt キャッシュ** → Q3 の手順で削除
3. **Claude デスクトップの VM**（Cowork を使っていない場合のみ）→ Q2 の手順で削除
4. **`~/.claude/`・`~/.codex/`** → CLI をアンインストールする場合のみ削除。使い続けるなら残す

> 注意: `rm -rf` コマンドは**元に戻せません**。本ドキュメントの手順は `mv ... ~/.Trash/`（ゴミ箱経由）で書いてありますが、ネット記事などで `rm -rf` を見かけたら一度立ち止まり、`du -sh` で対象フォルダの中身とサイズを確認してから実行してください。そして、繰り返しになりますが、**AI エージェントに `rm -rf` 系のコマンドを投げない**こと。

---

### Q7: Windows を使っている。Mac と同じフォルダ名で探しても見つからない

**A: Windows の場合は保存場所が異なります。**

| 役割 | Mac | Windows |
|---|---|---|
| CLI 本体データ | `~/.claude/`、`~/.codex/` | `%USERPROFILE%\.claude\`、`%USERPROFILE%\.codex\` |
| デスクトップアプリデータ | `~/Library/Application Support/Claude/` | `%LOCALAPPDATA%\Claude\` |
| アップデーターキャッシュ | `~/Library/Caches/.../Sparkle` | `%TEMP%\Squirrel-*` または `%LOCALAPPDATA%\Claude\` 内 |
| CLI 一時ファイル | `/private/tmp/claude-*` | `%TEMP%\claude-*` または `%TEMP%\codex-*` |

エクスプローラーで確認する場合は、アドレスバーに `%USERPROFILE%` や `%LOCALAPPDATA%` と入力すると直接移動できます。

Windows では「一時ファイルのクリーンアップ」（設定 → システム → ストレージ → 一時ファイル）で CLI の一時ファイルをまとめて削除できる場合があります。
