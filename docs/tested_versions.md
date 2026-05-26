# 動作確認済みバージョン

v1.0 リリース時点（2026-05-12）で動作確認した CLI のバージョン。

## CLI

| ツール | 確認済みバージョン | 備考 |
|---|---|---|
| Codex CLI | 0.130.0 | 主たる対象 |
| Claude Code | 2.1.139 | hook 仕様準拠（v1.2.1 から `permissions.deny` 内部ツール対応） |
| Gemini CLI | **0.41.2（凍結版）** | BeforeAgent / BeforeTool / AfterModel / AfterAgent hook。**2026-06-18 で公式廃止**（後継: Antigravity CLI） |
| Antigravity CLI (`agy`) | **1.0.0 / 1.0.1** | v1.3.0 で `launch-agy-safe.{sh,ps1}` を追加し並立対応。`--sandbox` 強制起動 + `proceed-in-sandbox` permission mode で防御。設定ファイル経由の deny キー有効性は未確認（v1.3.1 で実機受講者環境にて再検証） |

## ⚠ Gemini CLI → Antigravity CLI 移行ステータス（v1.3.0 時点）

| 項目 | 状態 |
|---|---|
| Gemini CLI 公式廃止期限 | **2026-06-18**（Pro / Ultra / 無料ティア。Enterprise / Workspace は対象外） |
| Antigravity CLI 実機検証 | **完了**（agy 1.0.0 / 1.0.1 を yamaguchi 開発機で確認） |
| 本パッケージの agy 対応 | **v1.3.0 で並立対応**（Gemini CLI launcher と agy launcher の両方を提供） |

### agy 1.0.0 実機検証で判明した破壊的変更

- **CLI フラグ消失**: `--approval-mode` / `--policy` が agy には**存在しない**。現存フラグは `--add-dir` / `--sandbox` / `--dangerously-skip-permissions` / `--print` / `--prompt-interactive` のみ
- **設定パス**: `~/.gemini/antigravity-cli/settings.json`（互換ディレクトリ）
- **トップレベルキー**: `colorScheme` / `enableTelemetry` / `trustedWorkspaces` を確認。**`permissions.deny` 相当の glob deny スキーマは未確認**
- **MCP**: `url` フィールドが `serverUrl` に rename（破壊的）
- **Plugin import**: `agy plugin import gemini` で旧拡張を変換可能

### 講座運用での当面の方針（v1.3.0）

1. **Gemini CLI 利用者は引き続き `launch-gemini-safe.{sh,ps1}` を使う**（廃止期限 2026-06-18 まで）
2. **agy 利用者は `launch-agy-safe.{sh,ps1}` を使う**（v1.3.0 で新規追加）
3. 受講者が agy / Gemini CLI のどちらを入れていても、本パッケージの launcher 経由なら最低限の防御が効く
4. agy 起動後は `/settings` UI を開いて `configs/agy/recommended-settings.json` の値に揃えるよう案内
5. 2026-06-18 以降は Gemini CLI launcher を段階的に deprecate（v1.3.x で削除予定）

## OS

## OS

| OS | 確認済み | 備考 |
|---|---|---|
| macOS Sonoma 14.x | ✅ | doctor 10/10 PASS |
| Windows 10 21H2+ | 講師PC検証予定 | PowerShell 5.1 |
| Windows 11 | 講師PC検証予定 | PowerShell 5.1 / 7.x 両対応 |

## アップデートとの付き合い方

上記より新しいバージョンの CLI が出た場合：

1. `update-safety` スクリプトを実行
2. `doctor` を再実行
3. fail があれば、講師に連絡

仕様が大きく変わった場合は、本パッケージの新バージョンを待ってください。

## 配布物 SHA-256 ハッシュ一覧（H6: 配布物改ざん検知）

`install.sh` / `install.ps1` 起動時、以下のファイルの SHA-256 を本表と照合する。
mismatch が出た場合、配布 URL すり替えや手動改変の可能性があるため、警告を表示し
**継続するか確認プロンプト**を出す（強制 exit はしない、講師カスタマイズ運用を想定）。

講師は新リリース時にこの表を更新すること。値は `shasum -a 256 <file>`（macOS）
または `Get-FileHash -Algorithm SHA256 <file>`（Windows）で算出する。

### v1.0.x（main HEAD 時点）

| ファイル | SHA-256 |
|---------|---------|
| policy/safety-policy.json | 6d4b9b3a2f7f37572d63f0a3c877b02072b38d91056234d3655a48935c1d73d5 |
| configs/codex/hooks.mac.json | 6f03deee71871c40dd81d098867a4860284700f98135fbb05730936738a729ca |
| configs/codex/hooks.windows.json | 9e7292426dd844ebe4d6ffa20f92f2283e9c1f6e704412bb1321117d4eb62d6a |
| configs/claude/settings.mac.json | 03c7d38c28529afc4866ed500254ca8178426ae16f065b5248d662d7a156231f |
| configs/claude/settings.windows.json | 460045ffb8d55636e98c529647fba93ea3bcd970a36b05af9bf673ee3f479444 |
| configs/gemini/settings.mac.json | b9f45bac5583930c6b44a07a2351c6bd21722503de82983e63cd5f38db2a6213 |
| configs/gemini/settings.windows.json | f061d04699ce366887ae829d0f6fd78ac8d597c9bbaac80bb985332f32d1f012 |
| configs/codex/config.mac.toml | 0261597fa7cc1b4ba057d40e0b8dd05a0da0234e308efa42fcfb952d79d1b295 |
| configs/codex/config.windows.toml | 6deb434337bb80bc4d0ed97c4b430ff844599bca27b90f1fc90310cce0340e00 |
| configs/gemini/policies/safety.toml | d63830fc7548c9987a1d84b7ec0212b6527f639a6af808ee29d00427ceb87f3c |
| workspace-template/aiexclude.template | 9fee69aa1fa5dc7253ebb1419bc1f28b4ca24c8c794f5c6fcc011a1c4a2e444b |

## v1.1.0 配布 zip 全体

| ファイル | SHA-256 |
|---------|---------|
| ai-agent-safety-package-v1.1.0.zip | d906e3f025f95d7cf9fc1e9066eb1bcdef088bd561fd07947fd002a88b0299bf |

このハッシュは配布元と受講者で一致することを確認してください:
`shasum -a 256 ai-agent-safety-package-v1.1.0.zip` (mac) / `Get-FileHash ai-agent-safety-package-v1.1.0.zip` (win)

## v1.2.0 配布 zip 全体

v1.2.0 では agent-monitor（承認時の解説カードと監視ビューア）を追加。
個別ファイル（policy/safety-policy.json 等）の SHA-256 は v1.1.0 から変更なし。
新規ファイル群（`configs/safety/cards/`, `scripts/{macos,windows}/monitor.{sh,ps1}`,
`scripts/{macos,windows}/lib/{explainer.sh,Explainer.ps1}`）はパッケージ zip 全体
のハッシュで検証する。

| ファイル | SHA-256 |
|---------|---------|
| ai-agent-safety-package-v1.2.0.zip | b7e5417d372c2ed4c60b12ed5c8603ea17b08bcdb68976ae24756eaaf3fb8281 |

このハッシュは配布元と受講者で一致することを確認してください:
`shasum -a 256 ai-agent-safety-package-v1.2.0.zip` (mac) / `Get-FileHash ai-agent-safety-package-v1.2.0.zip` (win)

## バックアップ整合性検証（H7: zip-slip / 改ざん）

`backup.sh` / `backup.ps1` は zip 作成時に同名の `.sha256` ファイルを出力する。
`restore.sh` / `restore.ps1` は復元前に以下を検証する。

1. **ハッシュ照合**: `<zip>.sha256` が存在すれば zip の SHA-256 と照合し、不一致なら exit 1
2. **zip-slip 検知**: エントリ名に `../` を含む場合、悪意あるアーカイブとして exit 1
3. 上記が通った場合のみ展開

`.sha256` ファイルが無い場合（旧バックアップ等）はハッシュ照合をスキップするが、
zip-slip 検知は常に実行する。
