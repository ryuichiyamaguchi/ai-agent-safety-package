# AI エージェント安全運用パッケージ v1.14.8

Codex CLI、Claude Code、OpenCode、Gemini CLI を「あなたを守る安全装置」付きで使うためのパッケージです。

業務で使う本物のプロジェクトでも安心して AI エージェントを動かせるように設計されています。学校 PC でも、自宅 PC でも同じように動きます。

## v1.14.6：macOSの日本語ファイル名の照合を修正

- macOSがZIP展開時に濁点付きの日本語ファイル名をNFD形式にしても、改ざん検知一覧のNFC形式と正しく照合
- `あんぜん.md` などが「一覧に登録されていません」と誤判定され、Macの初回インストールが中止する問題を修正
- 実ファイル本文のSHA-256検査は維持し、NFD名でも改ざん時は従来どおり導入を中止

## v1.14.4：Windowsラッパーの出力形式差へ追加対応

- Bouncer統合版のOpenCode画面に、常時表示の実行ステータスバーを追加
- OpenCodeのGateway観測値から、作業ディレクトリ、モデル、thinking、文脈残量、トークン消費、出力速度を表示
- DeepSeek V4 Pro / Flash のモデル上限を1M context / 384K outputとしてOpenCode設定へ明示
- 準備ログと設定JSONの間に改行がない出力、およびJSON形式の準備ログが混ざる出力へ対応
- JSONの位置ではなくOpenCode解決済み設定の構造で本体を一意に特定
- 安全設定らしいJSONが複数ある場合は引き続きfail-closedで停止
- 解析できない場合はGatewayの合言葉を伏せた診断ファイルを保存し、画面に場所を表示

## v1.14.3：Windows初回起動の設定JSON誤判定を修正

- `opencode debug config` の前後に初回の依存関係準備ログが混ざると、正しい安全設定でもJSONエラーとして停止する問題を修正
- 準備ログの中から解決済み設定JSONを一意に特定できる場合だけ検証し、安全設定が有効ならOpenCodeを起動
- 設定JSONが複数ある曖昧な出力や、安全設定が弱められた出力は従来どおりfail-closedで停止
- WindowsのUTF-8ファイル渡し（BOM・CRLFを含む）とMacの実ランチャー経路を回帰テスト

## v1.14.2：「最新版に更新」でOpenCode起動修正を配布

- OpenCodeの依存キャッシュ `node_modules` 内にある通常のJavaScriptや `.bin` リンクを、危険なコマンド定義と誤認して起動を止める問題を修正
- `node_modules` 自体がリンクの場合と、依存キャッシュ外の危険記法・シンボリックリンクは従来どおり起動前に遮断
- 「最新版に更新」の完了時に、実際に導入されたパッケージ版を読み戻して表示
- Mac / Windowsの両更新処理で、配布物の版と更新後ワークスペースの版が一致しなければ完了扱いにしない

## v1.14.1：OpenCode承認モニター連携

- OpenCodeの `permission.asked` / `permission.replied` をBouncerへリアルタイム反映
- 承認対象のコマンド・ファイル・URLを、「何をどこで行うか／何が変わるか／外部送信するか」まで初心者向けに表示
- 右パネルのコマンド履歴から、今日の全コマンドと意味・影響を何度でも展開して確認
- AIコーチがトークン上限で途切れた場合は未完成文を表示せず、固定ルールの解説を案内
- Bouncer犬が待機・許可目安・要確認・拒否・AI確認中の状態に連動し、吹き出しで次にすべきことを案内
- `d-claude + DeepSeek` をMac / Windowsの統合メニューへ追加し、送信検査Gateway・Claude安全フック・Bouncerモニターを同時起動
- 「今回だけ許可／常に許可／許可しない」の回答も監査履歴へ記録
- APIキー、セッションID、メッセージIDはBouncerの表示・監査ログに保存しない

## v1.14.0：Bouncer統合版とOpenCode + DeepSeek

- Mac / Windows共通のBouncer統合ランチャーと見守りUI
- 標準モードはローカルLLM不要。最大保護モードだけローカルGemmaを使用
- OpenCode + DeepSeek V4 Proを標準経路、V4 Flashを補助モデルに設定
- DeepSeek送信検査Gatewayが実キーをOpenCodeから隔離し、秘密情報を検査
- Web検索は既定OFF。明示的に有効化した時も確認制
- 統合起動時はプロジェクト固有のOpenCode設定と外部プラグインを無効化し、安全設定の迂回を防止
- `d-claude`も統合メニューから起動でき、モニター上では独立した監視対象として表示

詳しくは [docs/10_OpenCode_DeepSeekを安全に使う.md](docs/10_OpenCode_DeepSeekを安全に使う.md) を参照してください。

## このパッケージを使うとどうなるか

AI が暴走したり、騙されたりしても、以下のような事故が**仕組みで止まる**ようになります。

- 自分の認証情報（`.env`、`.ssh`、`.aws` など）を AI が外に送ろうとしても止まる
- AI が秘密情報を含む送信や匿名アップロード先への持ち出しを試みると止まる
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

## 現行プロファイルの防御 4 層（ざっくり）

このパッケージは、Codex CLI / Claude Code に対して下記 4 層を同時に効かせます。

1. **OS サンドボックス**：macOS Seatbelt / Windows native の `workspace-write` モード（workspace 外への書き込みを OS が拒否）
2. **送信先・秘密情報ガード**：秘密情報の送信・匿名アップロード・リモートコード実行（取ってきたコードのその場実行）を止める
   - ⚠️ **v1.14.0 でこの層は守りを一段ゆるめています。** v1.13.x までは `network_access = false` で curl / wget を含む外部通信を**全部**遮断していました。しかしそれでは調べものもライブラリの取得もできず AI が実用にならないため、**通常の調査・パッケージ取得は通す**方式に変えました。**「外に出る通信は全部止まる」は、もう成り立ちません。**
   - 取ってくるだけのコマンド（`curl http://...` など）を止めるかどうかは、AI の承認ダイアログと見守りモニターの判断票にゆだねています。何が自動で止まり何が止まらないかは [docs/90_守れる-守れない.md](docs/90_守れる-守れない.md) の「素のダウンロード・外部サイトの取得」を必ず読んでください。
   - ⚠️ **扱いは起動する AI ごとに違います。** Codex / Claude / Antigravity では素の `curl` / `wget` は自動では止まりませんが、**OpenCode DeepSeek 統合版だけは `curl` / `wget` そのものを拒否**します（送信検査 Gateway を迂回させないため）。エージェント別の対応表は [docs/90_守れる-守れない.md](docs/90_守れる-守れない.md) の「起動する AI によって扱いが違います」にあります。
   - ⚠️ **書き方をずらされると「何をするコマンドか」を言い当てられません。** `cat ~/.e""nv` や `echo x > ~/.z\shrc` のように引用符・バックスラッシュを挟むと、シェルは元のファイル（`.env` / `.zshrc`）をそのまま扱うのに、文字の並びで照合する自動判定は危険語を認識できません。見守りモニターはこれを難読化と見なして**緑（今回だけ許可の目安）は出しません**が、表示は「確認が必要」止まりで何をする操作かは説明されないため、**そのときは許可せず講師に確認**してください（[docs/90_守れる-守れない.md](docs/90_守れる-守れない.md)「書き方をずらした命令」）。
3. **環境変数の除外**：`OPENAI_API_KEY` 等のシークレット環境変数を AI に渡さない
4. **承認ポリシー on-request + hook permission lockdown**：モデルが確認を必要と判断した操作だけ承認画面へ回し、Claude Code / Codex のhookが秘密情報・破壊操作を独立して止める

特に 4 の `approval_policy = "untrusted"` は v1.0.9 で導入した中核の防御で、v1.1.0 で hook permission lockdown と doctor drill が加わりました。これは「全部止まる」スイッチではありません。`python -c "open('.env')..."`、`curl https://attacker/`、`rm -rf`、`git push --force` のような **trusted list 外**のコマンドが来たときに確認ダイアログを出します。一方、`cat ~/.ssh/id_rsa` のように trusted コマンド（`cat`）+ 危険な引数の組合せでは approval は出ず、2 層目（hook / policy.json）や 1 層目（OS サンドボックス）が止めます。**4 層のどこかで止まれば安全**というモデルです。

> 詳細は [docs/90_守れる-守れない.md](docs/90_守れる-守れない.md) の「なぜ『安全』は 4 層で成り立つのか」を参照してください。

> 統合版では `launch-integrated.sh <workspace> codex standard` から起動してください。内部で `launch-codex-safe` を呼び、見守りUIも同時に起動します。`approval_policy` が効くのは Codex CLI を**対話モード（TUI）で起動した時だけ**です。

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
- ブラウザ版では、AI不要の **承認判断票** が「いま押すなら／何が変わる／元に戻せる／外部送信／確認する2点」を先に表示する
- ガードがブロックした時の理由もリアルタイムで分かる
- すべての出来事は監査ログ（`~/.ai-safety/logs/events-YYYY-MM-DD.jsonl`）に残る
- OpenCode の承認画面もBouncerへ連動し、実行内容・影響・承認後の結果をリアルタイム表示する

使い方は [docs/07_AIの動きをモニターする.md](docs/07_AIの動きをモニターする.md) を見てください。AI を動かすターミナルと並べて 1 つ起動するだけです。

## どう始めるか

OS ごとに `docs/` の中の手順を読んでください。

- 学校 PC（Windows）→ [docs/01_学校PCで使う.md](docs/01_学校PCで使う.md)
- 自宅 Windows → [docs/02_自宅Windowsで使う.md](docs/02_自宅Windowsで使う.md)
- 自宅 Mac → [docs/03_自宅Macで使う.md](docs/03_自宅Macで使う.md)
- AI の動きを横で見たい → [docs/07_AIの動きをモニターする.md](docs/07_AIの動きをモニターする.md)
- OpenCode + DeepSeekを使いたい → [docs/10_OpenCode_DeepSeekを安全に使う.md](docs/10_OpenCode_DeepSeekを安全に使う.md)

## 何が守れて、何が守れないか

完全防御とまではいきません。[docs/90_守れる-守れない.md](docs/90_守れる-守れない.md) を読んでください。Computer Use / Cowork / ブラウザ ChatGPT が**このパッケージの守備範囲外**であることもそこに書きました。

## AI の仕組みと隔離技術を深く知りたい人へ

VM・サンドボックス・OS 権限制御がどう違うか、Mac と Windows で防御の効き方がなぜ違うかを非エンジニア向けに解説しています。

→ [docs/92_AIの仕組みと隔離技術.md](docs/92_AIの仕組みと隔離技術.md)

## トラブル時

[docs/99_known_issues.md](docs/99_known_issues.md) を見てから、講師に連絡してください。「PC 内の謎フォルダ FAQ」も同じファイルにまとめてあります。

## 実装ドキュメント

設計者・開発者向けの実装解説は [README_IMPLEMENTATION.md](README_IMPLEMENTATION.md) を参照。
