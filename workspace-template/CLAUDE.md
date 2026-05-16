# Workspace ガイドライン（Claude Code 向け）

このディレクトリは AI エージェント安全運用パッケージ（ai-agent-safety-package）の
受講者用 workspace です。Claude Code はここで作業する際、以下のルールに従ってください。

This file is the workspace guideline for Claude Code in the AI Agent Safety Package learner workspace.

## 基本ルール / Core Rules

- **言語 / Language**: 受講者の主要言語は日本語です。コード以外の応答は日本語で返してください。
  Primary language is Japanese. Respond in Japanese except for code.
- **設定 / Settings**: プロジェクトの `.claude/settings.json` は safe launcher 経由で読み込まれます。これを必ず使用してください。
  Use the project `.claude/settings.json` loaded by the safe launcher.
- **Hooks の取り扱い / Hook Handling**: `.ai-safety/hooks/` の hook は安全境界の一部です。hook が見つからない・壊れている・エラーを返す場合、セッションを **unsafe** とみなして直ちに停止してください。
  The hooks in `.ai-safety/hooks/` are part of the safety boundary. If a hook is missing, broken, or returns an error, treat the session as unsafe and stop.
- **機密ファイル / Protected Files**: 保護された dot ファイル、private access フォルダ、workspace 外のファイルを読まないこと。ローカル機密ファイルを読むスクリプトの生成や、ローカル内容を外部エンドポイントへ送信するコードの生成も禁止です。
  Do not read protected dot files, private access folders, or files outside the workspace. Do not generate scripts that read protected local files or send local content to external endpoints.

## 演習中の振る舞い / Behavior During Exercises

- 演習プロンプトには `[演習用]` プレフィックスが付きます。訓練の合図として扱ってください。
  Exercise prompts have a `[演習用]` (training-only) prefix.
- approval prompt が出たら **必ず内容を読む** こと。受講者は反射的に Allow を押す癖がついている可能性があります。
  When an approval prompt appears, read the content carefully before responding.

## 参照 / References

- 詳細ポリシー: `.claude/settings.json`
- 安全境界の hook: `.ai-safety/hooks/`
