# 自宅 Windows で使う

自分の Windows PC で AI エージェント安全運用パッケージ v1.16.0 を使う手順です。

> **このページは在校中（講座期間中）向けです。** 卒業した方・もうすぐ卒業する方は、まず [20_卒業後ガイド.md](20_卒業後ガイド.md) を読んでください。

> ## 🚀 まず [00_クイックスタート.md](00_クイックスタート.md) を試してください
>
> **`1_安全パッケージを準備-Windows.bat` をダブルクリックする**だけでステップ 0〜5 を自動実行します。下の手動手順は、ワンクリックで失敗した場合の予備手段として残しています。

## 前提

- Windows 10 / 11
- 自分のユーザーアカウント（管理者権限あり推奨）
- 使いたい AI の CLI がインストール済み（例：Codex CLI なら `codex --version` が動く）

CLI のインストールが未済の方は、まず以下を済ませてください（どの AI を入れるかは [00_はじめに.md](00_はじめに.md) の課金状況別の表を参照）。

- Node.js：[nodejs.org](https://nodejs.org/) から LTS 版 MSI を DL してインストール（`npm install` に必要）
- 各 AI の CLI：[09_各AIのインストール.md](09_各AIのインストール.md)（次の「ステップ 0」を済ませてから）

## ステップ 0：最初の儀式（5分・必須）

PowerShell（黒い画面）を開いて、以下の 1 行を実行してください。**CLI を `npm install` する前に必ずやってください**。

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

確認プロンプトで `Y` を押す → 完了。

**なぜ必要か**：Windows の標準設定では PowerShell スクリプトの実行が止められており、このままだと `npm` コマンド（実体は `npm.ps1`）や一部の `.ps1` スクリプトが動きません。この 1 行で「自分のユーザーの範囲だけ、署名付きスクリプトを許可する」設定に変えます（システム全体には影響しません）。

**一度実行すれば永続的に有効**です。

実行後、PowerShell を一度閉じて開き直すと確実です。その後で：

```powershell
npm install -g @openai/codex
codex --version
codex login
```

## ステップ 1：パッケージのダウンロード

GitHub の Release ページから最新版の ZIP をダウンロードします。

ダウンロード先：**ユーザーフォルダ直下**（`C:\Users\あなたの名前\`）または**デスクトップ**

## ステップ 2：展開

ZIP を右クリック →「すべて展開」→ 展開先を選んで「展開」。

## ステップ 3：インストール

エクスプローラーで展開したフォルダを開き、アドレスバーに `powershell` と入力して Enter。

開いた PowerShell で以下を実行：

```
powershell -File scripts\windows\install.ps1 -Workspace "$env:USERPROFILE\Documents\my-ai-workspace"
```

※ 事前に `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` を実行済みであることが前提です（ステップ 0 参照）。

`my-ai-workspace` は好きな名前に変更可。`Documents` 配下に作るのを推奨します。

`-InstallGlobalClaudeSettings` オプションを付けると、グローバルの Claude 設定も上書きされます（バックアップ付き）。`safe-workspace` の外で Claude を起動した時にも基本防御を効かせたい場合のみ付けてください。

```
powershell -File scripts\windows\install.ps1 -Workspace "$env:USERPROFILE\Documents\my-ai-workspace" -InstallGlobalClaudeSettings
```

## ステップ 4：動作確認

```
powershell -File "$env:USERPROFILE\Documents\my-ai-workspace\.ai-safety\hooks\windows\doctor.ps1"
```

`pass=10 fail=0` を確認。

## ステップ 5：使う

```
cd $env:USERPROFILE\Documents\my-ai-workspace
powershell -File .ai-safety\hooks\windows\launch-codex-safe.ps1
```

これで Codex CLI が**対話モード（TUI）**で安全装置付きに起動します。

本パッケージの launcher は次の構成を強制します。

- `--sandbox workspace-write`：workspace 外への書き込みを OS が拒否（1 層目）
- `network_access = false`：外部通信を全遮断（2 層目）
- `shell_environment_policy.exclude`：`OPENAI_API_KEY` などのシークレット環境変数を AI に渡さない（3 層目）
- `--ask-for-approval untrusted`：Codex 内部の trusted list（`cat` / `ls` / `sed` などの安全コマンド）以外が来たときに、**実行前に承認ダイアログ**を出す（4 層目）

`python -c "open('.env')..."` や `curl`、`rm -rf`、`git push --force` のような trusted list 外の操作は、承認ダイアログが出る（そこで「いいえ」を押せば実行されない）か、または hook 層（`policy/safety-policy.json`）で**先に**拒否されます。`cat ~/.ssh/id_rsa` のように trusted コマンド + 危険な引数の組合せでは approval は出ませんが、hook 層と OS サンドボックスが止めます。**4 層のどこかで止まれば安全**というモデルです。詳細は `docs\90_守れる-守れない.md` の「なぜ『安全』は 4 層で成り立つのか」を参照。

> 注意：本パッケージの `approval_policy = "untrusted"` が効くのは **Codex CLI を対話モード（TUI）で起動した時だけ**です。`codex exec` のような非対話モードは強制的に `never` に降格されます。必ず上記の launcher 経由で起動してください。

Claude Code を使う場合：

```
powershell -File .ai-safety\hooks\windows\launch-claude-safe.ps1
```

## 自分の本物のプロジェクトで使う

`my-ai-workspace` の中に自分の業務プロジェクトのファイルを置けば、そのまま安全装置付きで作業できます。

ただし以下を守ってください：

- 本物の `.env` を置いてもよい（hook と承認ダイアログが二重で保護してくれる）
- 本物の API キー類をチャット欄に直接ペーストしない
- アップデート時は `doctor` を再実行

## バックアップ / リストア / アップデート

```
powershell -File .ai-safety\hooks\windows\backup.ps1
powershell -File .ai-safety\hooks\windows\update-safety.ps1
powershell -File .ai-safety\hooks\windows\restore.ps1
```

## 困った時

- `doctor` で fail → そのまま使わない、`docs\99_known_issues.md` を見る、講師へ
- インストールエラー → 管理者権限で再実行を試す
- Codex / Claude のメジャーアップデート後 → `update-safety.ps1` を走らせる

## もう一歩深く知りたい人へ

- 守れること／守れないこと、Computer Use / Cowork / ブラウザ ChatGPT が守備範囲外な理由：`docs\90_守れる-守れない.md`
- VM・サンドボックスの違い、Mac との防御モデル比較：`docs\92_AIの仕組みと隔離技術.md`
- PC 内の謎フォルダ・謎ファイル FAQ：`docs\99_known_issues.md`
