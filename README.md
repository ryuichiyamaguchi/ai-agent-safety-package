# AI エージェント安全運用パッケージ v1.2.0

Codex CLI、Claude Code、Gemini CLI を「あなたを守る安全装置」付きで使うためのパッケージです。

業務で使う本物のプロジェクトでも安心して AI エージェントを動かせるように設計されています。学校 PC でも、自宅 PC でも同じように動きます。

## このパッケージを使うとどうなるか

AI が暴走したり、騙されたりしても、以下のような事故が**仕組みで止まる**ようになります。

- 自分の認証情報（`.env`、`.ssh`、`.aws` など）を AI が外に送ろうとしても止まる
- AI が `curl` や `wget` で外部にデータを送ろうとしても止まる
- AI が `rm -rf` のような危険コマンドを実行しようとしても、承認なしには動かない
- 認可していない外部 Web ページを AI が読みに行こうとしても止まる
- workspace の外側にファイルを書き込もうとしても OS レベルで止まる


## v1.2.0 の防御 4 層（ざっくり）

このパッケージは、Codex CLI / Claude Code に対して下記 4 層を同時に効かせます。

1. **OS サンドボックス**：macOS Seatbelt / Windows native の `workspace-write` モード（workspace 外への書き込みを OS が拒否）
2. **ネットワーク遮断**：`network_access = false`（curl / wget / 外部送信を全ブロック）
3. **環境変数の除外**：`OPENAI_API_KEY` 等のシークレット環境変数を AI に渡さない
4. **承認ポリシー untrusted + hook permission lockdown**：Codex の trusted list（`cat` / `ls` / `sed` 等の安全コマンド）以外が来たときに承認ダイアログを出し、加えて Claude Code 側は hook と `permissions.deny` で危険コマンドを事前ブロック（v1.1.0 の Security Hardening Release で強化）

特に 4 の `approval_policy = "untrusted"` は v1.0.9 で導入した中核の防御で、v1.1.0 で hook permission lockdown と doctor drill が加わりました。これは「全部止まる」スイッチではありません。`python -c "open('.env')..."`、`curl https://attacker/`、`rm -rf`、`git push --force` のような **trusted list 外**のコマンドが来たときに確認ダイアログを出します。一方、`cat ~/.ssh/id_rsa` のように trusted コマンド（`cat`）+ 危険な引数の組合せでは approval は出ず、2 層目（hook / policy.json）や 1 層目（OS サンドボックス）が止めます。**3 層のどこかで止まれば安全**というモデルです。

> 詳細は [docs/90_守れる-守れない.md](docs/90_守れる-守れない.md) の「なぜ『安全』は 3 層で成り立つのか」を参照してください。

> 注意：`approval_policy` が効くのは Codex CLI を**対話モード（TUI）で起動した時だけ**です。`codex exec` のような非対話モードは自動的に `never` に降格されるため、`launch-codex-safe` スクリプトから起動する運用を徹底してください。

## あなたが守るべき 3 つのこと

仕組みが多くを守りますが、以下の 3 点だけは利用者責任です。

1. **本物の秘密情報（API キー、パスワード、顧客情報）をチャット欄に直接ペーストしない**
2. **安全パッケージを入れた `safe-workspace`（または自分のプロジェクト）の中で AI を起動する**
3. **アップデート時は `doctor` スクリプトを必ず走らせる**

この 3 点を守れば、AI を本気で使い倒せます。

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
