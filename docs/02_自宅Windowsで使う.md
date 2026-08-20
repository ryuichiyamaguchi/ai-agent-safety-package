# 自宅 Windows で使う

自分の Windows PC で AI エージェント安全運用パッケージ v1.17.0 を使う手順です。

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

- **壁**（`--sandbox workspace-write`）：workspace 外への書き込みを OS が力ずくで拒否します。**Codex はネイティブ Windows でも壁が使える唯一の CLI**で、専用の低権限ユーザーとファイアウォール規則で境界を作ります
- **見張り**（hook = `policy/safety-policy.json`）：危ないやり方をリストと照らして実行前に止めます
- **見張り**（`--ask-for-approval on-request`）：モデルが「これは確認が要る」と判断したときに、**実行前に承認ダイアログ**を出します
- `shell_environment_policy.exclude`：`OPENAI_API_KEY` などのシークレット環境変数を AI に渡しません
- **記録係**：起きたことは監査ログと見守りモニターに残ります

**正直に書いておくこと**

- **通信は止めていません**（`network_access = true`）。調べもの・パッケージ取得・API の動作確認を止めないためです。`curl` や `wget` 自体も自動ブロックしません。外への持ち出しは、匿名アップロード先の拒否や秘密パターンの検出といった**見張り側**で防ぎます。
- **壁は「読み取り」を止めません。** 秘密ファイルの読み取りを止めているのは見張り（hook）のほうです。

`rm -rf` や `git push --force` のような取り返しのつかない操作は、承認ダイアログが出る（そこで「いいえ」を押せば実行されない）か、見張り（hook）が**先に**拒否します。`cat ~/.ssh/id_rsa` のように「安全なコマンド + 危険な引数」の組合せでは承認ダイアログが出ないことがありますが、そこは見張りが受け止めます。**壁・見張り・記録係のどこかで止まれば安全**というモデルです。詳細は `docs\90_守れる-守れない.md` を参照。

> 注意：本パッケージの `approval_policy = "on-request"` が効くのは **Codex CLI を対話モード（TUI）で起動した時だけ**です。`codex exec` のような非対話モードは強制的に `never` に降格されます。必ず上記の launcher 経由で起動してください。

Claude Code を使う場合：

```
powershell -File .ai-safety\hooks\windows\launch-claude-safe.ps1
```

> ⚠️ **Windows の Claude Code には「壁」がありません。** Claude Code の OS サンドボックスは公式に macOS / Linux / WSL2 のみ対応で、ネイティブ Windows は対象外だと明記されています（公式の原文：「Native Windows is not supported. On Windows, run Claude Code inside a WSL2 distribution.」）。Windows の Claude Code は**見張り（hook と権限リスト）と記録係だけ**で守ります。壁も欲しい場合は、Codex を使うか、Claude Code を WSL2 の中で動かしてください。

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
