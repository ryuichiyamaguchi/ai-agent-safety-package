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
