# AI エージェント安全運用パッケージ v1.12.0

Codex CLI、Claude Code、Gemini CLI を「あなたを守る安全装置」付きで使うためのパッケージです。

業務で使う本物のプロジェクトでも安心して AI エージェントを動かせるように設計されています。学校 PC でも、自宅 PC でも同じように動きます。

## このパッケージを使うとどうなるか

AI が暴走したり、騙されたりしても、以下のような事故が**仕組みで止まる**ようになります。

- 自分の認証情報（`.env`、`.ssh`、`.aws` など）を AI が外に送ろうとしても止まる
- AI が `curl` や `wget` で外部にデータを送ろうとしても止まる
- AI が `rm -rf` のような危険コマンドを実行しようとしても、承認なしには動かない
- 認可していない外部 Web ページを AI が読みに行こうとしても止まる
- workspace の外側にファイルを書き込もうとしても OS レベルで止まる


## Gemini CLI / Antigravity CLI 並立対応（v1.3.0〜）

Google から「Gemini CLI は **2026-06-18** で Pro / Ultra / 無料ティアの提供を終了し、後継の **Antigravity CLI（`agy`）** に移行する」と発表されました（Enterprise / Workspace ティアは対象外）。

本パッケージ v1.3.0 は **両方の CLI を並立サポート** します:

| CLI | launcher | 状態 |
|---|---|---|
| Gemini CLI 0.41.2 | `launch-gemini-safe.{sh,ps1}` | 廃止期限 2026-06-18 まで利用可 |
| Antigravity CLI (`agy`) | `launch-agy-safe.{sh,ps1}` | **v1.3.0 で新規追加** |

- agy を入れている人は `launch-agy-safe.*` を、Gemini CLI のままの人は `launch-gemini-safe.*` を使ってください
- **新規受講者は agy を推奨**します（公式の継続サポート対象）
- agy 起動後は `/settings` UI を開いて `configs/agy/recommended-settings.json` の値に揃えてください（特に `allow_access_gitignore: false` と Secure Mode 推奨）
- 廃止期限 2026-06-18 以降の運用は v1.3.x のリリースノートで案内予定

詳しくは [docs/99_known_issues.md](docs/99_known_issues.md) の「Gemini CLI → Antigravity CLI 並立対応」セクション。

## v1.5.0 の防御 4 層（ざっくり）

このパッケージは、Codex CLI / Claude Code に対して下記 4 層を同時に効かせます。

1. **OS サンドボックス**：macOS Seatbelt / Windows native の `workspace-write` モード（workspace 外への書き込みを OS が拒否）
2. **ネットワーク遮断**：`network_access = false`（curl / wget / 外部送信を全ブロック）
3. **環境変数の除外**：`OPENAI_API_KEY` 等のシークレット環境変数を AI に渡さない
4. **承認ポリシー untrusted + hook permission lockdown**：Codex の trusted list（`cat` / `ls` / `sed` 等の安全コマンド）以外が来たときに承認ダイアログを出し、加えて Claude Code 側は hook と `permissions.deny` で危険コマンドを事前ブロック（v1.1.0 の Security Hardening Release で強化）

特に 4 の `approval_policy = "untrusted"` は v1.0.9 で導入した中核の防御で、v1.1.0 で hook permission lockdown と doctor drill が加わりました。これは「全部止まる」スイッチではありません。`python -c "open('.env')..."`、`curl https://attacker/`、`rm -rf`、`git push --force` のような **trusted list 外**のコマンドが来たときに確認ダイアログを出します。一方、`cat ~/.ssh/id_rsa` のように trusted コマンド（`cat`）+ 危険な引数の組合せでは approval は出ず、2 層目（hook / policy.json）や 1 層目（OS サンドボックス）が止めます。**4 層のどこかで止まれば安全**というモデルです。

> 詳細は [docs/90_守れる-守れない.md](docs/90_守れる-守れない.md) の「なぜ『安全』は 4 層で成り立つのか」を参照してください。

> 注意：`approval_policy` が効くのは Codex CLI を**対話モード（TUI）で起動した時だけ**です。`codex exec` のような非対話モードは自動的に `never` に降格されるため、`launch-codex-safe` スクリプトから起動する運用を徹底してください。

## あなたが守るべき 3 つのこと

仕組みが多くを守りますが、以下の 3 点だけは利用者責任です。

1. **本物の秘密情報（API キー、パスワード、顧客情報）をチャット欄に直接ペーストしない**
2. **安全パッケージを入れた `safe-workspace`（または自分のプロジェクト）の中で AI を起動する**
3. **アップデート時は `doctor` スクリプトを必ず走らせる**

この 3 点を守れば、AI を本気で使い倒せます。

## v1.5.0 で追加：DeepSeek 版ランチャー・集約インストール doc・stdin 修正

- **DeepSeek バックエンド版 Claude Code ランチャー** — Claude Code の UI のまま推論バックエンドを DeepSeek に切り替えて起動するラッパー。本パッケージの 4 層防御・ガードはそのまま効きます。
- **各 AI 集約インストール doc** — Codex / Claude / Gemini / DeepSeek の導入手順を 1 か所にまとめた集約ドキュメントを追加。
- **ガード / secret-scan の UTF-8 stdin 修正** — 日本語等のマルチバイト入力を stdin 経由で渡したときの文字化け・誤判定を修正。
- **doctor の Continue 化** — `doctor` を 1 件 FAIL で停止せず、全 drill を走り切ってからまとめて結果表示するように変更（問題の全体像を一度に把握できる）。

## v1.4.0／v1.4.1 で追加：外部 LLM 用 機微情報スキャナ

DeepSeek 等の **外部 / 中国系 LLM** を使うときの「プロンプトに API キーや顧客情報をうっかり混ぜて送信してしまう事故」を防ぐためのツールを追加しました。これは本パッケージの 4 層防御とは別軸（「ローカル PC で何をするか」ではなく「プロンプトに何を書いて外に送るか」）の補助層です。

### 提供ツール

- `secret-scan` — プロンプト本文を `[MASKED:type]` に置換するスキャナ（OpenAI / Anthropic / Google / AWS / GitHub / Slack / JWT / 秘密鍵 / 一般パターン）
- `safe-paste` — クリップボードをスキャン + マスキング + 書き戻しするワンライナー
- `deepseek-safe` — DeepSeek を使う前の念押しゲート（赤い警告 + `yes/no` 確認）

### 推奨ワークフロー

```
1. deepseek-safe                # 念押し確認
2. プロンプトを書いて ⌘C
3. safe-paste                   # クリップボード内をマスキング
4. DeepSeek の Web UI に ⌘V
```

詳細は [docs/08_外部LLMを安全に使う.md](docs/08_外部LLMを安全に使う.md) を参照。

監査ログ: `~/.ai-safety/logs/secret-scan-events.jsonl`（本物の値は記録されず、タイプ別件数のみ）

## v1.3.0 で追加：Antigravity CLI launcher（並立対応）

Gemini CLI の後継 **Antigravity CLI (`agy`)** 用に、`scripts/{macos,windows}/launch-agy-safe.{sh,ps1}` を新規追加しました。`launch-codex-safe.*` / `launch-gemini-safe.*` と同じ流れで使えます。

- 起動時に `--sandbox` フラグを**強制付与** → agy のターミナル制限サンドボックスが必ず効く
- `--add-dir <workspace>` で作業ディレクトリを明示し、workspace 外への混入を抑制
- agy 1.0.1 以降の `proceed-in-sandbox` permission mode と組み合わせて、サンドボックス内のターミナルコマンドのみ自動承認、サンドボックスを抜けようとした時のみ手動承認
- 初回起動時に「推奨セキュリティ設定があります」というヒントを表示（`configs/agy/recommended-settings.json` の値を `/settings` UI で揃える案内）

受講者が `/settings` UI で OFF にすべき項目（agy はユーザー単位の設定ファイルしか持たないため launcher で強制不可、UI 設定が必要）:

- `allow_access_gitignore` → `false`（`.gitignore` 記載ファイル＝`.env` 等への AI 読み取りをブロック）
- `allow_edit_gitignore` → `false`
- `allow_auto_run_commands` → `false`
- agy の **Secure Mode** を ON（最強の防御層、強く推奨）

これらを完全に守らない場合、PromptArmor が報告した `cat .env → webhook.site` 系の exfil シナリオは agy デフォルト設定下で成立します。詳細は [docs/99_known_issues.md](docs/99_known_issues.md) と `configs/agy/README.md` を参照。

## v1.2.1 で追加：Claude Code 内部ツールの deny（v1.3.0 でも継続）

Day3 の実機検証で「AI が内部 WebFetch / Write を選ぶとシェル経由の防御を素通り」する事実が判明。v1.2.1 で **Claude Code の `permissions.deny` に内部ツール単位の deny** を追加し、次を止めます（`configs/claude/settings.{mac,windows}.json`）。

- **WebFetch** の **exfil 危険ドメイン** (`gist.github.com` / `pastebin.com` / `transfer.sh` / `0x0.st` 等 8 ドメイン)
- **Write / Edit** の **`.env` / `.ssh/**`** 書き換え
- **Read** の **`.env` / `.ssh/**` / `.aws/**` / `.azure/**` / `.kube/**` / `.config/gcloud/**` / `.docker/config.json` / `.npmrc` / `.pypirc`** 読み取り

「Desktop / Documents への Write/Edit は許可」のまま据え置き（受講者の通常作業を阻害しないため）。**API キー漏洩防止**が最重要なので、シークレット系を直接守る方針です。Codex CLI 側にはツール単位 deny が現状存在しないため、これは Claude Code 利用者のみが受ける恩恵です。詳細は [docs/05_Claude_Codeを安全に使う.md](docs/05_Claude_Codeを安全に使う.md) を参照。

## v1.2.0 で追加：agent-monitor（動きを横で見る）

v1.2.0 から、AI が承認を求めてくる **瞬間** に、横の画面で日本語の解説カードが自動で切り替わる **agent-monitor** が同梱されました。

- 「許可しますか？」のたびに、その操作が何をするか、何をチェックすべきかが **隣のターミナルで読める**
- ガードがブロックした時の理由もリアルタイムで分かる
- すべての出来事は監査ログ（`~/.ai-safety/logs/events-YYYY-MM-DD.jsonl`）に残る

使い方は [docs/07_AIの動きをモニターする.md](docs/07_AIの動きをモニターする.md) を見てください。AI を動かすターミナルと並べて 1 つ起動するだけです。

## どう始めるか

OS ごとに `docs/` の中の手順を読んでください。

- 学校 PC（Windows）→ [docs/01_学校PCで使う.md](docs/01_学校PCで使う.md)
- 自宅 Windows → [docs/02_自宅Windowsで使う.md](docs/02_自宅Windowsで使う.md)
- 自宅 Mac → [docs/03_自宅Macで使う.md](docs/03_自宅Macで使う.md)
- AI の動きを横で見たい → [docs/07_AIの動きをモニターする.md](docs/07_AIの動きをモニターする.md)

## 何が守れて、何が守れないか

完全防御とまではいきません。[docs/90_守れる-守れない.md](docs/90_守れる-守れない.md) を読んでください。Computer Use / Cowork / ブラウザ ChatGPT が**このパッケージの守備範囲外**であることもそこに書きました。

## AI の仕組みと隔離技術を深く知りたい人へ

VM・サンドボックス・OS 権限制御がどう違うか、Mac と Windows で防御の効き方がなぜ違うかを非エンジニア向けに解説しています。

→ [docs/92_AIの仕組みと隔離技術.md](docs/92_AIの仕組みと隔離技術.md)

## トラブル時

[docs/99_known_issues.md](docs/99_known_issues.md) を見てから、講師に連絡してください。「PC 内の謎フォルダ FAQ」も同じファイルにまとめてあります。

## 実装ドキュメント

設計者・開発者向けの実装解説は [README_IMPLEMENTATION.md](README_IMPLEMENTATION.md) を参照。
