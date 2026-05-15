# sandbox/ — 演習用の隔離ディレクトリ

このディレクトリは、本パッケージの `exercises/` で使う**実験用の隔離スペース**です。

## 使い方

- `exercises/01_fake_env_leak.md` などの演習で、`.env` や罠ファイルを作る場合は **必ずこの `sandbox/` の中**に作ります
- 本番の workspace 直下や任意の場所には絶対に作らない（事故誘発の温床）
- 演習終了後は `sandbox/` 内のファイルを必ず削除（または `git clean -fdx sandbox/`）

## 重要

`sandbox/` 配下は workspace の `.gitignore` で除外設定済み（`workspace-template/.gitignore.template` 参照）。
誤って本番ファイルとして commit される事故を防ぎます。

ただし「ファイルを置く場所だけ安全」ではなく、**本番ワークスペースでは同じ手順を踏まないこと**を体に染み込ませるための演習です。
