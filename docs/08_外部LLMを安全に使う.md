# 外部 LLM（DeepSeek 等）を安全に使う

v1.4.0 で追加。Claude / OpenAI / Anthropic 以外の **外部 LLM**（DeepSeek、Kimi、Qwen 等の中国系 / 第三者 LLM）を使うときの運用ガイドです。

> DeepSeek の課金（チャージ）のやり方や、卒業後にどの経路で DeepSeek を使うかは [20_卒業後ガイド.md](20_卒業後ガイド.md) にまとめてあります。

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

> `secret-scan` はコマンドとしてそのまま使えるように PATH に登録されていません。以下のようにスクリプトファイルを直接指定して実行してください。

**Windows（PowerShell）：**

```powershell
# 標準入力
echo "ここに本文" | powershell -File ".ai-safety\hooks\windows\secret-scan.ps1"

# ファイルを直接スキャン
powershell -File ".ai-safety\hooks\windows\secret-scan.ps1" prompt.txt

# 検出件数だけ確認（マスキングなし、検出時は終了）
echo "ここに本文" | powershell -File ".ai-safety\hooks\windows\secret-scan.ps1" --check
```

**Mac（ターミナル）：**

```bash
# 標準入力
echo "ここに本文" | bash .ai-safety/hooks/macos/secret-scan.sh

# ファイルを直接スキャン
bash .ai-safety/hooks/macos/secret-scan.sh prompt.txt

# 検出件数だけ確認（マスキングなし、検出時は exit 1）
echo "ここに本文" | bash .ai-safety/hooks/macos/secret-scan.sh --check
```

> これらのコマンドはワークスペースフォルダ（例：`Desktop\my-project`）を開いたターミナルで実行してください。

検出されるタイプ:

**ハード秘密（決まった形のトークン）**

- OpenAI API key（`sk-` / `sk-proj-`）
- Anthropic API key（`sk-ant-`）
- Google API key（`AIza...`）
- AWS access key（`AKIA...` / `ASIA...`）
- GitHub token（`ghp_` / `gho_` 等）
- Slack token（`xoxb-` 等）
- JWT（`eyJ...`）
- Private key block（`-----BEGIN PRIVATE KEY-----`）
- Generic secret（`api_key=...`, `password=...` 等の一般パターン）

**PII（半構造の個人情報）** — 検出条件と非対象を正直に明記します。

- **メール**（`xxx@yyy.zzz`）：半角記号で書かれたもののみ。**全角 `＠` や、記号の前後にスペースを挟んだもの（`x x @ y`）は検出されません。**
- **電話番号**：前後 ±20 文字に文脈語（`電話`/`TEL`/`携帯`/`連絡先`/`℡`）がある場合のみ検出。**文脈語が近くに無い裸の番号は検出されません。**
- **郵便番号**：前後 ±20 文字に文脈語（`〒`/`郵便`/`住所`）がある場合のみ検出。**文脈語が近くに無い番号は検出されません。**
- **マイナンバー**：`マイナンバー`/`個人番号`/`マイナ` が近くにある **ハイフン無し数字12桁** のみ。**ハイフン付きの書式は検出されません。**
- **クレジットカード番号**：Luhn チェックを通る 13〜19 桁のみ（文脈語ゲートは無し）。**稀に Luhn 偶然一致の数字 ID（注文番号等）を不可逆破壊し得ます。**
- **denylist 登録語**：`~/.ai-safety/denylist.txt` に1行1語で登録した語句を部分一致でマスク（大小無視）。**登録していない語は対象外です。**

**検出されないもの（重要）**

- **氏名・住所本文・社内コードネームなど自由記述の機微情報**（regex では網羅不能）
- 上記 PII の各「非対象」条件に当たるもの
- **DeepSeek からの応答（返答内容）のフィルタはありません**

> これらは `secret-scan` と送信検査 Gateway の双方に共通の検出パターンです（`scripts/common/secret-patterns.js` が実体）。**拾えないものは、送る前に自分で消す**のが大原則です。

### `safe-paste`（クリップボード経由のワンライナー）

最も簡単な使い方。プロンプトを書いてコピー → `safe-paste` → DeepSeek に貼り付け。

**Windows（PowerShell）：**

```powershell
# クリップボードをスキャン + マスキング + 書き戻し
powershell -File ".ai-safety\hooks\windows\clipboard-safe-paste.ps1"

# マスキングせず検出件数だけ確認
powershell -File ".ai-safety\hooks\windows\clipboard-safe-paste.ps1" --check
```

**Mac（ターミナル）：**

```bash
# クリップボードをスキャン + マスキング + 書き戻し
bash .ai-safety/hooks/macos/clipboard-safe-paste.sh

# マスキングせず検出件数だけ確認
bash .ai-safety/hooks/macos/clipboard-safe-paste.sh --check
```

### `deepseek-safe`（起動ゲート）

DeepSeek を使う前の念押し画面。`yes` と打つまで続行しません。

**Windows（PowerShell）：**

```powershell
powershell -File ".ai-safety\hooks\windows\launch-deepseek-safe.ps1"
```

**Mac（ターミナル）：**

```bash
bash .ai-safety/hooks/macos/launch-deepseek-safe.sh
```

起動すると赤い警告ボックスが出て、「絶対に流出しても問題ないことだけ扱いますか？」と聞かれます。`yes` で続行、それ以外で中断。続行後は推奨ワークフローと `safe-paste` の使い方が表示されます。

## 推奨ワークフロー

### Windows の場合

1. ワークスペースフォルダ（例：`Desktop\my-project`）を開いたターミナルで以下を実行 → 念押し確認に `yes`
   ```powershell
   powershell -File ".ai-safety\hooks\windows\launch-deepseek-safe.ps1"
   ```
2. **DeepSeek の Web UI（chat.deepseek.com）を別のブラウザタブで開く**
3. **プロンプトを書く** → Ctrl+C でコピー
4. ターミナルで以下を実行 → クリップボード内容がマスキングされる
   ```powershell
   powershell -File ".ai-safety\hooks\windows\clipboard-safe-paste.ps1"
   ```
5. **DeepSeek に Ctrl+V** で貼り付け
6. 応答が返ってきたら、応答の中身も**機微情報が混じっていないか目視で確認**してから使う
7. セッションが終わったら監査ログをセルフチェック:
   ```powershell
   Get-Content ".ai-safety\logs\secret-scan-events.jsonl" | Select-Object -Last 10
   ```

### Mac の場合

1. ワークスペースフォルダを開いたターミナルで以下を実行 → 念押し確認に `yes`
   ```bash
   bash .ai-safety/hooks/macos/launch-deepseek-safe.sh
   ```
2. **DeepSeek の Web UI（chat.deepseek.com）を別のブラウザタブで開く**
3. **プロンプトを書く** → ⌘C でコピー
4. ターミナルで以下を実行 → クリップボード内容がマスキングされる
   ```bash
   bash .ai-safety/hooks/macos/clipboard-safe-paste.sh
   ```
5. **DeepSeek に ⌘V** で貼り付け
6. 応答が返ってきたら、応答の中身も**機微情報が混じっていないか目視で確認**してから使う
7. セッションが終わったら監査ログをセルフチェック:
   ```bash
   tail .ai-safety/logs/secret-scan-events.jsonl
   ```

## 監査ログ

ワークスペースの `.ai-safety/logs/secret-scan-events.jsonl` に「いつ・どんな種類の機微情報を・何件マスキングしたか」が記録されます。**本物の値は記録されません**（タイプと件数のみ）。

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

## コマンドを短くしたい場合（エイリアス設定）

毎回長いパスを打つのが面倒な場合は、エイリアス（ショートカット）を設定できます。一度設定すれば、短いコマンド名で呼び出せるようになります。

### Mac（~/.zshrc に追加）

ターミナルで以下を実行してください（1 回だけでOK）：

```bash
echo 'alias secret-scan="bash ~/Documents/my-ai-workspace/.ai-safety/hooks/macos/secret-scan.sh"' >> ~/.zshrc
echo 'alias safe-paste="bash ~/Documents/my-ai-workspace/.ai-safety/hooks/macos/clipboard-safe-paste.sh"' >> ~/.zshrc
echo 'alias deepseek-safe="bash ~/Documents/my-ai-workspace/.ai-safety/hooks/macos/launch-deepseek-safe.sh"' >> ~/.zshrc
source ~/.zshrc
```

設定後は `secret-scan`、`safe-paste`、`deepseek-safe` とだけ入力すれば動きます。

> `my-ai-workspace` はインストール時に指定したワークスペースフォルダ名に読み替えてください。

### Windows（PowerShell $PROFILE に追加）

PowerShell ウィンドウで以下を実行してください（1 回だけでOK）：

```powershell
# $PROFILE ファイルがなければ作成
if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force }

# エイリアスを追加
Add-Content $PROFILE 'function secret-scan { powershell -File "$env:USERPROFILE\Desktop\my-project\.ai-safety\hooks\windows\secret-scan.ps1" @args }'
Add-Content $PROFILE 'function safe-paste { powershell -File "$env:USERPROFILE\Desktop\my-project\.ai-safety\hooks\windows\clipboard-safe-paste.ps1" @args }'
Add-Content $PROFILE 'function deepseek-safe { powershell -File "$env:USERPROFILE\Desktop\my-project\.ai-safety\hooks\windows\launch-deepseek-safe.ps1" }'

# 反映（現在のセッション）
. $PROFILE
```

設定後は `secret-scan`、`safe-paste`、`deepseek-safe` とだけ入力すれば動きます。

> `Desktop\my-project` はインストール時に指定したワークスペースフォルダのパスに読み替えてください。

## Safe Auto Mode（承認を省く自動モード）

v1.6.0 で追加。`--auto` を付けて起動すると、doctor が「金庫（OS 隔離）が効いている」と確認できたときだけ承認プロンプトを省きます。確認できない場合は理由を表示して従来の都度承認モードで起動します（フェイルクローズ）。

### 使い方

以下のコマンドに `--auto` を付けて起動します（専用ボタンはありません）。

**macOS:**

```bash
# Codex(実証ベース)
bash .ai-safety/hooks/macos/launch-codex-safe.sh <workspace> "" --auto

# agy(宣言ベース)
bash .ai-safety/hooks/macos/launch-agy-safe.sh <workspace> "" --auto
```

**Windows（PowerShell）:**

```powershell
# Codex(実証ベース)
powershell -File ".ai-safety\hooks\windows\launch-codex-safe.ps1" <workspace> "" --auto

# agy(宣言ベース)
powershell -File ".ai-safety\hooks\windows\launch-agy-safe.ps1" <workspace> "" --auto
```

### 対象エンジン別の強度

| エンジン | 隔離の強さ | 承認解放の条件 | 解放後の承認モード |
|---|---|---|---|
| **Codex** | **強・実証** | doctor が「外部送信できない / 作業フォルダ外に書けない」を実際に試して確認 | `--ask-for-approval on-failure` |
| **agy** | **弱・宣言ベース** | agy バイナリが存在するだけ（金庫を外から実証する手段がないため） | `--dangerously-skip-permissions`（`--sandbox` は維持） |
| **Claude Code** | 対象外 | 基本 DeepSeek 駆動 + 普通の Windows では金庫がないため | — |

### 重要な制限事項

- **Codex のオート解放**は「外部ネット送信遮断」と「workspace 外書き込み遮断」が実証できた場合のみです。
- **agy のオートは未実証**です。`--sandbox` フラグを信頼するもので、Codex のように独立した検証はされていません。重要な作業では手動承認の利用も検討してください。
- 解放後も `--sandbox` などの OS 隔離は常時稼働します（承認の手間だけを省きます）。
- doctor がハング・不在・例外など「判断できない」状況では必ず従来モード（都度承認）にフォールバックします。

### トラブルシューティング

「オートを有効にできません」と表示された場合は `doctor.sh`（macOS）または `doctor.ps1`（Windows）を実行して隔離ドリルの状況を確認してください。

## 関連ドキュメント

- `docs/90_守れる-守れない.md` — 4 層防御のスコープ説明
- `docs/99_known_issues.md` — 既知の問題
- `policy/safety-policy.json` — secret-scan の検出パターンソース（`secretRegex`）
