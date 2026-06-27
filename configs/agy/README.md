# configs/agy/ — Antigravity CLI 用 安全設定

v1.3.0 で新規追加。Gemini CLI から後継の Antigravity CLI（`agy`）への移行対応。

## ファイル

| ファイル | 用途 |
|---|---|
| `recommended-settings.json` | agy のユーザー設定 `~/.gemini/antigravity-cli/settings.json` に揃えてほしい推奨値 |

## なぜ「設定ファイル直配布」ではなく「推奨値」なのか

agy の設定は `~/.gemini/antigravity-cli/settings.json` という **ユーザー単位の 1 ファイル** で管理されます。本パッケージのように workspace ごとに deny ポリシーを配って launcher 経由で読ませる仕組みは、agy 側に**現時点では存在しません**（v1.0.0/1.0.1 のバイナリから抽出した設定キー一覧で確認）。

そのため:

1. `scripts/{macos,windows}/launch-agy-safe.{sh,ps1}` は **`agy --sandbox --add-dir <workspace>`** を強制起動する（これは確実に効く）
2. `recommended-settings.json` の各キーは、受講者が **agy 起動後に `/settings` を開いて 1 つずつ ON/OFF を合わせる** 形で適用してください
3. launcher は初回起動時に「推奨設定ファイルが存在します」と案内します（`~/.ai-safety/.agy-recommended-shown` フラグで再表示は抑止）

## 推奨キーの説明

| キー | 推奨値 | 効果（推定） |
|---|---|---|
| `enableTelemetry` | `false` | テレメトリ送信オフ |
| `trustedWorkspaces` | `[]` | デフォルトで信頼ワークスペースを空に。受講者が手動で追加 |
| `allow_access_gitignore` | `false` | `.gitignore` 記載ファイル（`.env` 等）への AI 読み取りをブロック |
| `allow_edit_gitignore` | `false` | 同上の書き換えをブロック |
| `allow_auto_run_commands` | `false` | 自動コマンド実行を抑止 |
| `allow_all` | `false` | 全許可モードを明示的に拒否 |

## キー有効性の確認状況

- v1.3.0 時点で **agy インタラクティブモードでの確認は未実施**（受講者環境がまだ整っていない、`--print` 非対話モードではツール承認ダイアログでハングするため検証不能）
- **v1.3.1 で受講者環境にて実機再検証** する予定
- キーが無視された場合も、launcher 強制の `--sandbox` と agy 1.0.1 の `proceed-in-sandbox` モードが防御として機能する

## 見守りモニター（コーチ解説）は agy 対象外

本パッケージの見守りモニターのコーチ解説・追問は `claude` / `codex` 専用です。agy は hook の注入点を持たない別系統のため、モニターに安全イベントもコーチ解説も表示されません。agy は本 README の `--sandbox` ＋推奨設定で守る設計（hook ベースの claude/codex とは別防御系統）です。

## 関連ドキュメント

- `docs/04_Cursor_でCodexとGeminiを起動.md` — Day3 ハンズオン（agy 並立対応）
- `docs/99_known_issues.md` — Gemini CLI → Antigravity CLI 移行セクション
- `docs/tested_versions.md` — agy 動作確認状況
