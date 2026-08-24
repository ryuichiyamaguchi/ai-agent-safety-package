# 自宅 Mac で使う

自分の Mac で AI エージェント安全運用パッケージ v1.18.0 を使う手順です。

> **このページは在校中（講座期間中）向けです。** 卒業した方・もうすぐ卒業する方は、まず [20_卒業後ガイド.md](20_卒業後ガイド.md) を読んでください。

> ## 🚀 まず [00_クイックスタート.md](00_クイックスタート.md) を試してください
>
> **`1_安全パッケージを準備-Mac.command` を右クリック → 「開く」**するだけでステップ 1〜4 を自動実行します。下の手動手順は、ワンクリックで失敗した場合の予備手段として残しています。
>
> 最新の macOS で「ゴミ箱に入れる / 完了」しか出ない場合の対処法も `00_クイックスタート.md` の Mac 章を見てください。

## Mac の利点

Mac では macOS の **Seatbelt**（`sandbox-exec`）という OS の隔離機構が使えます。このパッケージの言葉でいう「**壁**」です。**Codex CLI と Claude Code の両方**が Mac では壁つきで動きます（Windows の Claude Code には壁がありません）。

ただし壁が止めるのは「**作業フォルダの外への書き込み**」と「**許可していない相手への通信**」だけで、**読み取りは止まりません**。秘密ファイルの読み取りを止めているのは、壁ではなく「**見張り**」（このパッケージの hook と権限リスト）のほうです。言葉の意味は [00_はじめに.md](00_はじめに.md) の「守られ方の言葉づかい」を見てください。

## 前提

- macOS Monterey (12) 以降推奨
- 使いたい AI の CLI がインストール済み（例：Codex CLI なら `codex --version` が動く。入れ方は [09_各AIのインストール.md](09_各AIのインストール.md)）
- Bash 環境（標準で入っている）

## ステップ 1：パッケージのダウンロード

GitHub の Release ページから最新版の ZIP をダウンロード。

ダウンロード先：`~/Downloads` または `~/Desktop`

## ステップ 2：展開

Finder で ZIP をダブルクリック → 同じ場所に展開されます。

## ステップ 3：インストール

ターミナル（アプリケーション → ユーティリティ → ターミナル）を開いて：

```bash
cd ~/Downloads/ai-agent-safety-package-v1
bash scripts/macos/install.sh ~/Documents/my-ai-workspace
```

`my-ai-workspace` は好きな名前に変更可。

グローバルの Claude 設定も上書きしたい場合：

```bash
bash scripts/macos/install.sh ~/Documents/my-ai-workspace --global-claude
```

## ステップ 4：動作確認

```bash
~/Documents/my-ai-workspace/.ai-safety/hooks/macos/doctor.sh ~/Documents/my-ai-workspace
```

`pass=10 fail=0` を確認。

## ステップ 5：使う

```bash
cd ~/Documents/my-ai-workspace
bash .ai-safety/hooks/macos/launch-codex-safe.sh
```

これで Codex CLI が**対話モード（TUI）**で安全装置付きに起動します。

本パッケージの launcher は次の構成を強制します。

- **壁**（`--sandbox workspace-write`）：workspace 外への書き込みを macOS Seatbelt が OS レベルで拒否します
- **見張り**（hook = `policy/safety-policy.json`）：危ないやり方をリストと照らして実行前に止めます
- **見張り**（`--ask-for-approval on-request`）：モデルが「これは確認が要る」と判断したときに、**実行前に承認プロンプト**を出します
- `shell_environment_policy.exclude`：`OPENAI_API_KEY` などのシークレット環境変数を AI に渡しません
- **記録係**：起きたことは監査ログと見守りモニターに残ります

**正直に書いておくこと**

- **通信は止めていません**（`network_access = true`）。調べもの・パッケージ取得・API の動作確認を止めないためです。`curl` や `wget` 自体も自動ブロックしません。外への持ち出しは、匿名アップロード先の拒否や秘密パターンの検出といった**見張り側**で防ぎます。
- **Seatbelt は「読み取り」を止めません。** Codex が作るサンドボックスの設定には「ファイルの読み取りは許可」が明示的に入っています（実測で `~/.ssh/config` の中身が読めることを確認済み）。秘密ファイルの読み取りを止めているのは見張り（hook）のほうです。

`rm -rf` や `git push --force` のような取り返しのつかない操作は、承認プロンプトが出る（そこで「いいえ」を押せば実行されない）か、見張り（hook）が**先に**拒否します。`cat ~/.ssh/id_rsa` のように「安全なコマンド + 危険な引数」の組合せでは承認プロンプトが出ないことがありますが、そこは見張りが受け止めます。**壁・見張り・記録係のどこかで止まれば安全**というモデルです。詳細は `docs/90_守れる-守れない.md` を参照。

> 注意：本パッケージの `approval_policy = "on-request"` が効くのは **Codex CLI を対話モード（TUI）で起動した時だけ**です。`codex exec` のような非対話モードは強制的に `never` に降格されます。必ず上記の launcher 経由で起動してください。

Claude Code の場合：

```bash
bash .ai-safety/hooks/macos/launch-claude-safe.sh
```

> Mac の Claude Code には、Claude Code 純正の**壁**（Seatbelt）を有効にしてあります（実測で、作業フォルダの外へ書き込もうとすると OS に拒否されることを確認済み）。壁があると、その中で完結する作業は確認ダイアログ無しで進むので、**安全と同時に使いやすくなります**。ここでも読み取りは壁では止まらないので、見張り（hook）は 1 本も外していません。

## 自分の本物のプロジェクトで使う

`my-ai-workspace` の中に作業フォルダを置く、または既存のプロジェクトに直接インストールすることもできます。

```bash
bash scripts/macos/install.sh /path/to/your/existing/project
```

既存の `.claude/`、`.codex/`、`.gemini/` 設定はバックアップを取った上で上書きされます。

## バックアップ / リストア / アップデート

```bash
bash .ai-safety/hooks/macos/backup.sh
bash .ai-safety/hooks/macos/update-safety.sh
bash .ai-safety/hooks/macos/restore.sh
```

## Apple Silicon Mac での注意

Codex CLI が動かないケースが報告されています。`codex --version` でバージョン確認できない場合は、Codex CLI を Rosetta 経由でインストールし直す必要があるかもしれません。

```bash
arch -x86_64 npm install -g @openai/codex
```

## 困った時

- `doctor` で fail → 講師へ
- Gatekeeper 警告（「開発元未確認」）→ 同梱スクリプトは未署名なので警告が出ることがあります。「右クリック → 開く」で初回のみ実行許可してください
- ZIP 展開後に実行権限が落ちた → `chmod +x .ai-safety/hooks/macos/*.sh`

## もう一歩深く知りたい人へ

- 守れること／守れないこと、Computer Use / Cowork / ブラウザ ChatGPT が守備範囲外な理由：`docs/90_守れる-守れない.md`
- VM・サンドボックスの違い、Mac の TCC と Windows の防御モデル比較：`docs/92_AIの仕組みと隔離技術.md`
- PC 内の謎フォルダ・謎ファイル FAQ（`~/Library/Application Support/Claude/` が 20GB ある等）：`docs/99_known_issues.md`
