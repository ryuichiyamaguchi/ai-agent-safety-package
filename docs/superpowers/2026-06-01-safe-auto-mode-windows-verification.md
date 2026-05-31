# Safe Auto Mode — Windows 実機検証 手順書 (runbook)

- **対象**: ryuichi さんが Windows 実機で実行
- **日付**: 2026-06-01
- **ブランチ**: `feat/safe-auto-mode`(PR #3)
- **目的**: macOS では実証済みの Safe Auto Mode が Windows でも (a) フェイルクローズで安全に動き、(b) 隔離が確認できたときオートが実際に解放されることを実機で確認する。
- **背景**: 当開発環境は macOS で pwsh が無く `.ps1` を実行できないため、Windows コードは mac の実証済み実装の忠実なミラー(静的レビュー済み)。**実行確認は本手順が初**。

> macOS 側の到達状態(参考): `auto-mode.test.sh` 28/28、`doctor --isolation-check codex` = exit 0(green)、full doctor pass=15、オフライン時は network 判定 HOLD でフォールバック。Windows でも同じ結果になることを確認する。

---

## 0. 前提(事前に揃える)

- Windows 10 / 11、自分のユーザーアカウント。
- **Codex CLI 0.135.0**(`codex --version` で確認)。`codex login` 済み。
  - ※ 本パッケージの codex 対応は **0.135 系の新 `codex sandbox` 構文**前提。0.130 等の旧版では検証ドリルが動かない。
- PowerShell 実行ポリシー: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`(未実施なら)。
- **git** がインストール済み(`git --version`)。ドリルの sandbox 検証は `:workspace` 解決のため inside dir を git 化する想定(mac で必要だった)。未確認点なので、git 無し環境での挙動も観察対象。
- Node.js は Gateway 用。Safe Auto Mode 単体には必須でない。

検証は展開した安全パッケージ(`feat/safe-auto-mode` の中身)の `scripts/windows/` を直接叩くか、`install.ps1` で workspace に入れた `.ai-safety/hooks/windows/` を叩く。以下は**リポジトリ直叩き**の例。workspace 経由なら各パスを `.ai-safety\hooks\windows\` に読み替え。

---

## 1. インストール配置の確認(safe.config.toml が要)

```powershell
powershell -File scripts\windows\install.ps1 -Workspace "$env:USERPROFILE\Documents\my-ai-workspace"
```

- **期待**: エラーなく完了。`%USERPROFILE%\Documents\my-ai-workspace\.codex\safe.config.toml` が配置される(install.ps1 が hash 検証付きでコピー)。
- **なぜ重要**: codex 0.135 は `codex --profile safe` と同一 config 内の `[profiles.safe]` 併用が **fatal**。`[profiles.safe]` を `safe.config.toml` に分離した。これが無いと launcher が codex を起動できない。

**確認**: `Test-Path "$env:USERPROFILE\Documents\my-ai-workspace\.codex\safe.config.toml"` が `True`。

---

## 2. フル doctor(回帰 + 隔離行)

```powershell
powershell -File scripts\windows\doctor.ps1
```

- **期待**: 既存ドリルが PASS、末尾に `isolation:` 行(PASS/SKIP)。`fail=0`。
- codex が居て sandbox が効けば `PASS isolation: ...`、codex 不在や sandbox 検証不能なら `SKIP isolation: ...`(集計外)。**FAIL isolation が出たら隔離に穴**なので報告。

---

## 3. 隔離チェック(オートのゲート本体) ★最重要

### 3-1. オンライン(ネット接続あり)で green を確認

```powershell
powershell -File scripts\windows\doctor.ps1 -IsolationCheck codex
echo "exit=$LASTEXITCODE"
```

- **期待(理想)**: 出力に `PASS ...`(workspace-外書込遮断)と network の PASS、**exit=0**(green)。
- これが green になれば、Windows でオートが実際に解放できる土台が成立。

### 3-2. オフライン(ネット遮断)で HOLD→非0 を確認(フェイルクローズ)

Wi-Fi/LAN を一時的に切る、または機内モードにして:

```powershell
powershell -File scripts\windows\doctor.ps1 -IsolationCheck codex
echo "exit=$LASTEXITCODE"
```

- **期待**: ベースライン疎通(`1.1.1.1:443`)が取れず network 判定が **HOLD** → **exit≠0**(オートを開けない=安全側)。
- 「遮断を実証できたときだけ green」原則。オフラインで green になってしまったら**バグ**(報告)。

### 3-3. agy の宣言チェック

```powershell
powershell -File scripts\windows\doctor.ps1 -IsolationCheck agy
echo "exit=$LASTEXITCODE"
```

- **期待**: agy が PATH にあれば exit=0(宣言ベース green)、無ければ exit≠0。

---

## 4. PowerShell テストハーネス

```powershell
powershell -File scripts\windows\test\auto-mode.test.ps1
```

- **期待**: `summary: pass=N fail=0`。特に classify 7 ケース(baseline+blocked=PASS / block-leak=FAIL / block-indeterminate=HOLD / offline-baseline=HOLD / baseline-timeout=HOLD / single-refused=HOLD / single-connected=FAIL)と、doctor 不在・実行不可のフェイルクローズ回帰が PASS。
- `fail>0` の項目名をそのまま報告してください。

---

## 5. launcher の --auto 分岐

### 5-1. dry-run でコマンド組み立てを確認(実起動しない)

```powershell
$env:AI_SAFE_DRY_RUN = "1"
powershell -File scripts\windows\launch-codex-safe.ps1 "$env:USERPROFILE\Documents\my-ai-workspace" "" --auto
Remove-Item Env:\AI_SAFE_DRY_RUN
```

- **期待(オンライン/doctor green)**: 出力コマンドに `--ask-for-approval on-failure`(承認解放) + `--sandbox workspace-write` 維持。
- **オフライン/doctor 赤**: `--ask-for-approval untrusted`(フォールバック) + 理由メッセージ。

### 5-2. --auto なし(従来起動・回帰)

```powershell
$env:AI_SAFE_DRY_RUN = "1"
powershell -File scripts\windows\launch-codex-safe.ps1 "$env:USERPROFILE\Documents\my-ai-workspace"
Remove-Item Env:\AI_SAFE_DRY_RUN
```

- **期待**: 従来どおり `--ask-for-approval untrusted`。変化なし。

### 5-3. 実起動(任意・dry-run を外す)

`AI_SAFE_DRY_RUN` を付けずに `launch-codex-safe.ps1 <ws>` を実行し、**codex が 0.135 で fatal にならず起動**すること(`safe.config.toml` 分離が効く)。`--auto` 付きで起動し、承認なしで通常作業が進むこと・危険操作や外部送信が hook/sandbox で止まることを軽く確認。

### 5-4. agy(任意)

```powershell
$env:AI_SAFE_DRY_RUN = "1"
powershell -File scripts\windows\launch-agy-safe.ps1 "$env:USERPROFILE\Documents\my-ai-workspace" "" --auto
Remove-Item Env:\AI_SAFE_DRY_RUN
```

- **期待(green)**: `--sandbox` + `--dangerously-skip-permissions` + 「独立検証されていない/verified でない」旨の caveat。**赤**: `--sandbox` のみ、skip-permissions 無し。

---

## 6. 重点確認ポイント(Windows 固有・未知が残る箇所)

これらは macOS と実装機構が違い(seatbelt ではなく AppContainer/制限ジョブ)、実機で初確認:

1. **`codex sandbox --permissions-profile <NAME> -C <dir> <cmd>` が 0.135 Windows でパース・起動するか**(旧 `codex sandbox windows` から構文変更)。
2. **inside-write 成功**: `cmd /c "type nul > <inside>\f"` が sandbox 内で成功しファイルが作られるか。
3. **outside-write 遮断**: `%USERPROFILE%\.ai-safety\.sbprobe-out.<guid>` への書込が遮断されるか(`%TEMP%` は workspace-write で書込可になりうるため outside 先を USERPROFILE 配下にしてある)。
4. **network: ベースライン(enabled=true)で `1.1.1.1:443` に CONNECTED / 遮断(enabled=false)で refused** になるか。Windows codex の network 遮断が AppContainer の network 分離で効くか。
5. **TcpClient 例外メッセージ**が分類キーワード(`operation not permitted|not permitted|denied|refused`)にマッチするか。マッチしないと安全側(HOLD)に倒れるが green に到達しない。
6. **クリーンアップ**: `Start-Job` の `Stop-Job`(スレッド中断)で finally が走らない可能性 → 開始時 prune がバックストップ。`%USERPROFILE%\.ai-safety\` に `.sbprobe-out.*` 残骸が蓄積しないか。
7. **`$env:CODEX_HOME` の保存・復元**がドリル前後で正しいか。

---

## 7. 結果報告テンプレ(これを埋めて戻してください)

```
[1 install]        safe.config.toml 配置: OK / NG(詳細)
[2 full doctor]    pass=__ fail=__  (FAIL項目: )
[3-1 green online] exit=__  (PASS/SKIP/FAIL の isolation 行: )
[3-2 offline]      exit=__  (HOLD でフォールバックしたか: Y/N)
[3-3 agy]          exit=__
[4 test.ps1]       pass=__ fail=__  (FAIL項目: )
[5-1 --auto green] on-failure 出た: Y/N
[5-2 no-auto]      untrusted 維持: Y/N
[5-3 実起動]       codex 0.135 起動: OK/NG / オート挙動所感:
[5-4 agy --auto]   skip-permissions+caveat: Y/N
[6 重点]           1〜7 で気づいた異常:
```

- どれかで「green になってはいけない場面で green」になったら**最優先で報告**(フェイルクローズの穴)。
- 構文エラー・PowerShell 例外が出たらメッセージ全文を貼ってください。実機でしか出ない PowerShell 5.1 固有の問題はここで初めて分かるので、遠慮なく。

---

## 関連
- 設計: `docs/superpowers/specs/2026-06-01-safe-auto-mode-design.md`(§6 に既知フォローアップ)
- 計画: `docs/superpowers/plans/2026-06-01-safe-auto-mode.md`
- mac 実装の到達状態は本書冒頭の参考値を参照。
