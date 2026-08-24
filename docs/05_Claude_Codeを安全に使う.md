# Claude Code を安全に使う（個人利用向け）

v1.17.4

## このドキュメントは誰のものか

このページは、個人で **Claude Code CLI** を使いたい受講者向けです。

> ⚠️ **Claude Code / Claude Desktop は無料プランでは使えません。** Claude の有料プラン（Pro 以上）への加入が前提です。無課金で「Claude のような使い心地」が欲しい場合は、[10_OpenCode_DeepSeekを安全に使う.md](10_OpenCode_DeepSeekを安全に使う.md) の OpenCode + DeepSeek 経路を使ってください。

Claude Code（Anthropic 製）と Codex（OpenAI 製）は別ツールですが、このパッケージで Codex と同等の防具を装着できます。

**AGI Cockpit というアプリの中から Claude を使いたい方へ**：作業フォルダを my-ai-workspace にすれば、このパッケージの保護はそのまま効きます（実測済み）。手順は [11_AGI-Cockpitで使う.md](11_AGI-Cockpitで使う.md) を見てください。

## Claude Code とは

Claude Code は **Claude 推論モデルを使って、あなたのパソコンでコードを書き実行する** AI ツールです。Codex と似ていますが、以下が違います。

| 項目 | Claude Code | Codex |
|---|---|---|
| 提供元 | Anthropic | OpenAI |
| 認証方式 | Anthropic アカウント | OpenAI API キー |
| 価格モデル | 使用量課金（API）| ChatGPT Pro / Team |
| ローカル設定 | `.claude/settings.json` | `.codex/config.toml` |
| インストール | Node.js 経由 | Node.js 経由 |

**操作・承認ダイアログの考え方は Codex と同じ**です。Day4 で習った「黄色いプロンプトが出たら読んで許可する」そのままで大丈夫です。

## 前提条件

Claude Code を使う前に以下が必要です。

- **Node.js 18 以上**（Codex と同じ）
- **Anthropic アカウント**（Claude.ai のアカウントと同じ）
- **Pro プラン以上の課金**（無料プランでは Claude Code は使えません。料金は公式サイトで確認：https://claude.com/pricing）

## ステップ 1：Node.js の確認

すでに Codex をインストールしていれば OK です。

```bash
node --version
npm --version
```

まだの場合は公式から：https://nodejs.org/

## ステップ 2：Claude Code をインストール

```bash
npm install -g @anthropic-ai/claude-code@latest
claude --version
```

バージョン確認できれば成功です（`2.1.236` など、数字は入れた時期で変わります）。

> **Claude Code は最新版に更新して使ってください。** 以前のこのパッケージは「パッケージが動作確認した版に合わせる」方式で版を固定していましたが、いまは**最新版追従**に変えました。Claude Code 純正の壁（サンドボックス）は新しい版でないと使えないためです。2 回目以降は、スタートフォルダの **「9_AIツールを最新版に更新」** をダブルクリックすれば更新できます。

**参考**：公式ドキュメント https://docs.claude.com/ja/docs/claude-code/quickstart

## ステップ 3：Anthropic アカウント認証

初回実行時にブラウザが開いて「Anthropic にログインしてください」と出ます。

```bash
claude
```

ブラウザで Anthropic アカウント（Claude.ai に使うのと同じアカウント）でログインします。

**注意**：
- ChatGPT のサブスクとは別です。Anthropic の Pro プラン以上に入っている必要があります
- **無料プランのアカウントでは Claude Code は使えません**
- 初回認証後はローカルに token が保存されるので、毎回ブラウザログインは不要です

## ステップ 4：このパッケージで安全に起動する

Claude Code を **このパッケージの保護下で実行**します。

いちばん簡単なのは、作業フォルダの `スタート` フォルダにある **「3_セーフClaudeを起動」**（Mac は `.command`、Windows は `.bat`）を**ダブルクリック**する方法です。

コマンドで起動したい場合：

### Mac の場合

```bash
cd ~/Documents/my-ai-workspace
bash .ai-safety/hooks/macos/launch-claude-safe.sh
```

### Windows の場合

```powershell
cd "$env:USERPROFILE\Documents\my-ai-workspace"
powershell -File ".ai-safety\hooks\windows\launch-claude-safe.ps1"
```

> ※ `my-ai-workspace` の部分は、インストール時に自分でつけたフォルダ名に読み替えてください（例：`Desktop\my-project` など）。

> **短い呼び名も使えます**：長いパスを打つ代わりに、`claude-safe` と入力しても同じ安全起動ができます（Codex は `codex-safe`、AntiGravity は `agy-safe`）。導入時に用意される呼び名で、中で上の launcher に橋渡ししています。ターミナルを開き直しても呼び名が見つからないときは、これまでどおり上のコマンドを使ってください。

※ 事前に `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` を実行済みであることが前提です（docs/01 / docs/02 のステップ 0 参照）。

launcher が次の防御を自動で有効にします。ここは **Mac と Windows で中身が違います**。ごまかさずに書きます。

**Mac（壁 + 見張り + 記録係）**

- **壁**：Claude Code 純正のサンドボックス（macOS の Seatbelt）を有効にしてあります（`configs/claude/settings.mac.json` の `sandbox` ブロック）。作業フォルダの外への書き込みと、許可していない相手への通信を、OS が力ずくで止めます（実測確認済み）
- 壁があるおかげで、**その中で完結するコマンドは確認ダイアログ無しで実行されます**（`autoAllowBashIfSandboxed`）。安全にしながら、同時に使いやすくなっています
- **見張り**：hook（`policy/safety-policy.json` + guard 系）と、`.claude/settings.json` の権限リスト（`allow` / `ask` / `deny`）
- **記録係**：監査ログと見守りモニター

**Windows（見張り + 記録係。壁はありません）**

- ⚠️ **Claude Code の OS サンドボックスは、ネイティブ Windows では使えません。** 公式が「Native Windows is not supported. On Windows, run Claude Code inside a WSL2 distribution.」と明記しています。そのため Windows 用の設定ファイルには `sandbox` を意図的に書いていません
- Windows の Claude Code は**見張り（hook と権限リスト）と記録係だけ**で守ります。壁も欲しい場合は、Codex を使う（Codex は Windows でも壁が効きます）か、Claude Code を WSL2 の中で動かしてください

**両方に共通する、いちばん大事な注意**

**壁は「読み取り」を止めません。** Claude Code が作るサンドボックスの設定にも「ファイルの読み取りは許可」が入っています。`.env` や SSH 鍵のような秘密ファイルの読み取りを止めているのは、壁ではなく**見張り**（下の `permissions.deny`）のほうです。だから Mac で壁を入れたあとも、見張りの hook は 1 本も外していません。

言葉の意味（壁・見張り・記録係）は [00_はじめに.md](00_はじめに.md) の「守られ方の言葉づかい」を、守れる／守れないの全体像は [docs/90_守れる-守れない.md](90_守れる-守れない.md) を見てください。

> **導入（インストール）が作業フォルダを Claude の「信頼済み」に登録します。** この登録が無いと、Claude Code は権限の設定そのものを無視してしまいます。**別のフォルダで作業したくなったら**、スタートフォルダの **「（上級）14_新しい作業フォルダを安全にする」** をダブルクリックして、そのフォルダを選んでください（安全ルール・見張り・信頼済み登録がまとめて入ります）。

### v1.2.1 で追加：Claude Code 内部ツールの deny

Day3 の実機検証で「Codex CLI が**内部 WebFetch でサイト読み取り** + **内部 Write でデスクトップに HTML 生成**」を素通りさせたことが判明しました。AI CLI には**シェル経由ツール**（壁と承認ダイアログが効く）と、**内部ツール**（CLI 本体が直接 OS の機能を呼ぶので壁を素通りする）の 2 種類があり、AI は便利な内部ツールを選びがちです。**壁は Bash の子プロセスにしか効かない**ので、内部ツールは見張りで止めるしかありません。

Claude Code は `.claude/settings.json` の `permissions.deny` に**内部ツール単位の deny** を書けるため、v1.2.1 から次を deny に追加しました（`configs/claude/settings.{mac,windows}.json`）。

- **WebFetch (exfil ドメイン)**：`gist.github.com` / `gist.githubusercontent.com` / `pastebin.com` / `hastebin.com` / `0x0.st` / `transfer.sh` / `file.io` / `anonfiles.com` — プロンプトインジェクション経由のデータ流出経路を塞ぐ
- **Write / Edit (シークレット)**：`.env` / `.env.*` / `.ssh/**` — AI が `.env` や SSH 鍵を書き換えられない
- **Read (シークレット)**：`.env` / `.env.*` / `.ssh/**` / `.aws/**` / `.azure/**` / `.kube/**` / `.config/gcloud/**` / `.docker/config.json` / `.npmrc` / `.pypirc` — AI が API キー・クラウド認証ファイルを読み取れない（**API キー漏洩を防いでいる最重要の見張り**。壁は読み取りを止めないので、ここが無いと秘密が読まれます）

Desktop / Documents 配下への Write/Edit は deny **しません**（受講者の通常作業を阻害しないため）。代わりに「シークレットを直接保護する」方向で守ります。

> Codex CLI 側にはツール単位 deny が存在しないため、これは **Claude Code 利用者のみが受ける恩恵**です。Codex は引き続き、承認ダイアログ・このパッケージの hook（見張り）・OS サンドボックス（壁）で守ります。

## ステップ 5：動作確認（重要）

実際に防御が効いているか確認します。

### Mac

```bash
~/Documents/my-ai-workspace/.ai-safety/hooks/macos/doctor.sh ~/Documents/my-ai-workspace
```

### Windows

```powershell
powershell -File "$env:USERPROFILE\Documents\my-ai-workspace\.ai-safety\hooks\windows\doctor.ps1"
```

`pass=10 fail=0` と出ればOKです。10 種の攻撃がすべてブロックされていることを確認できます。

## Codex との操作の共通点

Day4 で習った以下のやり方は Claude Code でも全く同じです。

### 承認プロンプト（黄色）

AI が危ないコマンドを実行しようとすると、実行前にプロンプトが出ます。

```
[?] Allow this command?
$ rm -rf data/
Yes / No
```

**読む。判断する。許可した場合だけ Yes を押す。**怪しければ No 。この習慣が最強の防御です。

### Workspace フォルダ外での作業は避ける

最初から `~/Documents/my-ai-workspace` 内で作業を始めます。

```bash
cd ~/Documents/my-ai-workspace
# ここで claude を起動

# workspace 内にプロジェクトを作る
claude create my-project
```

## 料金・API 制限について

Claude Code を使うには **Claude の有料プラン（Pro 以上）** が必要です。**無料プランでは使えません。**

- プランの種類と料金は公式ページで確認してください：https://claude.com/pricing
- 料金・利用上限は変わることがあるので、このドキュメントには固定額を書きません

使用量は [Anthropic のコンソール](https://console.anthropic.com) で確認できます。

## 個人利用での情報セキュリティ

このパッケージはあなたの **PC 内の安全を守る** 装置です。情報管理は別です。

| 守る範囲 | 説明 |
|---|---|
| ✅ 守る | あなたの PC が乗っ取られるリスク、ファイル破壊、無関係な外部通信 |
| ❌ 守らない | AI プロバイダのサーバーに送信されたデータ、あなたが AI に直接ペーストした機密情報 |

**チャット欄に本物の API キー・パスワード・顧客情報を直接ペーストしない。** これだけは利用者責任です。

### 業務情報の扱い

個人事業・副業で顧客情報を扱う場合：

- 使う前に顧客 / 契約書 / 弁護士に相談
- 個人 ID（氏名・メール・電話）は AI に渡さない
- プロダクトの仕様や金額・数値例は「実在しない架空データ」で置き換える
- 「〇〇さんの売上が減ってる」→「顧客A の売上が減ってる」に言い換える

## 困ったときの確認リスト

### Claude Code がインストールできない

```bash
npm install -g @anthropic-ai/claude-code@latest
```

が失敗する場合：

- Node.js が最新か確認（`node --version`）
- Windows では管理者権限で PowerShell を実行

#### 権限エラーが出た場合（推奨：ローカルインストール）

`EACCES` などの権限エラーが出るのは、`npm` がシステム領域（`/usr/local/lib` 等）にグローバルインストールしようとするためです。**まずは権限が要らない方法から**試してください。

1. **`nvm` を使って node 自体をユーザー領域に置く**（一番おすすめ）
   - macOS: `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash`
   - Windows: [nvm-windows](https://github.com/coreybutler/nvm-windows) を使う
   - nvm 経由で入れた node は `~/.nvm/versions/node/...` 配下にあるので、グローバルインストールにも sudo / 管理者権限が要りません

2. **`npm` の prefix をユーザー領域に変更する**（nvm を入れずに済ます方法）
   ```bash
   mkdir -p ~/.npm-global
   npm config set prefix ~/.npm-global
   # PATH に ~/.npm-global/bin を追加（~/.zshrc 等に export PATH=~/.npm-global/bin:$PATH）
   npm install -g @anthropic-ai/claude-code@latest
   ```

#### 最終手段：`--force`（非推奨）

上の方法が使えない / うまく動かない場合の**最後の手段**としてのみ：

```bash
npm install -g @anthropic-ai/claude-code@latest --force
```

`--force` は依存関係の解決エラーや権限関連の警告を **黙らせる** ためのフラグです。本来は「原因を調べて直すべきエラー」まで通してしまうので、極力使わないでください。使った場合は「なぜそれが必要だったのか」を後で講師に共有して、根本原因を残さないようにすること。

### ログイン画面が出ない

```bash
claude logout
claude login
```

で再認証します。

### Launcher が起動しない

Launcher スクリプト（`launch-claude-safe.sh` または `.ps1`）が実行権限を失っている可能性があります。

**Mac**：
```bash
chmod +x ~/Documents/my-ai-workspace/.ai-safety/hooks/macos/launch-claude-safe.sh
```

> `my-ai-workspace` はインストール時に指定したワークスペースフォルダ名に読み替えてください。

**Windows**：PowerShell のExecutionPolicy を確認
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 「API キーが無い」エラーが出る

Pro プラン以上に登録済みか、Anthropic コンソールで確認してください。無料プランのアカウントでは Claude Code は使えません。

## もう少し深く知りたい人へ

- 守れること / 守れないこと、すべてのリスク：[docs/90_守れる-守れない.md](90_守れる-守れない.md)
- サンドボックスの仕組み、Mac と Windows の防御の違い：[docs/92_AIの仕組みと隔離技術.md](92_AIの仕組みと隔離技術.md)
- ログインできない、謎のフォルダが増えた等の FAQ：[docs/99_known_issues.md](99_known_issues.md)

## 質問・報告

- 講座期間中は講師へ
- 講座終了後は [20_卒業後ガイド.md](20_卒業後ガイド.md) の「困ったときの調べ方」の順に自分で確かめてください（10_困ったとき診断 → 99_既知の問題 → AI コーチ）

---

**最後に一言**：AI は強力ですが、ブレーキとガードレールがあるからこそ安心して使えます。このパッケージがあれば、慌てずに「まず読む、判断する、許可する」という習慣が身につきます。それが何より大事です。
