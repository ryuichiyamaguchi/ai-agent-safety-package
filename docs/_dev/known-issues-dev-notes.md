# 既知の問題 — 開発者向けの記録

`docs/99_known_issues.md` から移した、修正の実装内容・実機で失敗した方法・未確認事項・過去の移行メモです。
受講者向けの症状と直し方は `docs/99_known_issues.md` にあります。ここは開発者（講師）向けで、配布先の作業フォルダには同期されません。

### v1.17.3 での修正

- ランチャー側: 外部コマンド（node / opencode / codex など）の呼び出しを `Invoke-NativeQuiet` に統一し、
  **成否は必ず終了コードで判定する**ようにした。情報メッセージが 1 行出ただけで止まることはなくなる。
  同じ書き方が残っていた他のランチャー・診断・隔離ドリルも横断で直した
- `gateway-token.js` 側: 「使い回せない」は正常系なので**何も出力せず終了コードだけで表す**ようにした
  （理由を見たいときは `--probe --verbose`）。本当の異常はこれまでどおりエラー出力に出し、起動を止める
- 更新直後に古い Gateway が 8788 番を掴んだまま残らないよう、記録されたポートは立て直しの前に必ず止める
- 回帰テスト（`scripts/common/test/windows-native-stderr.test.js`）で、危険な書き方が再び入らないよう機械的に固定した

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

### v1.17.2 での修正

- **修復の第一の手段を `icacls "<フォルダ>" /reset /T /C /Q` にしました**（実機で成功が確認された唯一の方法）。
  親フォルダから継承される既定の権限へ戻すだけなので、名前解決も SID の書式も
  `SeSecurityPrivilege` も所有権も関係しません。
- **第二の手段**として、DACL だけを扱う .NET API（`GetAccessControl([AccessControlSections]::Access)` /
  `SetAccessControl`）で継承を復活させ、現在のユーザーの **SID** にフル制御を付ける経路を残しました。
  `Get-Acl` / `Set-Acl` コマンドレットは使いません（上の「2 度目の失敗」参照）。
  この経路は**実機未検証**です。
- **`takeown` は既定で実行しません。** 実機では「アクセスが拒否されました」が大量発生し、しかも不要でした。
  `-Takeown` を明示指定したときだけ走る最後の手段として残してあります
  （`install.ps1` も `13_フォルダのアクセス権を直す` も渡しません）。
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
  修復ボタン（`13_フォルダのアクセス権を直す`）が**同じコード**を通ります。
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

- 壊れた実機で `13_フォルダのアクセス権を直す` **ボタン**を押して回復すること
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
- 修復後に「9_困ったとき診断」の `■ 4` / `■ 5` が正しい結果へ変わること

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

## Windows で「なぜ止まったのか」の日本語が化けていた（技術メモ）

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
