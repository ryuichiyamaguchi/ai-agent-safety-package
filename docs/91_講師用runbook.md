# 講師用 Runbook

職業訓練校マーケティング制作講座 Day4（2026-05-15 金）でこのパッケージを使う際の進行マニュアルです。

## 事前準備（5/12〜5/14）

### 5/12（火）夜 — 設計確定

- ✅ パッケージ実装完了（Codex によって v1.0 構築済み）
- ✅ Mac 実機で doctor 10/10 PASS 検証済み

### 5/13（水）— Windows 検証日

- 講師 PC（Windows）に v1.0 をインストール
- `doctor.ps1` を走らせて 10/10 PASS を確認
- 失敗項目があれば、`docs/99_known_issues.md` に追記、または修正版をリリース

### 5/14（木）— Day3、配布日

- Day3 は前田先生回（AI なし）
- 講師は配布用 ZIP の URL（GitHub Release）と QR コードを準備
- Day3 終了時または直後に受講者へ配布通知（LINE / メール / 紙）
- 「Day4 までに各自インストールしてきてください」と告知

## Day4（5/15 金）当日の進行

### 0:00 – 0:15　起動の儀式（Day1 の傷を癒す）

- 全員で講座室にあるパソコンを開き、Cursor を起動
- `Desktop\my-project` フォルダ（インストール済み）を開く
- 全員で `launch-codex-safe.ps1` を叩く
- Codex CLI のプロンプトが出た時点で「Day1 の呪い、解除」と宣言

**狙い**：Day1 で「動かない」体験をした全員が、Day4 では「最初の 15 分で動く」体験を共有する。

### 0:15 – 1:00　演習 A：秘密の暴露を試す（exercises/01）

- AI に「`.env` の中身を表示して」と依頼してもらう
- 安全装置がブロックして、理由を表示する
- ペアで「なぜ止まったのか」を 2 分で話し合う

**狙い**：「これは私を守ってくれている」と納得させる。

### 1:00 – 1:45　演習 B：偽情報の罠（exercises/02）

- 用意した「罠 Web 文書」のローカルファイルを AI に読ませる
- インジェクション文に従わず、ブロックされる体験
- 「AI も騙される。でもツールが守ってくれる」を体感

### 1:45 – 2:30　演習 C：危険コマンドの拒否（exercises/03）

- AI に `rm -rf` や `curl` を頼んでみる
- ブロックされる挙動を確認
- doctor を実際に走らせて 10/10 を見せる

### 2:30 – 2:50　議論：もし安全装置がなかったら

- 「Day1 の状態でこれをやっていたら何が起きていたか」を全員で言語化
- 配布した「守れる-守れない 1 枚資料」を埋める

### 2:50 – 3:00　まとめ

- 「Day1 で苦労したのは、皆さんが未熟だったからではなく、**道具が剥き出しだった**から」
- 「今日からは、**安全な道具を選べること自体が、最高のリテラシー**」
- 自宅 PC での再現方法（OS 別ドキュメント）を確認

## トラブルシュート

### `doctor` で fail が出る

| fail 項目 | 原因 | 対処 |
|---|---|---|
| 1 prompt asks protected read | guard-prompt スクリプトが起動していない | hook パス確認、PowerShell 実行ポリシー再設定 |
| 2 shell network command | guard-bash 起動失敗 / Codex sandbox 無効 | Codex CLI バージョン確認 |
| 4 write outside workspace | guard-write スクリプトの権限不足 | `Get-ExecutionPolicy` 確認 |
| 7 WebFetch unauthorized | allowedDomains 設定読込失敗 | `policy/safety-policy.json` 存在確認 |

### インストール時のエラー

- PowerShell 実行ポリシー → `-ExecutionPolicy Bypass` を必ず付ける
- パスが日本語フォルダ含む → 解凍先を Desktop 等のシンプルなパスに
- ZIP 展開で文字化け → Windows 標準の「すべて展開」を使う（Lhaplus 等の古いツール NG）

### 受講者の PC で動かない

- まず `collect-status.ps1` を走らせて結果を講師に提出してもらう
- バージョン情報・ファイル存在を確認
- 必要なら別 PC で実行（学校 PC は基本的に同一構成なので、隣の PC でも試す）

### Codex CLI が認証で詰まる（Day1 再現）

- そのまま当該受講者は **Cursor 拡張機能（Gemini Code Assist）に切り替え**
- Cursor 拡張なら認証は Cursor 側で完結、Codex CLI 不要
- 演習教材は同じものを Cursor 拡張で実施

## 自宅利用への移行

Day4 終了後、受講者は自宅 PC でも同じパッケージを使えます。

- 自宅 Windows → `docs/02_自宅Windowsで使う.md` を案内
- 自宅 Mac → `docs/03_自宅Macで使う.md` を案内
- Day5 以降の制作演習を、自宅と学校の両方で継続できる

## v1.0 リリース後の方針

- バグ報告は GitHub Issues か講師の連絡先へ
- マイナーアップデートは v1.0.x として継続リリース
- メジャー機能追加（ローカル LLM 判定、ダッシュボード等）は v1.1+ で検討

## 関連資料

- 設計の議論経緯：`06_notes/2026-05-12_ai-agent-safety-pack_設計議論まとめ.html`
- 設計確定版：`06_notes/2026-05-12_ai-agent-safety-pack_設計確定版.html`
- 参考にした思想：中島大介氏（株式会社メリル）「Claude Code Safety Hub」（YouTube「ウェブ職TV」）
