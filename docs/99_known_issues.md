# 既知の問題

v1.5.0 時点で把握している既知の問題と回避策。

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

それでも動かない場合、Codex CLI を諦めて Claude Code（Mac native）または Cursor 拡張に切り替え。

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
