# DeepSeek で Claude Code を使う（Mac・ガード付き）

このフォルダの3つの `.command` は、**本パッケージの保護フック（ガード）が効いたまま**、
バックエンドだけ DeepSeek に向けた Claude Code を起動するためのものです。
Windows 版（`scripts/windows/deepseek/`）の Mac 対等版です。

> 前提：先に `install-one-click.command` で安全パッケージをインストールしておくこと。
> 起動 `.command` は workspace（`~/Documents/my-ai-workspace`）の
> `launch-claude-safe.sh` を呼び出します。workspace が無いと起動できません。

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
| `登録-初回だけ.command` | 初回に1回だけ | DeepSeek の API キーを `~/.deepseek-claude/auth`（権限 600）に保存（起動ファイルに平文で書かない） |
| `起動-Claude-DeepSeek.command` | 毎日 | ① DeepSeek 同意ゲート → ② 送信検査 Gateway を起動（health 確認）→ ③ Gateway 経由で launch-claude-safe.sh を起動 |
| `キー削除.command` | 授業後 | `~/.deepseek-claude/auth` を削除 |

> Mac には Windows の `setx`（永続環境変数）が無いため、キーは権限 600 のファイルに
> 分離して保存し、起動 `.command` がそこから読み込みます。考え方は Windows 版と同じ
> （毎日使う起動ファイルに平文を残さない）です。

---

## 使い方

1. **DeepSeek の API キーを取る**：https://platform.deepseek.com/ でサインアップ →
   少額だけ Top up → API keys → Create new API key → すぐコピー。
2. **`登録-初回だけ.command` をダブルクリック** → キーを貼り付けて Enter（入力は非表示）。
3. **`起動-Claude-DeepSeek.command` をダブルクリック** → 赤枠の同意ゲートで `yes` →
   Claude Code が起動。画面のモデル表示が **`deepseek-v4-pro`** ならOK。
4. **授業後：** `キー削除.command` をダブルクリック ＋ DeepSeek 管理画面でもキーを Delete。

> 初回ダブルクリック時に Gatekeeper が「開発元を確認できません」と出たら、
> Finder で右クリック →「開く」、または `chmod +x *.command` 済みであることを確認。

---

## 「本当に DeepSeek が動いている」確認

- 画面のモデル名が `deepseek-v4-pro`。
- 数回質問後、https://platform.deepseek.com/ の Usage / Billing で**残高が減っていれば確実**。

---

## つまずき対処

### ① モデル名で「無効」エラー（GitHub Issue #56990）
`起動-Claude-DeepSeek.command` の `ANTHROPIC_MODEL` を差し替え：
- **A案**：`export ANTHROPIC_CUSTOM_MODEL_OPTION="deepseek-v4-pro"`（検証スキップ）
- **B案**：`ANTHROPIC_MODEL` 行を消し、起動後 `/model` で opus を選ぶ。

### ②「あなたは誰？」で「私は Claude」と答える
故障でも詐称でもありません。Claude Code のシステムプロンプトに「あなたは Claude です」と
書いてあり DeepSeek がそう名乗るだけ。確認は自己紹介ではなく**モデル名表示と請求**で。

### ③ 漏えい対策の運用
各自でキー作成 / 少額チャージ / 授業後に削除（`キー削除.command` ＋ 管理画面 Delete）。

---

## 出典（一次情報）
- DeepSeek 公式 Claude Code 連携: https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code
- DeepSeek 公式 Anthropic API: https://api-docs.deepseek.com/guides/anthropic_api
- 非 Anthropic モデル名の検証問題: https://github.com/anthropics/claude-code/issues/56990
