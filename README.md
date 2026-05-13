# AI エージェント安全運用パッケージ v1.0.3

Codex CLI、Claude Code、Gemini CLI を「あなたを守る安全装置」付きで使うためのパッケージです。

業務で使う本物のプロジェクトでも安心して AI エージェントを動かせるように設計されています。学校 PC でも、自宅 PC でも同じように動きます。

## このパッケージを使うとどうなるか

AI が暴走したり、騙されたりしても、以下のような事故が**仕組みで止まる**ようになります。

- 自分の認証情報（`.env`、`.ssh`、`.aws` など）を AI が外に送ろうとしても止まる
- AI が `curl` や `wget` で外部にデータを送ろうとしても止まる
- AI が `rm -rf` のような危険コマンドを実行しようとしても、承認なしには動かない
- 認可していない外部 Web ページを AI が読みに行こうとしても止まる
- workspace の外側にファイルを書き込もうとしても OS レベルで止まる

これは「演習用おもちゃ」ではなく、**3 ヶ月以上の実運用に耐える本物の安全装置**です。

## v1.0.3 の防御 4 層（ざっくり）

このパッケージは、Codex CLI / Claude Code に対して下記 4 層を同時に効かせます。

1. **OS サンドボックス**：macOS Seatbelt / Windows native の `workspace-write` モード（workspace 外への書き込みを OS が拒否）
2. **ネットワーク遮断**：`network_access = false`（curl / wget / 外部送信を全ブロック）
3. **環境変数の除外**：`OPENAI_API_KEY` 等のシークレット環境変数を AI に渡さない
4. **承認ポリシー untrusted**：`cat` / `ls` / `sed` 等の安全コマンド以外は、実行前に必ず承認ダイアログを出す

特に 4 の `approval_policy = "untrusted"` は v1.0.3 で導入した中核の防御です。`python -c "open('.env')..."`、`curl https://attacker/`、`rm -rf`、`git push --force` などはこの層で止まります。

> 注意：`approval_policy` が効くのは Codex CLI を**対話モード（TUI）で起動した時だけ**です。`codex exec` のような非対話モードは自動的に `never` に降格されるため、`launch-codex-safe` スクリプトから起動する運用を徹底してください。

## あなたが守るべき 3 つのこと

仕組みが多くを守りますが、以下の 3 点だけは利用者責任です。

1. **本物の秘密情報（API キー、パスワード、顧客情報）をチャット欄に直接ペーストしない**
2. **安全パッケージを入れた `safe-workspace`（または自分のプロジェクト）の中で AI を起動する**
3. **アップデート時は `doctor` スクリプトを必ず走らせる**

この 3 点を守れば、AI を本気で使い倒せます。

## どう始めるか

OS ごとに `docs/` の中の手順を読んでください。

- 学校 PC（Windows）→ [docs/01_学校PCで使う.md](docs/01_学校PCで使う.md)
- 自宅 Windows → [docs/02_自宅Windowsで使う.md](docs/02_自宅Windowsで使う.md)
- 自宅 Mac → [docs/03_自宅Macで使う.md](docs/03_自宅Macで使う.md)

## 何が守れて、何が守れないか

正直に書いてあります。[docs/90_守れる-守れない.md](docs/90_守れる-守れない.md) を読んでください。Computer Use / Cowork / ブラウザ ChatGPT が**このパッケージの守備範囲外**であることもそこに書きました。

## AI の仕組みと隔離技術を深く知りたい人へ

VM・サンドボックス・OS 権限制御がどう違うか、Mac と Windows で防御の効き方がなぜ違うかを非エンジニア向けに解説しています。

→ [docs/92_AIの仕組みと隔離技術.md](docs/92_AIの仕組みと隔離技術.md)

## トラブル時

[docs/99_known_issues.md](docs/99_known_issues.md) を見てから、講師に連絡してください。「PC 内の謎フォルダ FAQ」も同じファイルにまとめてあります。

## ライセンス・著作

職業訓練校マーケティング制作講座 Day4（2026-05-15）のために制作。設計の元は中島大介氏（株式会社メリル）の「Claude Code Safety Hub」思想を、個人〜小規模利用向けに簡易ローカル実装したもの。

## 実装ドキュメント

設計者・開発者向けの実装解説は [README_IMPLEMENTATION.md](README_IMPLEMENTATION.md) を参照。
