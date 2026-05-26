# 外部 LLM（DeepSeek 等）を安全に使う

v1.4.0 で追加。Claude / OpenAI / Anthropic 以外の **外部 LLM**（DeepSeek、Kimi、Qwen 等の中国系 / 第三者 LLM）を使うときの運用ガイドです。

## なぜ別ドキュメントが必要なのか

本パッケージの 4 層防御は「AI ツールが**ローカル PC で何をするか**」を縛るのが目的です。一方、外部 LLM を使うときに新しく出てくる問題は「あなたが書いたプロンプトの**中身がどこに送られるか**」という別軸の話で、4 層防御の対象外です。

### 家のたとえ

| | 4 層防御 | 外部 LLM 問題 |
|---|---|---|
| 守る対象 | 家の中（PC のファイル・コマンド） | 家から出ていく荷物（プロンプトの中身） |
| 担当者 | OS サンドボックス + hook + permissions.deny | あなた自身 + secret-scan（マスキング層） |

外部 LLM では、荷物（プロンプト）が中国管轄のサーバーに行く前に**自分で中身を確認する**仕組みが必要です。

## 守るべきこと（あなたの責任ライン）

外部 LLM を使う前に、**毎回**以下を確認してください:

1. **絶対に流出しても問題ない情報だけ**扱う
2. **本物の API キー・パスワード**を書かない
3. **顧客名・社外秘・個人情報**を書かない
4. 機微情報が混じる可能性のある長文は、**secret-scan でマスキング**してから貼り付ける
5. **企業案件・本物のクライアント業務**には使わない（マーケ講座の演習や個人学習用に限定）

## 提供されるツール

### `secret-scan`（機微情報スキャナ）

プロンプト本文を入力すると、API キー・パスワード・JWT・秘密鍵などを `[MASKED:type]` に置換します。

```bash
# 標準入力
echo "ここに本文" | secret-scan

# ファイル
secret-scan prompt.txt

# 検出件数だけ確認（マスキングなし、検出時は exit 1）
echo "ここに本文" | secret-scan --check

# 警告を抑制（監査ログには記録）
echo "ここに本文" | secret-scan --quiet
```

検出されるタイプ:

- OpenAI API key（`sk-` / `sk-proj-`）
- Anthropic API key（`sk-ant-`）
- Google API key（`AIza...`）
- AWS access key（`AKIA...` / `ASIA...`）
- GitHub token（`ghp_` / `gho_` 等）
- Slack token（`xoxb-` 等）
- JWT（`eyJ...`）
- Private key block（`-----BEGIN PRIVATE KEY-----`）
- Generic secret（`api_key=...`, `password=...` 等の一般パターン）

### `safe-paste`（クリップボード経由のワンライナー）

最も簡単な使い方。プロンプトを書いて ⌘C → `safe-paste` → DeepSeek に ⌘V。

```bash
# クリップボードをスキャン + マスキング + 書き戻し
safe-paste

# マスキングせず検出件数だけ確認
safe-paste --check
```

### `deepseek-safe`（起動ゲート）

DeepSeek を使う前の念押し画面。`yes` と打つまで続行しません。

```bash
deepseek-safe
```

起動すると赤い警告ボックスが出て、「絶対に流出しても問題ないことだけ扱いますか？」と聞かれます。`yes` で続行、それ以外で中断。続行後は推奨ワークフローと `safe-paste` の使い方が表示されます。

## 推奨ワークフロー

1. **`deepseek-safe`** を実行 → 念押し確認に `yes`
2. **DeepSeek の Web UI（chat.deepseek.com）または公式 CLI を別画面で開く**
3. **プロンプトを書く** → ⌘C でコピー
4. **ターミナルで `safe-paste`** → クリップボード内容がマスキングされる
5. **DeepSeek に ⌘V** で貼り付け
6. 応答が返ってきたら、応答の中身も**機微情報が混じっていないか目視で確認**してから使う
7. セッションが終わったら **監査ログをセルフチェック**: `cat ~/.ai-safety/logs/secret-scan-events.jsonl | tail`

## 監査ログ

`~/.ai-safety/logs/secret-scan-events.jsonl` に「いつ・どんな種類の機微情報を・何件マスキングしたか」が記録されます。**本物の値は記録されません**（タイプと件数のみ）。

```json
{"ts":"2026-05-27T03:31:22Z","user":"ryuichi","mode":"mask","cwd":"/Users/ryuichi/...","total":3,"counts":{"openai":1,"anthropic":0,"google":1,"aws":1,"github":0,"slack":0,"jwt":0,"private_key":0,"generic":0}}
```

## できないこと（限界）

- **応答内容のフィルタ**は実装していません。外部 LLM が機微情報を含む応答を返してきても本パッケージは関知しません
- **API 経由・SDK 経由で外部 LLM を直接呼ぶ**コードを書く場合、`secret-scan` はリクエスト前に挟まないと意味がありません
- **マスキング前提で生の API キーを書く習慣**がついてしまうと逆効果です。**そもそも書かない**のが第一の鉄則
- **DeepSeek 以外**（Kimi、Qwen、Mistral、Cohere 等）でも同じ運用が使えますが、それぞれのプライバシーポリシーは個別に確認してください

## FAQ

### Q: 講座の受講者全員に DeepSeek を勧めるべき？

A: **勧めません**。「選べることは伝える、勧めない」が無難です。受講者の自己責任で使う場合は、本ドキュメントの運用を必ず守らせてください。

### Q: マスキングされたプロンプトでも DeepSeek は意図を理解してくれる？

A: 多くの場合は理解できます（`[MASKED:openai]` は「ここに OpenAI API キーがある」というヒントとして機能する）。ただし、**マスキング前提で書く設計**になってしまうと「マスキングされるから書いていい」と勘違いするリスクがあるので、**そもそも書かない**ことが大事です。

### Q: secret-scan の検出パターンに引っかからない秘密情報は？

A: あります。たとえば「顧客の名前」「社内コードネーム」「特定の URL パターン」などは regex で網羅できません。**最終確認は目視**で行ってください。secret-scan は「うっかり貼り付けた API キーをブロックする最後の砦」であって、「すべての機微情報を完璧に検出するツール」ではありません。

## 関連ドキュメント

- `docs/90_守れる-守れない.md` — 4 層防御のスコープ説明
- `docs/99_known_issues.md` — 既知の問題
- `policy/safety-policy.json` — secret-scan の検出パターンソース（`secretRegex`）
