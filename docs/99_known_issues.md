# 既知の問題

本パッケージで把握している既知の問題と回避策。

## Windows: タスクのたびに「AI 判定の起動に失敗しました」と止まる（v1.18.1 で修正）

**症状**: d-claude で Bash を使うたびに、次の確認が出て作業が止まる。

```
Hook PreToolUse:Bash requires confirmation
AI 判定の起動に失敗しました（安全側で確認します）
```

**原因**: 2 鍵判定を起動する Windows hook が、PowerShell 5.1 に存在しない `StandardInputEncoding` を触っていた。触った瞬間に失敗し、安全側で毎回人間確認に倒していた。

**回避（修正版が届くまで）**: 確認画面で「Yes」を選べばそのコマンドは進みます。危険なコマンドまで自動では通りません。

**修正**: `scripts/windows/guard-bash.ps1` でそのプロパティを触らないようにし、`node.exe` を優先して探すようにした。

## Windows: d-claude の gemini-vision（画像読取）が使えない（v1.18.1 で修正）

**症状**: d-claude に画像やスクリーンショットを見せても、中身を読めない。

**原因（重なる）**:

1. Windows PowerShell 5.1 の `ConvertTo-Json` が、要素 1 個の `args` 配列を文字列に潰す。Claude Code が MCP を起動できず、gemini-vision を含む補助ツールが全部落ちる
2. `Set-Content -Encoding UTF8` が JSON に BOM を付け、設定ファイルとして読めないことがある
3. 会話に添付した画像は送信検査 Gateway がテキストに差し替えていたが、`describe_image` に渡すファイルパスが無かった

**回避（修正版が届くまで）**: 画像ファイルを作業フォルダに保存し、そのパスをチャットに書いて「このファイルを describe_image で見て」と頼む。MCP 自体が起動していない場合は、この回避も使えません。

**修正**: MCP 設定を node で BOM なし JSON として書き、Gateway が添付画像を一時ファイルに落としてパスを案内するようにした。

## 「7_金庫に秘密をしまう」のあとに `.env` へ何を書けばよいか

DeepSeek / Gemini / Buffer は専用ボタン（1 / 3 / 5 番）でしまい、`.env` は不要です。

それ以外の API キーは、7 番で付けた名前を使って次を `.env` に書きます。

```
（プログラムが探す名前）=aisafety://user/付けた名前
```

例: 名前を `openai` にした場合は `OPENAI_API_KEY=aisafety://user/openai`。
この住所のまま起動しても本物にはなりません。次で差し替えます。

```
node .ai-safety/hooks/common/secret-store.js --run --env-file .env -- node app.js
```

しまい終わった画面にも、同じ文字列が出ます。くわしくは `docs/13_秘密の入れ物-APIキーの安全な持ち方.md`。

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
   上流が 4xx/5xx を返していれば `{"event":"upstream_error","status":404,...}` の行が残ります（v1.17.4〜）。
   - **`upstream_error` の行がある** → 送り先（DeepSeek）が 404 を返しています。行の `path` と `body` が実際の理由です。
   - **`upstream_error` の行が 1 本も無い** → その 404 は Gateway を通っていません。Claude Code が **Gateway ではない別の宛先**（本家 `api.anthropic.com` など）へ送っています。`ANTHROPIC_BASE_URL` が `http://127.0.0.1:<ポート>` になっているか、古い Gateway がポートを掴んでいないかを確認してください。
2. 古い Gateway が残っている疑いがあるときは、上の「更新後、Windows で〜」の回復方法（再起動、または 8788 番の taskkill）と同じ手順で止めてから起動し直します。

**v1.17.3 で入れたもの**: ds-gateway が上流の 4xx/5xx を必ず `upstream_error` としてログに残し、404 のときは「Claude Code はこれをモデルの問題として表示しますが、実際は送り先が 404 を返しています」と画面にも出すようにしました。**現象そのものを直す修正ではありません**（パッケージ側のコードは mac 実機・実キーで端から端まで 200 で通ることを確認済み）。受講者の環境で再発したときに、原因が 1 分で切り分けられるようにするための変更です。

## ★重大: 更新後、Windows で OpenCode / d-claude が起動しなくなる（v1.17.3 で修正）

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

**誰が当たるか**: **v1.17.3 の更新を入れる前から送信検査 Gateway が動いていた Windows の人全員**。
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

（修正の経緯と開発者向けの記録は [_dev/known-issues-dev-notes.md](_dev/known-issues-dev-notes.md) にあります）

## ★重大: Windows で自分の `.ai-safety` フォルダに入れなくなる（v1.17.2 で修正）

**症状**（受講者の Windows 実機で確認）:

- 「9_困ったとき診断」に `Get-Content : パス 'C:\Users\<名前>\.ai-safety\deepseek.dpapi' へのアクセスが拒否されました。`
  （`UnauthorizedAccessException`）が出る
- 診断が **「金庫のファイルを復号できません（PC を替えた／Windows を入れ直した可能性）→ キーを作り直して登録し直してください」** と表示する
- AIコーチ（Gemini）のキーが金庫に入らず、平文のキーファイルだけが残る
- 「金庫への書き込みに失敗した記録はありません」と出るのに、金庫が作られていない

**原因**: v1.17.1 時点の `scripts/windows/install.ps1` は、導入の最後に次を実行していました（v1.17.2 で撤廃済み）。

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

1. **「スタート」フォルダの `13_フォルダのアクセス権を直す` を実行する**（おすすめ・ボタン 1 つ）
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

（修正の経緯と開発者向けの記録は [_dev/known-issues-dev-notes.md](_dev/known-issues-dev-notes.md) にあります）

## Windows で「なぜ止まったのか」の日本語が化けていた（修正済み・実機での最終確認待ち）

**症状**: 日本語 Windows で、安全ガード（hook）が出す日本語のメッセージが読めない文字列になる。とくに
**「AI Safety Guard BLOCKED: …」＝ なぜ止まったのかを伝える一番大事なメッセージ**が読めなくなっていました。

**修正済みです。** 日本語 Windows の実機での最終確認だけ残っています。（修正の経緯と開発者向けの記録は [_dev/known-issues-dev-notes.md](_dev/known-issues-dev-notes.md) にあります）

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

→ **Codex はスタートフォルダの「4_AIを起動する」から使ってください（メニューで Codex を選びます）。** Claude は Cockpit 経由でも、作業フォルダを my-ai-workspace にすれば保護が効きます（実測済み）。詳しくは [11_AGI-Cockpitで使う.md](11_AGI-Cockpitで使う.md)。

### CLI メジャーアップデート後に hook が動かない

Codex / Claude / Gemini CLI が hook の仕様を変更した場合に発生する可能性。

回避：スタートの「1_安全パッケージを最新版にする」→「9_困ったとき診断」の順に実行します（新しい CLI に合わせた設定が入ります）。

それでも直らない場合は、診断結果をコピーして、在校中は講師へ、卒業後は [20_卒業後ガイド.md](20_卒業後ガイド.md) の「困ったときの調べ方」に沿って相談してください。

## レポートしたい問題があれば

- GitHub Issues（リポジトリの Issues ページ）
- 在校中は講師の連絡先まで

具体的な再現手順、エラーメッセージ、「9_困ったとき診断」の結果（「結果をコピー」で取れます）を添えると修正が早いです。

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
