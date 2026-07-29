# Workspace Guide for Codex Agents (日本語ガイド)

このファイルは Codex Agents が workspace の文脈を理解するためのものです。
This file is for Codex Agents to understand the workspace context.

## このディレクトリは何か / What This Directory Is

AI エージェント安全運用パッケージ（ai-agent-safety-package v1.14.2）の受講者用 workspace です。
Training workspace for the AI Agent Safety Package (v1.14.2).

## エージェントへの指示 / Agent Instructions

### 日本語

- 受講者と話すときは **必ず日本語** で応答してください
- コードは英語、コメントは日本語が混在して OK
- 演習プロンプトに `[演習用]` が付いている場合、それは訓練の合図です
- `.env` `.codex/auth.json` などの機密ファイルは絶対に開かないこと
- 削除・上書き系の操作は **必ず** 承認ダイアログを出させる（hook 層で deny される設計）
- エージェントは provided safe gateway または launch スクリプト経由でのみ起動すること
- 本物の鍵・トークン・顧客データ・private access ファイルは workspace の外に置くこと
- approval や sandbox 設定を bypass しないこと
- CLI 更新後・重要作業前には doctor スクリプトを実行すること
- 作業可能領域: この workspace 内のみ
- 既定のネットワーク動作: shell network は遮断、WebFetch は allow-list

### English

- Always respond in Japanese when talking to the user.
- Mixed Japanese comments + English code is fine.
- The `[演習用]` prefix on prompts means it is a training exercise.
- Never open secret files such as `.env`, `.codex/auth.json`, etc.
- Delete/overwrite operations must always trigger the approval prompt
  (the hook layer is designed to deny them).
- Start agents only through the provided safe gateway or launch scripts.
- Keep real keys, tokens, customer data, and private access files outside this workspace.
- Do not bypass approval or sandbox settings.
- Run the doctor script after CLI updates and before important work.
- Allowed working area: this workspace only.
- Default network behavior: shell network is blocked; WebFetch is allow-listed.

## 参照ドキュメント / References

- `docs/00_はじめに.md` - 受講者向け導入
- `docs/90_守れる-守れない.md` - 3 層防御モデル
- `policy/safety-policy.json` - 詳細ポリシー
