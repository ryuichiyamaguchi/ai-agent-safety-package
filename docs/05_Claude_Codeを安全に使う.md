# Claude Code を安全に使う（個人利用向け）

v1.0.9

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
powershell -ExecutionPolicy Bypass -File ".ai-safety\hooks\windows\launch-claude-safe.ps1"
```

launcher が次の防御を自動で有効にします。

- `--sandbox workspace-write`：workspace の外への書き込みを OS レベルで拒否
- `network_access = false`：外部通信を全遮断
- `--ask-for-approval untrusted`：`cat`、`ls` などの安全コマンド以外は実行前に承認プロンプト
- `shell_environment_policy.exclude`：`OPENAI_API_KEY` などのシークレット環境変数を AI に渡さない

## ステップ 5：動作確認（重要）

実際に防御が効いているか確認します。

### Mac

```bash
~/Documents/my-ai-workspace/.ai-safety/hooks/macos/doctor.sh ~/Documents/my-ai-workspace
```

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Documents\my-ai-workspace\.ai-safety\hooks\windows\doctor.ps1"
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
- 権限エラーが出た場合は：`npm install -g @anthropic-ai/claude-code --force`
- Windows では管理者権限で PowerShell を実行

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
chmod +x ~/.ai-safety/hooks/macos/launch-claude-safe.sh
```

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
