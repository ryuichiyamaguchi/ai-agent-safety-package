# 環境変数と API キーって何（v1.14.16）

このドキュメントは、他の docs に頻出する「環境変数」「API キー」「.env ファイル」の意味がわからない方向けです。

聞いたことのない言葉かもしれませんが、5 分で理解できる内容です。

---

## 1. 環境変数って何？

### 家のたとえ

家の中に「共有の伝言板」があると想像してください。

リビングに「今日の天気：曇り」、玄関に「Wi-Fi パスワード：ABC123」、台所に「お母さんの電話番号：090-xxxx-xxxx」と書いてあります。

家族（家の中で動くアプリやプログラム）は、必要な情報が欲しいときに「この伝言板を見に行く」んです。

### コンピュータでの話

Windows や Mac の中には、OS が管理する「伝言板」があります。これが**環境変数**です。

例えば：

```
PATH = C:\Windows\System32;C:\Program Files\...
HOME = /Users/yourname
TEMP = C:\Users\yourname\AppData\Local\Temp
```

こういった情報が並んでいます。AI ツール（Codex、Claude Code、Gemini）がコマンドを実行する時に「環境変数を読んでくる」のは、この伝言板を見に行く動きです。

### 普通の人は気にしなくていい

環境変数は OS が勝手に管理しているので、日常的には意識する必要はありません。

ただし、AI に「API キーを使ったコードを書いて」と頼むと、AI は「その環境変数、この PC に存在するはずだ」と思い込んで読もうとします。そこが注意ポイントです。

---

## 2. API キーって何？

### 家のたとえ

API キーは「合鍵」です。

OpenAI（ChatGPT の会社）や Anthropic（Claude の会社）、Google（Gemini の会社）のビルがあると想像してください。

普通の来客は「受付を通して」来ますが、合鍵を持っている人は「バックドアから直接入れて、自分好みに AI を使える」という感じです。

### コンピュータでの話

API キーは、OpenAI・Anthropic・Google から個人に発行される**長い文字列**です。

例（以下は本物ではなく、説明用のデモ文字列です。実物はもっと長いランダムな英数字です）：
```
sk-proj-EXAMPLE-NOT-REAL
```

このキーを持っていると、その AI 会社のサービスを「あなたとして」呼び出せます。

- 余った API キーを他人に渡すと、その人があなた名義で AI を使い始める
- あなたの AWS アカウントから課金される（月数万円〜数十万円の被害例あり）

だからこのキーは絶対に漏らしてはいけません。

---

## 3. .env ファイルって何？

### 家のたとえ

.env ファイルは「合鍵を書いた紙」です。

大切な合鍵を部屋のどこかに置きすぎるのは危ないので「この引き出しに書いた紙で管理しよう」という工夫です。

ただし、この紙を他人が見つけたら意味がないので「金庫の中に」「家の人にだけ教える」というルールになっています。

### コンピュータでの話

プロジェクトフォルダの中に `.env` という**隠しファイル**を置く習慣があります。

```
.env ファイルの中身
---
OPENAI_API_KEY=sk-proj-EXAMPLE-NOT-REAL
ANTHROPIC_API_KEY=sk-ant-EXAMPLE-NOT-REAL
GEMINI_API_KEY=EXAMPLE-NOT-REAL
DATABASE_URL=postgresql://user:pass@localhost
```

開発者が「API キーをコード（`.py` や `.js` ファイル）に直接書かない」ために使われます。

理由は簡単：コードを GitHub にアップロードしてしまったら、GitHub にコードの中身（API キーまるごと）が保存されて、世界中に見られます。

でも .env ファイルなら、`.gitignore` というファイルに「.env は Git に追加しない」と書いておけば、GitHub にはアップロードされません。

---

## 4. このパッケージが守る仕組み

### 環境変数フィルタ

パッケージの設定 `shell_environment_policy.exclude` に以下が書いてあります。

```
OPENAI_API_KEY
ANTHROPIC_API_KEY
GEMINI_API_KEY
AWS_ACCESS_KEY_ID
GITHUB_TOKEN
...
```

これらの環境変数は、AI に読ませない設定です。

AI から見ると「そんな環境変数は最初から無い」という状態になります。つまり AI が「OPENAI_API_KEY を読みたい」と動いても、フィルタが間に入って「そんなものは無い」と返す。これで漏洩を防ぎます。

### .env ファイルの承認ダイアログ

もし AI が `.env` ファイルを直接読もうとしたら、あなたの画面に**ダイアログが出ます**。

```
【確認】
AI が .env ファイルを読もうとしています。
許可しますか？

[許可]  [許可しない]
```

ここで「許可しない」を押せば、AI は `.env` を読めません。

---

## 5. 受講者が守るべき 3 つのこと

### 1. API キーをチャット欄に貼らない

```
× 悪い例
ChatGPT のチャットに「このコード直してください」と言いながら、
チャット欄に sk-proj-EXAMPLE-NOT-REAL... をコピペする
```

Codex / Claude / ChatGPT の入力欄に直接 API キーを貼ると、その瞬間にこれらのサービスのサーバーに送信されます。

AI プロバイダ側に「API キーが見える」状態になるので、**絶対にしないでください**。

このパッケージのフィルタも、ここまでは防げません。**利用者の習慣**が一番大事です。

### 2. .env ファイルを読むときはダイアログをよく読む

AI が `.env` を読もうとしたら、承認ダイアログが出ます。

- 「許可」を押したら、AI が `.env` を読める
- 「許可しない」を押したら、AI は読めない

一瞬で判断しないで、「今、何を読もうとしているのか」確認してから選んでください。

### 3. GitHub に push する前に .env が含まれていないか確認

コマンドラインで以下を実行：

```bash
git status
```

出力を見て、`.env` が出てきたら**一旦止めます**。

```
M  example.py
?  .env          ← これが出ていたらダメ
```

このファイルを削除してから push してください。

> ⚠️ 本パッケージの `policy/safety-policy.json` は `git push` を **deny** します。受講者は **launcher を抜けた素のターミナル**（Cursor の別ターミナルや、macOS の Terminal.app / Windows の PowerShell 直接起動など、`launch-codex-safe` / `launch-claude-safe` を経由しないセッション）で push してください。launcher 内（AI エージェントのセッション内）で `git push` を実行しようとすると hook 層で block されます。これは「AI 自身がうっかり / 悪意あるプロンプトに従って push してしまう」事故を防ぐためで、人間が自分の判断で push する経路は別に確保されています。

---

## 6. もし API キーが漏れてしまったら

もし「誰かに見られてしまった」「チャット欄に貼ってしまった」と気付いたら：

### すぐやること

1. OpenAI / Anthropic / Google の管理画面にログイン
2. API キー一覧から「漏れたキーを revoke（無効化）」
3. 新しいキーを発行
4. `.env` ファイルに新しいキーを書き換え

### 被害を最小化するために

- 「昨日漏れたかも」と思っても、即座に revoke してください
- 1 時間放置で数万円課金された事例があります
- 会社の重要なキーなら、上司に報告して対応してもらってください

---

## 7. よくある質問

### Q. 環境変数って自分で作ったり編集したりするんですか？

A. 職業訓練校の環境では、ほぼやりません。OS が作った環境変数を「AI が読む」という流れがメインです。

もし「環境変数を設定してください」と誰かに言われたら、それは上級者の作業です。迷わず講師に聞いてください。

### Q. API キーを忘れてしまったら？

A. 新しいキーを発行するだけです。古いキーは revoke して無効化します。大丈夫。

### Q. .env ファイルはどこに置くんですか？

A. プロジェクトフォルダの直下（ルート）に置きます。

```
my-project/
  .env           ← ここ
  .env.example   （テンプレート、コードと一緒に管理）
  code/
  data/
```

### ❌ レベル 0：絶対 NG — コードに直接書く

```python
client = OpenAI(api_key="sk-proj-EXAMPLE-NOT-REAL")  # ← 絶対NG
```

GitHub に push した瞬間に世界中に公開されます。 bot が秒単位でスキャンしているので、数分で誰かに使われ始めます（過去に何度も事故が起きています）。

### ⚠️ レベル 1：基本 — `.env` ファイル + 環境変数（ローカル開発のデファクト）

```python
import os
from openai import OpenAI

client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])  # 環境変数から読む
```

- `OPENAI_API_KEY` は `.env` ファイルに書く
- `.env` を `.gitignore` で GitHub から除外する
- アプリ起動時に `.env` の中身が環境変数に展開され、`os.environ` から読み取る

ローカル開発でよく使われる方法ですが、**`.env` ファイルは PC 内に平文で保存される**ため、完璧ではありません。 PC が盗まれたり、別のソフトウェアに読まれたりするリスクは残ります。

### ✅ レベル 2：より安全 — OS の暗号化保管庫（キーチェーン）

OS にはユーザーごとに暗号化された保管庫が標準で備わっています。 そこにキーを置き、コードからは `keyring` ライブラリ経由で取り出します。

- **macOS**: キーチェーン（Keychain）
- **Windows**: 資格情報マネージャー（Credential Manager）
- **Linux**: Secret Service（GNOME Keyring / KWallet など）

```python
import keyring
from openai import OpenAI

api_key = keyring.get_password("openai", "default")  # OSの暗号化保管庫から取り出す
client = OpenAI(api_key=api_key)
```

キーチェーンに保存されたキーは、OS がログインユーザーごとに暗号化して保管します。 `.env` ファイルが平文で残るリスクを避けられます。 個人の本番運用ならこれが最低ライン。

### 🏢 レベル 3：本番運用 — クラウドのシークレット管理サービス

チーム開発や本番サーバーでは、**AWS Secrets Manager** / **HashiCorp Vault** / **GCP Secret Manager** / **Azure Key Vault** のようなクラウドサービスからランタイムで取得します。 IAM ロール（権限制御）と組み合わせて、「このサーバーだけがこのキーを読める」状態にします。 今日は概念だけ知っておけば十分。

### Q. 戦略講座（Strategy Kit）で GAS のスクリプトプロパティに Gemini API キーを入れたけど、あれは大丈夫だったの？

A. 大丈夫です。 **GAS のスクリプトプロパティ（Script Properties）はレベル 2 相当**、つまり「プラットフォームの暗号化保管庫」に該当します。

```javascript
// GAS では、コードに API キーを直接書かない
const apiKey = PropertiesService.getScriptProperties().getProperty('GEMINI_API_KEY');
// ↑ Google 管理下の暗号化保管領域から取り出している
```

ポイント:

- **コード（`.gs` ファイル）にはキーが書かれていない**ので、コードを共有・コピーされても漏れません
- スクリプトプロパティは Google アカウントの認証配下にあり、暗号化されて保管されます
- アクセス権はそのスクリプトの編集者（あなたが許可した人）に限定されます

| 方式 | 保管場所 | 暗号化 | 該当レベル |
|---|---|---|---|
| GAS スクリプトプロパティ | Google のクラウド | ◎（Google管理） | レベル 2 相当 |
| OS のキーチェーン | 自分の PC（暗号化保管庫） | ◎（OS管理） | レベル 2 |
| `.env` ファイル | 自分の PC（平文） | ✗ | レベル 1 |
| コードに直接 | コードファイル内 | ✗ | レベル 0（NG） |

つまり Strategy Kit でやったことは、**「Google というクラウドのキーチェーンを使った」と読み替えればOK**です。

---

**このパッケージが守ってくれるのは、上のどのレベルであっても、AI エージェント（Codex / Gemini / Claude Code）が悪意のあるプロンプトを受け取って、勝手に `.env` やキーチェーンを読んで外部に送信する事故**です。 あなた自身は、最低でもレベル 1（`.env`）、本格運用ならレベル 2（キーチェーン）を使ってください。

---

## まとめ

| 用語 | たとえ | 役割 |
|---|---|---|
| 環境変数 | 家の伝言板 | アプリが共通設定を読む場所 |
| API キー | 合鍵 | AI サービスを「あなた」として使う許可証 |
| .env ファイル | 合鍵を書いた紙 | API キーをコードと分離して管理 |

このパッケージは：

- API キーが AI に見えないようにフィルタを入れる
- .env を読もうとしたらダイアログで確認する
- コマンド実行の危ない動きを止める

ですが、**最後の砦は「受講者が API キーをチャットに貼らない」という習慣**です。

docs/90 と docs/92 で「守れること・守れないこと」「隔離の仕組み」をさらに詳しく説明していますので、興味があれば読んでください。

---

## workspace を Git に上げるときの注意

launcher（`launch-codex-safe.*` / `launch-claude-safe.*`）は、AI 認証情報を workspace 内に持ち込みます:

- `.codex/auth.json` — Codex の OpenAI auth トークン
- `.claude/` — Claude の設定
- `.gemini/` — Gemini の認証情報

**workspace をそのまま `git init` して `git add .` すると、これらが Git 履歴に混入します**。バックアップサービス（iCloud Drive / OneDrive / Google Drive / Dropbox）でも同様にクラウド側に上がります。

### 対策

workspace 直下に必ず以下を配置してください:

```bash
# workspace-template/.gitignore.template を workspace/.gitignore にコピー
cp workspace-template/.gitignore.template /path/to/workspace/.gitignore

# AI に読ませない除外設定（Gemini / Codex 共通）
cp workspace-template/aiexclude.template /path/to/workspace/.aiexclude
```

`.gitignore` と `.aiexclude` の両方に **`.codex/` `.claude/` `.gemini/` `.ai-safety/logs/`** が含まれていることを確認してから `git init` / `git add` してください。

> Windows の `launch-codex-safe.ps1` は v1.0.10 以降、`auth.json` を workspace 内に物理コピーせず、`~/.codex/auth.json` への **SymbolicLink**（生成できない環境では ACL ロックダウン + Hidden 属性付きフォールバックコピー）として配置します。よって `.gitignore` を外して `git add -f .codex` してもリンク本体だけが上がり、トークン実体は `~/.codex/auth.json` に留まります（ただし `git` の挙動はバージョン依存なので、運用上は `.gitignore` での除外を必ず維持してください）。

すでに add してしまった場合の対処:

```bash
git rm -r --cached .codex .claude .gemini .ai-safety/logs
git commit -m "remove leaked AI credentials"
# 既に push 済みなら auth.json を必ずローテーション
```
