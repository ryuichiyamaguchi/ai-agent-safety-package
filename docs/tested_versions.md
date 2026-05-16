# 動作確認済みバージョン

v1.0 リリース時点（2026-05-12）で動作確認した CLI のバージョン。

## CLI

| ツール | 確認済みバージョン | 備考 |
|---|---|---|
| Codex CLI | 0.130.0 | 主たる対象 |
| Claude Code | 2.1.139 | hook 仕様準拠 |
| Gemini CLI | 0.41.2 | BeforeAgent / BeforeTool / AfterModel / AfterAgent hook |

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
| policy/safety-policy.json | 0b0b008cb0ccf1e08ca92bca4cf935ed6e9e64924ac985c7a5d05aa25021f13a |
| configs/codex/hooks.mac.json | 6f03deee71871c40dd81d098867a4860284700f98135fbb05730936738a729ca |
| configs/codex/hooks.windows.json | 9e7292426dd844ebe4d6ffa20f92f2283e9c1f6e704412bb1321117d4eb62d6a |
| configs/claude/settings.mac.json | 03c7d38c28529afc4866ed500254ca8178426ae16f065b5248d662d7a156231f |
| configs/claude/settings.windows.json | 460045ffb8d55636e98c529647fba93ea3bcd970a36b05af9bf673ee3f479444 |
| configs/gemini/settings.mac.json | b9f45bac5583930c6b44a07a2351c6bd21722503de82983e63cd5f38db2a6213 |
| configs/gemini/settings.windows.json | f061d04699ce366887ae829d0f6fd78ac8d597c9bbaac80bb985332f32d1f012 |
| configs/codex/config.mac.toml | c97a0cfb1367fcb0478c6be5f1d31f8b05c6bf5a6e9510c0023d0b4308363a56 |
| configs/codex/config.windows.toml | 00b0b20431e7c5eea6092bd27b91a62343d57052da224583f30bffda35abd30d |
| configs/gemini/policies/safety.toml | d63830fc7548c9987a1d84b7ec0212b6527f639a6af808ee29d00427ceb87f3c |
| workspace-template/aiexclude.template | 9fee69aa1fa5dc7253ebb1419bc1f28b4ca24c8c794f5c6fcc011a1c4a2e444b |

## バックアップ整合性検証（H7: zip-slip / 改ざん）

`backup.sh` / `backup.ps1` は zip 作成時に同名の `.sha256` ファイルを出力する。
`restore.sh` / `restore.ps1` は復元前に以下を検証する。

1. **ハッシュ照合**: `<zip>.sha256` が存在すれば zip の SHA-256 と照合し、不一致なら exit 1
2. **zip-slip 検知**: エントリ名に `../` を含む場合、悪意あるアーカイブとして exit 1
3. 上記が通った場合のみ展開

`.sha256` ファイルが無い場合（旧バックアップ等）はハッシュ照合をスキップするが、
zip-slip 検知は常に実行する。
