# Safe Auto Mode — 設計仕様 (spec)

- **日付**: 2026-06-01
- **ブランチ**: `feat/safe-auto-mode`
- **対象パッケージ**: ai-agent-safety-package (v1.5.0 系の上に追加)
- **前提メモ**: `memory/safe-auto-mode-handoff.md`、関連: DeepSeek Gateway (`memory/deepseek-gateway-handoff.md`)

---

## 1. 背景とねらい

安全パッケージは危険操作を「都度承認 / ブロック」して受講者を守る。しかしこれは AI エージェントの **オートモード(自動実行)の便利さを放棄**している面がある。受講者にもその便利さを **安全に** 享受させたい。

`--dangerously-skip-permissions` を素で踏ませるのは危険なので、**OS レベルの隔離(以下「金庫」)が実際に効いていると検証できたときだけ、承認プロンプトを外す**仕組みを作る。

### 中心となる安全モデル

> **金庫が先、承認解放は後。** OS が「外部送信」と「workspace 外書き込み」を遮断していると doctor が**実証**できたときだけ、都度承認の手間を消す。OS 金庫・hook・deny の多層防御は解放後も一切無効化しない(最後の砦として常時稼働)。

「金庫(OS サンドボックス)」とは、AI のプロセスを OS レベルで閉じ込め、(a) 外部ネットワークへの送信を遮断し、(b) 作業フォルダ(workspace)の外への書き込みを遮断する仕組みを指す。金庫の中なら AI が何をしても外に影響が出ないため、承認を外しても安全が保てる、というのが解放の根拠。

---

## 2. スコープ (MVP)

### 対象エンジン

| エンジン | MVP での扱い | 根拠 |
|---|---|---|
| **Codex** | ✅ オート対象・**実証検証(強)** (Mac / Windows 両方) | 自前の OS 金庫を持つ: `--sandbox workspace-write` + `[sandbox_workspace_write] network_access=false`。`codex sandbox` サブコマンドで doctor が金庫を**実証検証できる**。Windows は `[windows] sandbox="unelevated"` で動作。→ 「Windows 優先」要件を満たす |
| **agy** (Antigravity CLI) | ⚠️ オート対象・**宣言ベース(弱)** | `--sandbox`(terminal restrictions)+ `--dangerously-skip-permissions` を持つが、**サンドボックス内コマンドを外部実行する手段(`codex sandbox` 相当)が無く、doctor が金庫を独立検証できない**(実機確認 2026-06-01)。ryuichi 判断で `--sandbox` フラグを**信頼**してオートを出す。Codex と異なり**実証されていない**ことを docs に正直明記する(§4・§6・docs 90 の overclaim 回避方針)|
| **Claude Code** | ⛔ **MVP 対象外**・手動承認のまま (将来課題) | 受講者の Claude Code は基本 DeepSeek 駆動。かつ Claude のネイティブ金庫 (`sandbox.enabled`) は macOS / Linux(WSL2) のみで、**普通の Windows では効かない**。無理に deny-list だけで開けると「ネット遮断」を保証できず看板に反する |

### 決定事項 (確定済み)

1. **主対象**: 教室の受講者 (リスク許容度は低め、迷わせない UX 最優先)。
2. **解放トリガー**: **明示オプトイン** (専用 launcher または `--auto` フラグ) **かつ** doctor のチェックが green のときだけ。意図しない全自動を防ぎ、「承認を読む」教育方針とも両立。
   - Codex は**実証**チェック(実際に弾かれるか試す)。agy は**宣言**チェック(agy が存在し launcher が `--sandbox` を強制適用することの確認のみ。金庫の効力は実証しない)。
3. **オートのレベル**: 承認プロンプトを外す。OS 金庫 + hook + deny は維持。
   - Codex: `--ask-for-approval` を `untrusted` から **`on-failure`** に下げる (危険時=コマンド失敗時のみ承認を挟む。暴走の最終ストッパーを残しつつ正常作業は止めない。`never` にするかはレビューで再検討)。
   - agy: green のとき **`--dangerously-skip-permissions`** を付ける (`--sandbox` は維持)。これは宣言ベースの解放であり、Codex のような実証保証は無いことを docs に明記。
4. **フォールバック**: 金庫が検証できなければ **理由付きメッセージを表示してから通常モード (都度承認) で起動**。黙って落とさない。
5. **フェイルクローズ**: 検証が「保留 (判定不能)」でも安全側に倒し、オートを開けない。

### 非対象 (Out of Scope)

- Claude Code のオート化 (将来課題、§7 に必須事項を記録)。
- `never` (完全無人) を既定にすること (レビューで再検討の余地として残す)。
- 新しいエンジンの追加。

---

## 3. アーキテクチャ

```
受講者が「オートで起動」を選ぶ (--auto / 専用 launcher)
        │
        ▼
 ┌──────────────────────────────────────┐
 │ doctor.sh --isolation-check <engine> │  ← ゲート (実証検証)
 │   ① workspace 外に書けないか           │
 │   ② 外部ネットに送信できないか           │
 │   ③ hook / deny が効くか (既存ドリル)    │
 └──────────────────────────────────────┘
        │ exit 0 (全 green)        │ exit≠0 (赤 or 保留)
        ▼                          ▼
  承認を外して起動            理由付きメッセージ + 通常モード起動
  Codex: --ask-for-approval    「⚠ オートを有効にできません
         on-failure             理由: <赤の項目>
  agy:   auto-run 有効化         → 安全のため都度承認で起動します」
        │                              │
        ▼                              ▼
  最後の砦は常時稼働:          従来の --ask-for-approval untrusted で起動
  OS 金庫 (書込/ネット遮断)
  + PreToolUse hook (exit/deny)
  + permissions.deny
```

### コンポーネント

1. **隔離検証ロジック** (新規) — doctor 内に engine 別のチェック関数として実装 (Codex=実証ドリル / agy=宣言チェック)、launcher からも軽量に呼べる形にする。
2. **doctor の軽量サブコマンド** `doctor.sh --isolation-check <engine>` (新規) — Codex はその実証ドリル①②、agy は宣言チェック④を高速に実行。green なら exit 0。フル `doctor.sh` (引数なし) は従来どおり全ドリル + 隔離チェックを内包し `pass=/fail=` サマリを出す。
3. **launcher の `--auto` 分岐** (`launch-codex-safe.{sh,ps1}` / `launch-agy-safe.{sh,ps1}` を変更) — `--auto` 受付 → doctor 検証 → green で承認解放 / 赤でフォールバック。
4. **フォールバック表示** — 「何が」「なぜ」赤かを 1 行で受講者に示す。

### データフロー

- launcher は `--auto` を受けると、起動前に doctor 軽量サブコマンドを子プロセスとして実行し、**終了コード**で分岐する (標準出力の文字列パースに依存しない fail-closed 設計)。
- doctor 側はドリル結果を `pass=/fail=` 形式 + 終了コードで返す。赤・保留はいずれも非 0。

---

## 4. doctor のチェック (安全の心臓部)

**原則 (Codex): 設定値を読むだけ (宣言) では信用しない。実際にやらせてみて弾かれるか (実証) で判定する。**
**例外 (agy): `codex sandbox` 相当の外部実行手段が無いため実証できない。agy は宣言チェック (agy が存在し launcher が `--sandbox` を強制適用すること) のみ。実証していないことを docs に明記 (overclaim 回避)。**

Codex には ①②③ の実証ドリルを適用。agy には ④ の宣言チェックを適用する。

### ① workspace 外への書き込み遮断ドリル (Codex のみ・実証)

- 金庫の中から workspace の **外** のファイルに書き込みを試みる → ファイルが**作られなければ PASS**。
- Codex は既存 (`scripts/macos/doctor.sh` の `codex sandbox macos -C <inside> /bin/sh -lc "echo pwn > <outside>"`)。

### ② 外部ネット送信遮断ドリル (新規・最重要)

- 金庫の中から、**許可リストに無い実在の宛先** (例 `example.com:443`) へ TCP 接続を試みる (データは送らず接続試行のみ)。
- 判定基準を厳密に分ける:

  | 結果 | 解釈 | 判定 |
  |---|---|---|
  | OS / サンドボックスが**即拒否** (EPERM / operation not permitted 等) | 金庫が効いている | ✅ PASS |
  | **接続が成立してしまう** | 金庫に穴 | ❌ FAIL |
  | タイムアウト / 到達不能のみ (拒否か単にオフラインか区別不能) | 効力を実証できない | ⚠️ 保留 → **安全側で赤** (オートを開けない) |

- 実在ドメインを宛先にすることで「金庫無効なら必ず接続が成立する」= 穴を確実に検出できる。
- **オフライン誤判定対策**: 「即拒否 (金庫由来)」と「タイムアウト/到達不能 (環境由来)」を区別する。区別できない場合は安全側 (赤)。判定方法の細部 (接続エラーの種類で分岐) は実装で詰める。

### ③ hook / deny ドリル (既存を流用)

- 既存の doctor ドリル (保護パス読取 block / ネットワークコマンド block / fail-closed drill 等) がそのまま「最後の砦が生きている」証拠になる。`--isolation-check` では必要最小限のサブセットを回す。

### ④ agy 宣言チェック (agy のみ・実証ではない)

- `--isolation-check agy` は **agy バイナリが存在し、launcher が `--sandbox` を強制適用する構成であること**だけを確認して green を返す。
- **金庫の効力 (ネット遮断・workspace 外書込遮断) は実証しない**。`--sandbox` の "terminal restrictions" を信頼するのみ。
- doctor / launcher の出力と docs に「agy のオートは宣言ベース (未実証)、Codex より保証が弱い」と明示する (overclaim 回避)。agy が存在しなければ赤 (= フォールバック)。

---

## 5. launcher の分岐とフォールバック

### Codex 版 (agy も同型)

```
launch-codex-safe.sh [workspace] [prompt] [--auto]
   │
   --auto 無し ──────────▶ 従来どおり --ask-for-approval untrusted で起動 (現状維持・回帰禁止)
   │
   --auto 有り
   ▼
   doctor.sh --isolation-check codex
   │
   exit 0 (全 green)              exit≠0 (赤/保留)
   ▼                              ▼
   承認を外して起動                理由付きメッセージ表示
   --ask-for-approval on-failure   → --ask-for-approval untrusted で起動
   (--sandbox workspace-write +    (フォールバック)
    network_access=false は維持)
```

### agy 版 (宣言ベース)

```
launch-agy-safe.sh [workspace] [prompt] [--auto]
   │
   --auto 有り
   ▼
   doctor.sh --isolation-check agy   (④ 宣言チェック: agy 存在 + --sandbox 強制)
   │
   exit 0 (green)                      exit≠0 (agy 無し等)
   ▼                                   ▼
   --sandbox --dangerously-skip-       理由付きメッセージ表示
   permissions で起動                   → --sandbox のみ(通常承認)で起動
   (実証保証なし=docs に明記)
```

- 実機確認 (2026-06-01): agy には `--sandbox` と `--dangerously-skip-permissions` がある。`codex sandbox` 相当の外部実行手段は無いため金庫を実証できない。
- green のとき `--dangerously-skip-permissions` を付与 (`--sandbox` 維持)。**宣言ベースの解放であり Codex のような実証保証は無い**ことを launcher の起動時メッセージと docs に明記する。

### フォールバック表示の原則

- **必ず「何が」「なぜ」赤かを 1 行で**示す (例:「外部ネット遮断を確認できませんでした → 安全のため都度承認モードで起動します。直すには doctor を実行してください」)。
- 受講者が次に何をすればよいか分かる文言にする。

---

## 6. エラー処理・リスク

- **doctor 軽量チェック自体が失敗 (実行不能・例外)** → フェイルクローズ。オートを開けず通常モードへ。
- **ネット遮断ドリルの環境依存** → 「拒否 vs 到達不能」を区別。区別不能は赤 (§4 ②)。
- **agy の金庫は実証できない (確定リスク)** → agy のオートは `--sandbox` を信頼する**宣言ベース**。`--sandbox` が実際にネット遮断するかは未検証。ryuichi 判断で許容。**残存リスク**: agy の `--sandbox` がネット遮断を伴わない場合、プロンプトインジェクションされた agy が承認なし (`--dangerously-skip-permissions`) でデータを外部送信しうる。→ 緩和策: (a) docs に「未実証・Codex より弱い」と明記、(b) `--sandbox` を必ず強制、(c) agy が無ければ赤でフォールバック。将来 agy に検証手段が出たら実証へ格上げ。
- **Codex `on-failure` の妥当性** → OS 金庫で封じ込めた上での `on-failure` は安全と判断するが、`never` との比較はレビューで再検討。

### 既知の問題 / フォローアップ (2026-06-01 実装中に発見)

- **codex sandbox CLI のスキーマ移行 (要対応・別件)**: 実機 codex 0.135.0 では `codex sandbox` の構文が変わっており、(a) 旧 `codex sandbox macos -C ...` の `macos` は実行コマンド扱いになり `execvp() of 'macos' failed` で落ちる、(b) 正しい `codex sandbox --permissions-profile <NAME> --cd <DIR> <CMD>` は新しい `[permissions]` テーブル設定を要求する (`Error: default_permissions requires a [permissions] table`)。パッケージの `configs/codex/config.{mac,windows}.toml` は旧構造 (`sandbox_mode` / `[sandbox_workspace_write]` / `[profiles.safe]`) のまま。
  - **影響 1**: Safe Auto Mode の Codex green パスは現行 codex では到達不能 (ただし doctor が HOLD=赤 → フォールバックするので**安全**。オートが開かないだけ)。
  - **影響 2**: **既存の `doctor.sh` の codex sandbox チェック (line ~53-66) も同じ旧構文で、現行 codex では偽 PASS している** (v1.5.0 出荷済みの既存バグ)。
  - **対応 (別エンゲージメント推奨)**: codex 0.135.0 の `[permissions]` スキーマを調査し、`config.{mac,windows}.toml` と doctor の sandbox 呼び出し (既存 + 新規ドリル) を新構文に移行する。Safe Auto Mode の実装ロジック自体は終了コード契約で正しく、この移行とは独立 (移行後に green パスが有効化される)。

---

## 7. 将来 Claude Code 対応時の必須事項 (MVP 対象外・記録のみ)

1. `sandbox.enabled: true` + ネットワーク allow-list を Claude settings に追加し、doctor の ②③ を Claude にも適用 (出典: code.claude.com/docs/en/sandboxing.md)。
2. `permissions.disableBypassPermissionsMode: "disable"` を **オート時だけ解除**した settings に切り替える (通常時は禁止のまま)。bypassPermissions の起動は `--permission-mode bypassPermissions` または `--dangerously-skip-permissions`。
3. **#24327 デッドロック対策**: Opus 4.6+ では PreToolUse hook の `exit 2` ブロックを Claude が「ユーザー拒否」と誤解し、無言で human input 待ちのデッドロックに入ることがある (intermittent)。対策として PreToolUse guard を `exit 2` から JSON 出力へ変更:
   ```json
   {
     "hookSpecificOutput": {
       "hookEventName": "PreToolUse",
       "permissionDecision": "deny",
       "permissionDecisionReason": "<拒否理由>",
       "additionalContext": "修正して再試行してください: <ヒント>"
     }
   }
   ```
   (出典: code.claude.com/docs/en/hooks.md の Decision control 節)
4. 普通の Windows (WSL2 なし) では Claude の金庫が無いため Claude オートは出さない。WSL2 検出時のみ将来開放。
5. DeepSeek 駆動時は送信 Gateway 必須 (`memory/deepseek-gateway-handoff.md` と連結)。

### bypassPermissions と金庫・hook の関係 (確認済みの技術前提)

- Claude のネイティブ金庫 (`sandbox.enabled`) は permission-mode と独立して効く → **bypassPermissions でも OS 隔離は生き続ける**。
- bypassPermissions 下でも (a) PreToolUse hook は実行され、(b) hook の `exit 2` はツールを止め、(c) `permissions.deny` は効く。評価順序: hook(exit2) > deny > ask > allow。bypass は ask の承認プロンプトだけをスキップする。
- (出典: code.claude.com/docs/en/permissions.md, hooks.md, permission-modes.md, sandboxing.md — claude-code-guide で 2026-06-01 確認)

---

## 8. テスト方針

- **doctor ドリルの自己テスト**: ② ネット遮断ドリルが「金庫あり=PASS / 金庫を意図的に壊した状態=FAIL / オフライン=保留(赤)」を正しく出すかを検証 (既存の fail-closed drill と同じ流儀)。
- **launcher 分岐テスト**: doctor を green / 赤に固定したスタブで、launcher が「承認外す / フォールバック」を正しく選ぶかを検証 (実 CLI を起動せず、組み立てたコマンド配列を検査する形)。
- **回帰テスト**: `--auto` 無しの従来起動が一切変わらないこと (Codex / agy 双方)。
- **Windows**: `.ps1` 側で同等のテスト (doctor.ps1 のドリル + launcher 分岐)。

---

## 9. 完了条件 (Definition of Done)

1. `doctor.sh` / `doctor.ps1` に Codex の隔離実証ドリル (①②) + agy の宣言チェック (④) + `--isolation-check <engine>` 軽量サブコマンドが入り、テストで「金庫あり=green / 壊した=赤 / オフライン=赤」(Codex) と「agy 存在=green / agy 無し=赤」(agy) を出せる。
2. `launch-codex-safe.{sh,ps1}` が `--auto` で doctor green→`on-failure` / 赤→理由付き `untrusted` フォールバック。`launch-agy-safe.{sh,ps1}` が `--auto` で green→`--dangerously-skip-permissions` 付与 (`--sandbox` 維持) / 赤→理由付き `--sandbox` のみ。`--auto` 無しの従来動作は不変 (回帰テスト green)。
3. フォールバック時に「何が・なぜ」赤かが 1 行で受講者に表示される。
4. Mac で Codex の①②ドリルが実機 green。Windows は実機で doctor + launcher 分岐を確認。
5. agy のオートが**宣言ベース (未実証・Codex より弱い)** であることを launcher 起動時メッセージと docs に正直明記する。
6. Claude は MVP 対象外であること、将来対応の必須事項 (§7) が docs に記録される。
