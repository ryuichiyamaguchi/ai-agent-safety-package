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
- `AGENTS.md` を明示的に読み込み、配布スキルはOpenCode互換の `.claude/skills` から利用できます。インストーラーは `.opencode/skills` にも同じスキルを準備します。
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

## プロジェクト固有のOpenCode設定について

統合ランチャーは安全設定を固定するため、プロジェクト内の `opencode.json` と外部プラグインを無効にして起動します。これはソースコード、`AGENTS.md`、Claude互換スキルの読み取りを止めるものではありません。

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
