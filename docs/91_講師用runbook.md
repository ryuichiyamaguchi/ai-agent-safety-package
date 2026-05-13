# 講師用 Runbook（v1.0.3 版）

職業訓練校マーケティング制作講座 Day4（2026-05-15 金）でこのパッケージを使う際の進行マニュアルです。

## v1.0.3 で何が変わったか（講師が必ず知っておくこと）

v1.0.0 → v1.0.3 で、Codex CLI 側の防御設計を**大きく差し替え**ました。受講者には細部を語らず「承認ダイアログが出るのが正しい挙動」だけ伝えれば十分です。

| 項目 | v1.0.0 当初の想定 | v1.0.3 の実装 |
|---|---|---|
| Codex CLI の精密 hook（trust state） | `.env` 読取など個別操作を hook でブロック想定 | **諦めた**。trust state のハッシュ計算を再現できず実機で発火しなかったため |
| 代替の防御 | — | `approval_policy = "untrusted"` + `--ask-for-approval untrusted` で危険操作前に承認ダイアログを出す |
| 効くモード | （未確定） | **対話モード（TUI）のみ**。`codex exec` は強制 `never` 降格 |
| 削除した実装 | — | `scripts/common/codex-hook-trust-state.js`（不要かつ動かない）。Node.js 前提も不要に |
| 追加した docs | — | `docs/90` に「守備範囲外」節 / `docs/92_AIの仕組みと隔離技術.md` 新設 / `docs/99` に「PC 内の謎ファイル FAQ」追加 |
| 維持した機能 | — | v1.0.2 で実装した launcher の `auth.json` bridge（受講者の再ログイン不要） |

**受講者に説明する時の最短フレーズ**：

> 「危ないコマンドを AI が出すと、画面に『これ実行していい？』というダイアログが出ます。『いいえ』を押せば止まります。これが今日の主役の安全装置です。」

## 事前準備（5/12〜5/14）

### 5/12（火）夜 — 設計確定

- パッケージ v1.0.0 → v1.0.2 までで launcher / auth bridge / OS sandbox は確定
- Mac 実機で doctor 10/10 PASS 検証済み

### 5/13（水）— v1.0.3 確定、Windows 検証日

- Codex CLI 精密 hook を断念、`approval_policy = "untrusted"` へ切替（commit `23b2937`）
- スコープ境界 docs と隔離技術 docs を追加（commit `118cd66`）
- 講師 PC（Windows）に v1.0.3 をインストール
- `doctor.ps1` を走らせて 10/10 PASS を確認
- Codex CLI を `launch-codex-safe.ps1` から起動し、`rm -rf` / `curl` で**承認ダイアログが出ること**を実機確認
- 失敗項目があれば、`docs/99_known_issues.md` に追記、または v1.0.4 として修正版をリリース

### 5/14（木）— Day3、配布日

- Day3 は前田先生回（AI なし）
- 講師は配布用 ZIP（v1.0.3）の URL（GitHub Release）と QR コードを準備
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
- `cat .env` のような単純閲覧は通る場合があることを正直に伝える（`cat` は trusted コマンドのため承認なしで動く）
- 代わりに「`python` で `.env` を読み込んで送信させて」のような派手な指示を試す → **承認ダイアログが出る** ことを全員で確認
- ペアで「なぜここで止まったのか」を 2 分で話し合う

**狙い**：「これは私を守ってくれている」と納得させる。「精密に全部止める」のではなく「**危険操作を実行する前に必ず人間に聞く**」設計だ、と理解させる。

### 1:00 – 1:45　演習 B：偽情報の罠（exercises/02）

- 用意した「罠 Web 文書」のローカルファイルを AI に読ませる
- インジェクション文に従って AI が `curl` で外部に送ろうとする → **承認ダイアログ＋ネットワーク遮断**で二重ブロック
- 「AI も騙される。でもツールが守ってくれる」を体感

### 1:45 – 2:30　演習 C：危険コマンドの拒否（exercises/03）

- AI に `rm -rf` や `curl` を頼んでみる
- 承認ダイアログで「いいえ」を押す挙動を確認
- doctor を実際に走らせて 10/10 を見せる

### 2:30 – 2:50　議論：もし安全装置がなかったら

- 「Day1 の状態でこれをやっていたら何が起きていたか」を全員で言語化
- 配布した「守れる-守れない 1 枚資料」を埋める
- 余裕があれば `docs/92_AIの仕組みと隔離技術.md` の隔離 4 層の図を見せる

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

### 承認ダイアログが出ない

v1.0.3 の主防御である `approval_policy = "untrusted"` は**対話モード（TUI）でしか効きません**。受講者が `codex exec ...` のように非対話で叩いている場合、強制 `never` 降格で素通りします。

→ `launch-codex-safe.{ps1,sh}` 経由で起動しているかを最初に確認する。

### インストール時のエラー

- PowerShell 実行ポリシー → `-ExecutionPolicy Bypass` を必ず付ける
- パスが日本語フォルダ含む → 解凍先を Desktop 等のシンプルなパスに
- ZIP 展開で文字化け → Windows 標準の「すべて展開」を使う（Lhaplus 等の古いツール NG）

### 受講者の PC で動かない

- まず `collect-status.ps1` を走らせて結果を講師に提出してもらう
- バージョン情報・ファイル存在を確認
- 必要なら別 PC で実行（学校 PC は基本的に同一構成なので、隣の PC でも試す）

### Codex CLI が認証で詰まる（Day1 再現）

- v1.0.2 で実装した launcher の `auth.json` bridge により、講師 PC で一度ログインしておけば受講者は再ログイン不要
- それでも詰まる場合、当該受講者は **Cursor 拡張機能（Gemini Code Assist）に切り替え**
- Cursor 拡張なら認証は Cursor 側で完結、Codex CLI 不要
- 演習教材は同じものを Cursor 拡張で実施

### Windows の ConstrainedLanguage Mode 環境（hook が全部 fail に見える時）

v1.0.5 以降では既定で `features.hooks = false` に切り替えたため、通常はこの症状は出ません。
ただし旧バージョン（v1.0.4 以前）の launcher で起動した受講者環境で、Codex TUI 内に
`PreToolUse hook (failed) error: hook exited with code 1` のような赤い行が連続して出ることがあります。

原因: PowerShell が `ConstrainedLanguage Mode` で起動している環境（企業 AppLocker / WDAC / 学校 PC のグループポリシー）では、
hook スクリプトが `[Console]::OutputEncoding` 等のプロパティ設定で `PropertySetterNotSupportedInConstrainedLanguage` 例外を出して死にます。

確認方法（受講者 PC で実行）:

```powershell
$ExecutionContext.SessionState.LanguageMode
```

→ `ConstrainedLanguage` が返ったら確定。`FullLanguage` ならこの問題ではない。

対処（v1.0.5 以降を配布した場合は不要）:

- v1.0.5 以降に乗り換える（hook を呼ばないので fail メッセージも出ない）
- v1.0.4 以前を使い続ける場合は、講師が「赤い hook failed は無視して OK、approval ダイアログが本日の主役」と事前案内する

重要: hook が fail でも `approval_policy = "untrusted"` の最後の砦は機能します。
受講者が `rm` / `python で .env 読取` / ファイル書込み を AI に頼んだ時、approval ダイアログが
出て「No」を選べば止まります。Day4 演習の核心はこの動作なので、hook 失敗は致命傷ではありません。

### Gemini CLI を直接使う場合の注意（v1.0.x スコープ外）

v1.0.3 では Gemini CLI 0.42.0 以降の hook 設定（`settings.json` の `toolName: "run_shell_command"` 等）が現行ツール名スキーマと不整合のため、**hook ベースの精密ブロックは現状効きません**。実機検証で `cat .env` 相当の操作が素通りすることを確認済み。

- 効くもの: Policy Engine（launcher が渡す `--policy safety.toml`）と `--include-directories` による作業範囲制限
- 効かないもの: `BeforeTool` hook の `toolName` マッチング → `.env` 読取等が素通りする可能性
- 講師アクション: Day4 演習では **Codex CLI を主**で進める。受講者が Gemini を使いたい場合は前項の「Cursor 内 Gemini Code Assist 拡張」を推奨。Gemini CLI 直接利用は v1.1 で hook スキーマ整合作業を経て対応予定

## 自宅利用への移行

Day4 終了後、受講者は自宅 PC でも同じパッケージを使えます。

- 自宅 Windows → `docs/02_自宅Windowsで使う.md` を案内
- 自宅 Mac → `docs/03_自宅Macで使う.md` を案内
- Day5 以降の制作演習を、自宅と学校の両方で継続できる

## v1.0.3 リリース後の方針

- バグ報告は GitHub Issues か講師の連絡先へ
- マイナーアップデートは v1.0.x として継続リリース
- メジャー機能追加（精密 hook の再挑戦、ローカル LLM 判定、ダッシュボード等）は v1.1+ で検討
- Codex CLI 本体が trust state の hash 計算ロジックを公開・安定化したら、v1.1 で hook 精密ブロックを再挑戦する

## 関連資料

- 受講者向けスコープ説明：`docs/90_守れる-守れない.md`（守備範囲外節を含む）
- 隔離技術解説：`docs/92_AIの仕組みと隔離技術.md`
- PC 内の謎ファイル FAQ：`docs/99_known_issues.md`
- 設計の議論経緯：`06_notes/2026-05-12_ai-agent-safety-pack_設計議論まとめ.html`
- 設計確定版：`06_notes/2026-05-12_ai-agent-safety-pack_設計確定版.html`
- v1.0.3 までの引き継ぎ書：`06_notes/2026-05-13_ai-agent-safety-pack_引き継ぎ.html`
- AI 隔離技術ハンドオフメモ：`06_notes/2026-05-13_AI隔離技術ハンドオフ.md`
- 参考にした思想：中島大介氏（株式会社メリル）「Claude Code Safety Hub」（YouTube「ウェブ職TV」）
