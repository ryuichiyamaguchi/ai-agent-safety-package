# OpenCode + DeepSeek を安全に使う

統合版の標準経路は **OpenCode + DeepSeek V4 Pro** です。補助処理・サブエージェントには **DeepSeek V4 Flash** を使います。Claude Codeの操作感を使いたい場合は、同じ統合メニューから **d-claude + DeepSeek** を選べます。

## この経路で何を守るか

```text
OpenCode
  ↓ 127.0.0.1:8788（PC内だけ）
DeepSeek送信検査 Gateway
  ├─ APIキー・秘密情報を検査／マスク
  ├─ 実キーをローカルファイルから注入
  └─ 検査できない時は送信しない
  ↓
DeepSeek API
```

- OpenCodeにはDeepSeekの実キーを渡しません。
- Gatewayが起動・生存・health確認できた時だけOpenCodeを起動します。
- 読み取り・検索など日常操作は自動、ファイル変更と一般コマンドは確認制です。
- 再帰削除、管理者権限、外部フォルダ、push・publishは拒否します。
- 日本語の運用ハーネス（`AGENTS.md`）と日本語スラッシュコマンドを、統合起動専用の設定フォルダから読み込みます。配布スキルも同じ設定フォルダから読み込みます（起動のたびに workspace の `.ai-safety/dist-skills/` から配置し直します）。
- プロジェクト内の `opencode.json` と外部プラグインは統合起動時に読み込みません。保護モデルや権限をプロジェクト側から上書きされないための対策です。
- モニターには「送信検査が稼働中か」「Web検索が有効か」を表示します。

> この経路にローカルLLMは不要です。ローカルGemmaが必要なのはClaudeの「最大保護モード」だけです。

## 必要なもの

- Node.js
- OpenCode **1.14.24以上**
- DeepSeek APIキー
- このSafety Packageを導入したworkspace

OpenCodeとDeepSeekはいずれも第三者サービスです。利用規約、料金、データ取扱いは各サービスの最新情報を確認してください。

## 初回だけ：DeepSeekキーを登録

既存のDeepSeek登録ボタンを共用します。キーはPC内のユーザー専用ファイルへ保存し、リポジトリや配布ZIPには入りません。

### Mac

`スタート/（上級）1_DeepSeekキーを登録.command` を開きます。

### Windows

`スタート\（上級）1_DeepSeekキーを登録.bat` を開きます。

## 毎回の起動

いちばん簡単なのは `スタート/0_Bouncer統合版を起動` を開き、次を選ぶ方法です。

- `OpenCode + DeepSeek V4 Pro（Web検索OFF）`：通常はこちら
- `OpenCode + DeepSeek V4 Pro（Web検索を確認制でON）`：外部検索が必要な時だけ
- `d-claude + DeepSeek V4 Pro`：Claude Codeの操作感が必要な場合。送信検査とBouncer監視はON

コマンドで起動する場合：

### Mac

```bash
bash .ai-safety/hooks/macos/launch-integrated.sh "$(pwd)" opencode standard
```

Web検索を有効にする時だけ：

```bash
bash .ai-safety/hooks/macos/launch-integrated.sh "$(pwd)" opencode standard --websearch
```

### Windows

```powershell
powershell -File .ai-safety\hooks\windows\launch-integrated.ps1 -Workspace . -Agent opencode -Profile standard
```

Web検索を有効にする時だけ：

```powershell
powershell -File .ai-safety\hooks\windows\launch-integrated.ps1 -Workspace . -Agent opencode -Profile standard -WebSearch
```

## Web検索が既定でOFFの理由

検索を有効にすると、検索語が外部検索サービスへ送られます。統合版では既定で無効にし、明示的に有効化した場合も検索ごとに確認を求めます。顧客名、未公開情報、個人情報を検索語に入れないでください。

## 日本語ハーネスと日本語スラッシュコマンド

OpenCodeは素のままだと英語で答えたり、いきなり「どうしますか？」と自由記述で聞き返したりします。統合版では、受講者がそのまま使えるように日本語の運用ハーネスを最初から入れてあります。

導入(インストール)すると、次の3つが統合起動専用の設定フォルダ（`.ai-safety/opencode-runtime/xdg-config/opencode/`）に置かれます。起動のたびにパッケージ側の内容で置き直されるので、うっかり壊しても次の起動で元に戻ります。

- `AGENTS.md`: 日本語で答える、専門用語には言い換えを添える、聞き返しは選択肢で出す、承認画面が出る操作は事前に日本語で1行説明する、止められたら迂回せず代案を出す、といったふるまいの指示
- `commands/`: 下の日本語スラッシュコマンド
- `agents/`: 説明専門の「せんせい」（後述）

### スラッシュコマンドの使い方

OpenCodeの入力欄で **`/` を打つとコマンドの一覧が出ます**。矢印キーで選ぶか、名前を打ち込んでEnterで実行します。名前のうしろに続けて文章を書くと、それがそのまま渡ります。

| コマンド | 何が起きるか | 書き方の例 |
|---|---|---|
| `/そうだん` | やさしい壁打ち。はい/いいえと選択肢で少しずつ聞いて、考えを整理してくれます | `/そうだん 作りたいアプリが決まらない` |
| `/せつめい` | 直前にやったことを、専門用語なしで説明してくれます | `/せつめい` |
| `/なおして` | エラーメッセージを貼ると、意味・原因・直し方を手順で出します | `/なおして （赤い文字をそのまま貼る）` |
| `/あんぜん` | いまの設定でできること・できないことを日本語で一覧にします | `/あんぜん` |
| `/しらべて` | まず作業フォルダの中と手持ちの知識で調べ、足りなければ検索します。確かでないことは正直に分けて書きます | `/しらべて この設定ファイルは何をしている？` |

`/しらべて` は「手元 → 自分の知識 → 検索」の順で調べます。手元にある答えを外部に聞きに行かないためです。検索するときは、検索する言葉を先に見せてから実行し、出典も添えて返します。検索の道具が使えない環境では、無理に試さず「この環境では検索が使えません」と返ってきます。

### 説明だけしてほしいとき（せんせい）

「まだ触らないでほしい、まず説明して」というときのために、**何も書き換えない説明専門の担当「せんせい」**を入れてあります。ファイルの書き換え・新規作成・コマンドの実行ができない設定になっているので、壊れる心配なしに何度でも質問できます。

せんせいは、直し方まで一緒に決めたうえで、通常モードに戻ってからそのまま貼れる指示文を渡してくれます。切り替え方が分からないときは `/あんぜん` か、そのまま「せんせいに代わって」と話しかけてください。

### 外部サービスにつながる道具

コーチ用のキーが登録されている環境では、次の道具が確認付きで使えます。どれも**内容が外部へ送られます**。

| 道具 | できること | 送信先 |
|---|---|---|
| 検索 | 最新の情報を調べて、要約と出典を返す | 検索した言葉がGoogle（Gemini）へ |
| 画像の読み取り | スクリーンショットの文字やエラーを読み取る | 画像そのものがGoogle（Gemini）へ |
| 画像を作る（速い方） | 文字なしの画像を作る | 作りたい画像の説明文がPollinationsへ |
| 画像を作る（日本語文字入り） | 日本語の文字が入った画像を作る | 作りたい画像の説明文がGoogleのサービスへ |

とくに**スクリーンショットは中身がそのまま外部へ渡ります**。氏名、顧客名、メールの文面、他人の画面が写り込んでいないか、渡す前に必ず確認してください。AI側にも「渡す前に一度確認する」よう指示してありますが、最終判断は利用者の責任になります。

キーが登録されていない環境では検索と画像の読み取りは出てきません。AIは「この環境では使えません」と答えるように指示してあります。

### 聞き返しが選択肢で出る理由

自由記述で「どうしますか？」と聞かれると、多くの人はそこで手が止まります。この経路では、AIが判断に迷ったときは選択肢のついた質問画面を出すように指示してあります。分からないときは「まだ分からない」を選べば、AIが質問を作り直すか、仮置きして先へ進みます。自分の言葉で答えたいときは、自由入力の欄も同じ画面から使えます。

じっくり整理したいときは `/そうだん` を使うと、配布スキル `hearing-ladder`（やさしい階段型のヒアリング）の手順で最後まで付き合ってくれます。

## プロジェクト固有のOpenCode設定について

統合ランチャーは安全設定を固定するため、プロジェクト内の `opencode.json` と `.opencode/` フォルダ、外部プラグインを無効にして起動します。ソースコードの読み取りは、この状態でも従来どおり動きます。

配布スキルはこの状態でも使えますが、読み込み元はworkspaceの `.claude/skills` ではありません（`.opencode/` を無効にしているため、プロジェクト側のスキルフォルダは読まれません）。統合ランチャーが起動のたびにworkspaceの `.ai-safety/dist-skills/` から**統合起動専用フォルダの `skills/`** へ配置し直し、OpenCodeにはそちらを読ませます。`.claude/skills` はClaude Code / d-claude 用の置き場です。

ただし、この状態ではOpenCodeが自力でworkspace直下の `AGENTS.md` を探しに行かなくなります。統合ランチャーは、**統合起動専用フォルダの `AGENTS.md`（前の節）だけ**を読み込ませます。workspace直下の `AGENTS.md` は**意図的に読み込みません**。

workspace直下の `AGENTS.md` はCodex CLI向けに書いた指示書で、前提の違う指示がOpenCode側に混ざるのを避けるためです。この経路で日本語のふるまいを決めているのは統合起動専用フォルダの1本だけ、と考えてください。受講者がworkspace直下の `AGENTS.md` を書き換えても、OpenCode統合版のふるまいは変わりません。

モデルや権限を変更したい場合は、プロジェクトごとの設定で上書きせず、このパッケージの `scripts/common/opencode-config.js` を管理者が検証・更新してから再配布してください。

## 診断

まず通常の診断を実行します。

### Mac

```bash
bash .ai-safety/hooks/macos/doctor.sh "$(pwd)"
AI_SAFE_DRY_RUN=1 bash .ai-safety/hooks/macos/opencode/launch-opencode-deepseek.sh "$(pwd)"
```

### Windows

```powershell
powershell -File .ai-safety\hooks\windows\doctor.ps1 -Workspace .
$env:AI_SAFE_DRY_RUN='1'
powershell -File .ai-safety\hooks\windows\opencode\launch-opencode-deepseek.ps1 -Workspace .
Remove-Item Env:\AI_SAFE_DRY_RUN
```

dry-runにはキー本文を表示しません。

## キー削除・利用終了

### Mac

`スタート/（上級）9_DeepSeekキーを削除.command` を開きます。

### Windows

`スタート\（上級）9_DeepSeekキーを削除.bat` を開きます。

その後、DeepSeek管理画面でも使わないキーを失効させてください。OpenCode自体をアンインストールしても、Safety Packageのworkspace、監査ログ、DeepSeek側のキーは自動削除されません。

## d-claudeを統合版から起動する

`スタート/0_Bouncer統合版を起動` の `d-claude + DeepSeek V4 Pro` を選びます。統合版は次をまとめて起動します。

- DeepSeekへの送信同意確認
- 送信前の秘密情報検査・マスキングGateway
- Claude Codeの安全フック
- `AI_SAFE_AGENT=d-claude` として識別されるBouncerモニター
- グレー操作をDeepSeek自身ではなく独立したGeminiで確認する二鍵判定

Macで直接起動する場合:

```bash
bash .ai-safety/hooks/macos/launch-integrated.sh "$(pwd)" d-claude standard
```

Windowsで直接起動する場合:

```powershell
powershell -File .ai-safety\hooks\windows\launch-integrated.ps1 -Workspace . -Agent d-claude -Profile standard
```

DeepSeek APIキーが未登録の場合は、先に `スタート/（上級）1_DeepSeekキーを登録` を実行します。新規利用の標準は引き続きOpenCode経路ですが、d-claudeも統合版の正式な監視対象です。

## 限界

- 正規表現で判別できない氏名、住所本文、社内コード名などは自動検出できません。
- マスキング済みでも、外部サービスへ送ってよい情報かは利用者の判断が必要です。
- OpenCodeの `--auto` は確認要求を自動許可するため、統合ランチャーでは使いません。
- 本パッケージを経由せず素の `opencode` を起動すると、この送信検査と強制権限設定は効きません。
