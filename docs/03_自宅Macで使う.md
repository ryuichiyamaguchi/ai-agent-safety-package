# 自宅 Mac で使う

自分の Mac で AI エージェント安全運用パッケージ v1.14.0 を使う手順です。

> ## 🚀 まず [00_クイックスタート.md](00_クイックスタート.md) を試してください
>
> v1.4.1 以降は **`install-one-click.command` を右クリック → 「開く」**するだけでステップ 1〜4 を自動実行します。下の手動手順は、ワンクリックで失敗した場合の予備手段として残しています。
>
> 最新の macOS で「ゴミ箱に入れる / 完了」しか出ない場合の対処法も `00_クイックスタート.md` の Mac 章を見てください。

## Mac の利点

Mac では macOS の Seatbelt サンドボックスが Codex CLI と連動します。Windows ネイティブよりも **OS レベルで強い防御**が効きます。バグはありますが、それを補う層も組み込んであります。

## 前提

- macOS Monterey (12) 以降推奨
- Cursor または VS Code がインストール済み
- Codex CLI がインストール済み（`codex --version` が動く）
- Bash 環境（標準で入っている）

## ステップ 1：パッケージのダウンロード

GitHub の Release ページから v1.5.0 の ZIP をダウンロード。

ダウンロード先：`~/Downloads` または `~/Desktop`

## ステップ 2：展開

Finder で ZIP をダブルクリック → 同じ場所に展開されます。

## ステップ 3：インストール

ターミナル（または Cursor の Terminal）を開いて：

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

v1.5.0 の launcher は次の構成を強制します。

- `--sandbox workspace-write`：workspace 外への書き込みを macOS Seatbelt が OS レベルで拒否（1 層目）
- `network_access = false`：外部通信を全遮断（2 層目）
- `shell_environment_policy.exclude`：`OPENAI_API_KEY` などのシークレット環境変数を AI に渡さない（3 層目）
- `--ask-for-approval untrusted`：Codex 内部の trusted list（`cat` / `ls` / `sed` などの安全コマンド）以外が来たときに、**実行前に承認プロンプト**を出す（4 層目）

`python -c "open('.env')..."` や `curl`、`rm -rf`、`git push --force` のような trusted list 外の操作は、承認プロンプトが出る（そこで「いいえ」を押せば実行されない）か、または hook 層（`policy/safety-policy.json`）で**先に**拒否されます。`cat ~/.ssh/id_rsa` のように trusted コマンド + 危険な引数の組合せでは approval は出ませんが、hook 層と Seatbelt が止めます。**4 層のどこかで止まれば安全**というモデルです。詳細は `docs/90_守れる-守れない.md` の「なぜ『安全』は 4 層で成り立つのか」を参照。

> 注意：v1.5.0 の `approval_policy = "untrusted"` が効くのは **Codex CLI を対話モード（TUI）で起動した時だけ**です。`codex exec` のような非対話モードは強制的に `never` に降格されます。必ず上記の launcher 経由で起動してください。

Claude Code の場合：

```bash
bash .ai-safety/hooks/macos/launch-claude-safe.sh
```

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
