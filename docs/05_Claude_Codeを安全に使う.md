# Claude Code を安全に使う（個人利用向け）

v1.5.0

## このドキュメントは誰のものか

このページは、個人で **Claude Code CLI** を使いたい受講者向けです。Day4 講義ではメインで使いませんが、興味ある方向けの案内です。

Claude Code（Anthropic 製）と Codex（OpenAI 製）は別ツールですが、このパッケージで Codex と同等の防具を装着できます。

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
- **本格利用なら Pro プラン以上**（無料枠は限定的。1 〜 2 時間分程度）

## ステップ 1：Node.js の確認

すでに Codex をインストールしていれば OK です。

```bash
node --version
npm --version
```

まだの場合は公式から：https://nodejs.org/

## ステップ 2：Claude Code をインストール

```bash
npm install -g @anthropic-ai/claude-code
claude --version
```

バージョン確認できれば成功です（`1.0.0` など）。

**参考**：公式ドキュメント https://docs.claude.com/ja/docs/claude-code/quickstart

## ステップ 3：Anthropic アカウント認証

初回実行時にブラウザが開いて「Anthropic にログインしてください」と出ます。

```bash
claude
```

ブラウザで Anthropic アカウント（Claude.ai に使うのと同じアカウント）でログインします。

**注意**：
- ChatGPT のサブスクとは別です。Anthropic の Pro プラン or Team プランに入っていれば多くのコールができます
- 無料アカウントは 1 日の制限が厳しいので、本格利用なら Pro プラン以上をおすすめします
- 初回認証後はローカルに token が保存されるので、毎回ブラウザログインは不要です

## ステップ 4：このパッケージで安全に起動する

Claude Code を **このパッケージの保護下で実行**します。

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

※ 事前に `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` を実行済みであることが前提です（docs/01 / docs/02 のステップ 0 参照）。

launcher が次の防御を自動で有効にします。

- `--sandbox workspace-write`：workspace の外への書き込みを OS レベルで拒否（1 層目）
- `network_access = false`：外部通信を全遮断（hook 層 + サンドボックス）
- `--ask-for-approval untrusted`：Codex の trusted list（`cat`、`ls` などの安全コマンド）以外が来たときに、実行前に承認プロンプトを出す（4 層目）。`cat ~/.ssh/id_rsa` のような trusted コマンド + 危険な引数の組合せは approval をスキップするので、hook 層（`policy/safety-policy.json`）が代わりに止めます。**4 層のどこかで止まれば安全**というモデル。詳細は [docs/90_守れる-守れない.md](90_守れる-守れない.md) の「なぜ『安全』は 4 層で成り立つのか」を参照
- `shell_environment_policy.exclude`：`OPENAI_API_KEY` などのシークレット環境変数を AI に渡さない

### v1.2.1 で追加：Claude Code 内部ツールの deny

Day3 の実機検証で「Codex CLI が**内部 WebFetch でサイト読み取り** + **内部 Write でデスクトップに HTML 生成**」を素通りさせたことが判明しました。AI CLI には**シェル経由ツール**（OS サンドボックス・network_access・承認ダイアログが効く）と、**内部ツール**（CLI 本体が直接 OS API を呼ぶので上記の防御を素通りする）の 2 種類があり、AI は便利な内部ツールを選びがちです。

Claude Code は `.claude/settings.json` の `permissions.deny` に**内部ツール単位の deny** を書けるため、v1.2.1 から次を deny に追加しました（`configs/claude/settings.{mac,windows}.json`）。

- **WebFetch (exfil ドメイン)**：`gist.github.com` / `gist.githubusercontent.com` / `pastebin.com` / `hastebin.com` / `0x0.st` / `transfer.sh` / `file.io` / `anonfiles.com` — プロンプトインジェクション経由のデータ流出経路を塞ぐ
- **Write / Edit (シークレット)**：`.env` / `.env.*` / `.ssh/**` — AI が `.env` や SSH 鍵を書き換えられない
- **Read (シークレット)**：`.env` / `.env.*` / `.ssh/**` / `.aws/**` / `.azure/**` / `.kube/**` / `.config/gcloud/**` / `.docker/config.json` / `.npmrc` / `.pypirc` — AI が API キー・クラウド認証ファイルを読み取れない（**API キー漏洩防止の最重要層**）

Desktop / Documents 配下への Write/Edit は deny **しません**（受講者の通常作業を阻害しないため）。代わりに「シークレットを直接保護する」方向で守ります。

> Codex CLI 側にはツール単位 deny が現状（v0.130 系）存在しないため、これは **Claude Code 利用者のみが受ける恩恵**です。Codex は引き続き approval ダイアログと OS サンドボックスで守ります。

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

Codex（ChatGPT Pro）と異なり、Claude Code は **使用量に基づく課金**です。

- **Pro プラン**：月額 $20、月 100 万トークン
- **Team プラン**：チーム向け、チーム管理者が予算を設定
- **無料アカウント**：制限あり（約 1 時間分／日）

使用量は [Anthropic の コンソール](https://console.anthropic.com) で確認できます。

**本格利用を予定する場合は、Pro プランを推奨**します。

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
npm install -g @anthropic-ai/claude-code
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
   npm install -g @anthropic-ai/claude-code
   ```

#### 最終手段：`--force`（非推奨）

上の方法が使えない / うまく動かない場合の**最後の手段**としてのみ：

```bash
npm install -g @anthropic-ai/claude-code --force
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

Pro プランに登録済みか、Anthropic コンソールで確認してください。無料アカウントは 1 時間分しか使えません。

## もう少し深く知りたい人へ

- 守れること / 守れないこと、すべてのリスク：[docs/90_守れる-守れない.md](90_守れる-守れない.md)
- サンドボックスの仕組み、Mac と Windows の防御の違い：[docs/92_AIの仕組みと隔離技術.md](92_AIの仕組みと隔離技術.md)
- ログインできない、謎のフォルダが増えた等の FAQ：[docs/99_known_issues.md](99_known_issues.md)

## 質問・報告

- 講座期間中は講師へ
- 講座終了後に問題を見つけた場合は、GitHub Issues で報告するか、メールで連絡してください（学校指定のアドレス）

---

**最後に一言**：AI は強力ですが、ブレーキとガードレールがあるからこそ安心して使えます。このパッケージがあれば、慌てずに「まず読む、判断する、許可する」という習慣が身につきます。それが何より大事です。
