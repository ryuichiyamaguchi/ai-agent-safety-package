# DeepSeek で Claude Code を使う（Windows・ガード付き）

このフォルダの3つの `.bat` は、**本パッケージの保護フック（ガード）が効いたまま**、
バックエンドだけ DeepSeek に向けた Claude Code を起動するためのものです。

> 前提：先に `install-one-click.bat` で安全パッケージをインストールしておくこと。
> 起動 `.bat` は workspace（`%USERPROFILE%\Documents\my-ai-workspace`）の
> `launch-claude-safe.ps1` を呼び出します。workspace が無いと起動できません。

---

## ⚠ 最初に正しく理解すること（overclaim 防止）

- **会話内容は DeepSeek（中国管轄のサーバー）に送信されます。**
- 本パッケージのガードは、AI の**ツール操作の暴走**（ファイル削除・危険なコマンド実行・機微ファイルの読み書き等）を止めます。
- **さらに、送信検査 Gateway（ローカルプロキシ）が、DeepSeek へ送る前に既知パターンの機微情報を自動で `[MASKED]` 等に置換します。** 対象は **API キー・トークン・パスワード・秘密鍵ブロック等のハード秘密**と、**一部の PII（メール / 文脈語が近くにある電話・郵便番号 / マイナンバー（数字12桁）/ クレジットカード番号 / denylist に登録した語）** です。検査範囲はリクエスト body 全体・URL クエリ・カスタムヘッダーに及びます。
- **ただしこの自動マスキングは「検出できる決まった形のパターン」に限られます。** 検出できないものの例：**氏名・住所本文・社内コードネームなど自由記述の機微情報、文脈語の無い裸の電話/郵便番号、全角記号で書いたメール**。また**応答（DeepSeek の返答）のフィルタはありません**。「Gateway があるから DeepSeek でも完全に安全」というのは**誤り**です。**拾えないものは、送る前に自分で消してください。**
- したがって：**本当に流出して困る情報は入力しない**運用を引き続き守ってください。Gateway は**最後の安全網であって、完全な保証ではありません。**

---

## 3つのファイルの役割

| ファイル | いつ使う | 何をする |
|---|---|---|
| `登録-初回だけ.bat` | 初回に1回だけ | DeepSeek の API キーを Windows ユーザー領域に `setx` で保存（起動 .bat に平文で書かない） |
| `起動-Claude-DeepSeek.bat` | 毎日 | ① DeepSeek 同意ゲート → ② 送信検査 Gateway を起動（health 確認）→ ③ Gateway 経由で launch-claude-safe.ps1 を起動 |
| `キー削除.bat` | 授業後 | PC 側の `ANTHROPIC_AUTH_TOKEN` を削除 |

---

## 使い方（受講者向け）

1. **DeepSeek の API キーを取る**：https://platform.deepseek.com/ でサインアップ →
   少額だけ Top up（チャージしないとキーが動きません）→ API keys → Create new API key →
   **一度しか表示されないのですぐコピー**。
2. **`登録-初回だけ.bat` をダブルクリック** → キーを貼り付けて Enter（初回だけ）。
3. **いったんウィンドウを閉じる**（環境変数は新しいウィンドウから反映されるため）。
4. **`起動-Claude-DeepSeek.bat` をダブルクリック** → 赤枠の同意ゲートで `yes` →
   Claude Code が起動。画面のモデル表示が **`deepseek-v4-pro[1m]`** になっていればOK。
5. **授業後：** `キー削除.bat` をダブルクリック ＋ DeepSeek 管理画面でもキーを Delete。

> SmartScreen が警告を出したら「詳細情報」→「実行」。3つを1つの ZIP にまとめると警告が減ることがあります。

---

## 「本当に DeepSeek が動いている」確認

- 画面のモデル名が `deepseek-v4-pro[1m]`（Opus / Sonnet ではない）。
- 数回質問後、https://platform.deepseek.com/ の Usage / Billing で**残高が減っていれば確実**。

---

## つまずき対処（講師向けメモ）

### ① モデル名で「無効」エラーが出る環境がある
一部の Claude Code バージョンは非 Anthropic のモデル名（`deepseek-v4-pro[1m]`）を弾く検証を
入れています（GitHub Issue #56990）。`起動-Claude-DeepSeek.bat` の `ANTHROPIC_MODEL` 行を差し替え：
- **A案（表示も deepseek にしたい・検証スキップ）**：`set "ANTHROPIC_CUSTOM_MODEL_OPTION=deepseek-v4-pro[1m]"`
- **B案（動けばよい・表示は Opus）**：`ANTHROPIC_MODEL` 行を消し、起動後 `/model` で opus を選ぶ（サーバ側で v4 に振り分け）

全員の表示を揃えたいなら Claude Code のバージョンを固定し、1台で事前確認を。

### ②「あなたは誰？」で「私は Claude」と答える
故障でも詐称でもありません。Claude Code が毎回送る**システムプロンプト**に「あなたは
Anthropic の Claude です」と書いてあり、それを読んだ DeepSeek がそう名乗るだけです。
`ANTHROPIC_BASE_URL` は送信先を変えるだけで、この指示書は変えません。
**確認は「自己紹介」ではなく「画面のモデル名」と「DeepSeek の請求」で**行ってください。
（自己紹介まで変えるにはプロキシで指示書の書き換えが必要で、低スペック・大人数の教室には不向き。本パッケージでは採用しません。）

### ③ 漏えい対策の運用（技術より効く）
1. キーは受講者ごとに各自で作る（共用しない）
2. DeepSeek には少額だけチャージ（残高 = 使われる上限）
3. 授業後にキーを削除（`キー削除.bat` ＋ 管理画面で Delete）

---

## 出典（一次情報）
- DeepSeek 公式 Claude Code 連携: https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code
- DeepSeek 公式 Anthropic API: https://api-docs.deepseek.com/guides/anthropic_api
- DeepSeek 料金: https://api-docs.deepseek.com/quick_start/pricing
- 非 Anthropic モデル名の検証問題: https://github.com/anthropics/claude-code/issues/56990
