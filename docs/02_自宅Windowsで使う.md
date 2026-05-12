# 自宅 Windows で使う

自分の Windows PC で AI エージェント安全運用パッケージを使う手順です。

## 前提

- Windows 10 / 11
- 自分のユーザーアカウント（管理者権限あり推奨）
- Cursor または VS Code がインストール済み
- Codex CLI がインストール済み（`codex --version` が動く）

Cursor / Codex CLI のインストールが未済の方は、まず以下を済ませてください。

- Cursor：[cursor.com](https://cursor.com) から DL してインストール
- Codex CLI：Cursor 内で `npm install -g @openai/codex`（または公式手順）

## ステップ 1：パッケージのダウンロード

GitHub の Release ページから ZIP をダウンロードします。

ダウンロード先：**ユーザーフォルダ直下**（`C:\Users\あなたの名前\`）または**デスクトップ**

## ステップ 2：展開

ZIP を右クリック →「すべて展開」→ 展開先を選んで「展開」。

## ステップ 3：インストール

Cursor で展開したフォルダを開きます。

Cursor の Terminal で以下を実行：

```
powershell -ExecutionPolicy Bypass -File scripts\windows\install.ps1 -Workspace "$env:USERPROFILE\Documents\my-ai-workspace"
```

`my-ai-workspace` は好きな名前に変更可。`Documents` 配下に作るのを推奨します。

`-InstallGlobalClaudeSettings` オプションを付けると、グローバルの Claude 設定も上書きされます（バックアップ付き）。`safe-workspace` の外で Claude を起動した時にも基本防御を効かせたい場合のみ付けてください。

```
powershell -ExecutionPolicy Bypass -File scripts\windows\install.ps1 -Workspace "$env:USERPROFILE\Documents\my-ai-workspace" -InstallGlobalClaudeSettings
```

## ステップ 4：動作確認

```
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Documents\my-ai-workspace\.ai-safety\hooks\windows\doctor.ps1"
```

`pass=10 fail=0` を確認。

## ステップ 5：使う

```
cd $env:USERPROFILE\Documents\my-ai-workspace
powershell -ExecutionPolicy Bypass -File .ai-safety\hooks\windows\launch-codex-safe.ps1
```

これで Codex CLI が安全装置付きで起動します。

Claude Code を使う場合：

```
powershell -ExecutionPolicy Bypass -File .ai-safety\hooks\windows\launch-claude-safe.ps1
```

## 自分の本物のプロジェクトで使う

`my-ai-workspace` の中に自分の業務プロジェクトのファイルを置けば、そのまま安全装置付きで作業できます。

ただし以下を守ってください：

- 本物の `.env` を置いてもよい（hook が保護してくれる）
- 本物の API キー類をチャット欄に直接ペーストしない
- アップデート時は `doctor` を再実行

## バックアップ / リストア / アップデート

```
powershell -ExecutionPolicy Bypass -File .ai-safety\hooks\windows\backup.ps1
powershell -ExecutionPolicy Bypass -File .ai-safety\hooks\windows\update-safety.ps1
powershell -ExecutionPolicy Bypass -File .ai-safety\hooks\windows\restore.ps1
```

## 困った時

- `doctor` で fail → そのまま使わない、`docs\99_known_issues.md` を見る、講師へ
- インストールエラー → 管理者権限で再実行を試す
- Codex / Claude のメジャーアップデート後 → `update-safety.ps1` を走らせる
