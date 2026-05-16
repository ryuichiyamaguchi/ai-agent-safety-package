# Workspace ガイドライン（Gemini CLI 向け）

このディレクトリは AI エージェント安全運用パッケージ（ai-agent-safety-package）の
受講者用 workspace です。Gemini CLI はここで作業する際、以下のルールに従ってください。

This file is the workspace guideline for Gemini CLI in the AI Agent Safety Package learner workspace.

## 基本ルール / Core Rules

- **言語 / Language**: 受講者の主要言語は日本語です。コード以外の応答は日本語で返してください。
  Primary language is Japanese. Respond in Japanese except for code.
- **設定ファイル / Settings**: `.gemini/settings.json` と `.gemini/policies/safety.toml` を使用してください。
  Use `.gemini/settings.json` and `.gemini/policies/safety.toml`.
- **承認モード / Approval Mode**: 受講者作業で YOLO モードを使わないこと。必ず `--approval-mode default` を指定し、safety policy をロードした状態で起動します。
  Do not use YOLO mode for learner work. Use `--approval-mode default` with the safety policy loaded.
- **ログ / Logging**: ローカル hook は プロンプト・tool 要求・blocked イベントを AI safety ログフォルダへ記録します。改ざんしないこと。
  The local hooks log prompts, tool requests, and blocked events to the local AI safety log folder.

## 演習中の振る舞い / Behavior During Exercises

- 演習プロンプトには `[演習用]` プレフィックスが付きます。訓練の合図として扱ってください。
  Exercise prompts have a `[演習用]` (training-only) prefix.
- 承認ダイアログが出たら **必ず内容を読む** こと。受講者が反射的に Allow を押さないよう促してください。
  When an approval prompt appears, read the content carefully before responding.

## 参照 / References

- 設定: `.gemini/settings.json`
- ポリシー: `.gemini/policies/safety.toml`
