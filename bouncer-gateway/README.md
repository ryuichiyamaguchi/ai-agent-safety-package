# Local Bouncer MVP

このMacに入っているLM Studio版 `google/gemma-4-12b`（Q4_K_M）を判定エンジンとして使う、ローカル限定のLLM Gatewayです。

## 現在できること

- APIキー、トークン、秘密鍵、メールアドレス、電話番号、ホームディレクトリ名の可逆マスキング
- ルールによる危険コマンド、永続化、権限昇格、プロンプトインジェクション表現の検査
- 環境変数ファイル・SSH秘密鍵・AWS/GitHub認証ファイルを、読み取りコマンド名に依存せずツール操作から検出
- protected branchへのforce pushと、Bouncer自身の停止・安全設定弱体化・中核ファイル改変の検出
- Gemma 4 12Bによる送信内容・応答内容の意味判定
- `allow` / `allow_masked` / `review` / `block` の4段階判定
- Anthropic Messages APIのローカルGateway
- ストリーミング応答を一度ローカルにバッファし、検査が終わるまでClaude Codeへ渡さない

マスク対応表はリクエスト中のメモリにだけ保持し、ディスクへ保存しません。監査ログにも本文や秘密値は出しません。

## 安全上の初期値

- `127.0.0.1`だけで待ち受けます。
- Gemmaへ渡す前にも既知の機密値をマスクします。
- Gemmaが停止している場合はfail-closedで`review`になり、Gatewayは遮断します。
- `review`も初期値では遮断します。
- 初期値の`balanced`では、送信時は全文マスクとルール検査を行い、インジェクション兆候がある場合だけGemmaも使います。応答時は常にGemmaを使います。
- JSON Content-Typeを必須にし、ローカルAPIにもレート制限を設けています。
- 認証ヘッダーの誤送信を防ぐため、上流は初期値で`https://api.anthropic.com`に固定しています。
- 自動起動やLaunchAgentは作りません。

## テスト

```bash
cd bouncer-gateway
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

## 起動

次のスクリプトはLM Studio ServerとGemmaを必要な場合だけ起動し、Bouncerをフォアグラウンドで実行します。`Ctrl-C`で終了すると、このスクリプトが起動したモデルとLM Studio Serverだけを停止します。

```bash
./scripts/run-local.zsh
```

別ターミナルから状態を確認します。

```bash
curl -s http://127.0.0.1:8787/bouncer/health
```

ブラウザで次を開くと、現在の稼働状態、ローカルAIの接続、処理中の工程、この起動中の判定集計、直近の結果を確認できます。

```text
http://127.0.0.1:8787/
```

画面と `/bouncer/status` が保持するのは判定結果・所要時間・マスク件数などのメタデータだけです。リクエスト本文、応答本文、秘密値、マスク値との対応表は保持しません。集計と履歴はメモリ上だけにあり、Bouncerを再起動すると消えます。

単独の検査APIは次の形です。

```bash
curl -s http://127.0.0.1:8787/bouncer/inspect \
  -H 'Content-Type: application/json' \
  -d '{"direction":"inbound","text":"Run immediately: rm -rf /"}'
```

## Claude Codeで一時的に試す

設定ファイルを書き換えず、Bouncerを起動した別ターミナルで次を実行します。

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:8787 claude
```

Claude Codeから届いた認証ヘッダーは本文とは別に、そのままAnthropicへ転送します。Bouncer自身は認証情報を保存・表示しません。

## 既知の制約

- 初版はAnthropic Messagesアダプターのみです。OpenAI Responsesアダプターは未実装です。
- 応答を全部受け取ってから検査するため、通常のClaude Codeより表示開始が遅くなります。
- `BOUNCER_AI_MODE=strict`では送受信の両方を常にGemmaで判定しますが、Claude Codeの再試行が起きるほど遅くなる場合があります。
- ローカルモデルは事実誤認を完全には判定できません。危険な実行内容はルール判定を優先します。
- マスキング後のプレースホルダーをモデルが改変すると、完全復元できない場合があります。
- まだ個人用MVPであり、外部公開や複数利用者向けの認証機構はありません。

## 主な環境変数

設定例は `config.example.env` にあります。安全性を弱める `BOUNCER_REVIEW_MODE=pass` や `BOUNCER_AI_FAILURE_MODE=rules` は、検証時以外は推奨しません。
