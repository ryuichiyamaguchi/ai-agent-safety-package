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
| **Codex** | ✅ オート対象 (Mac / Windows 両方) | 自前の OS 金庫を持つ: `--sandbox workspace-write` + `[sandbox_workspace_write] network_access=false`。Windows は `[windows] sandbox="unelevated"` で動作。→ 「Windows 優先」要件を満たす |
| **agy** (Antigravity CLI) | ✅ オート対象 | `--sandbox` を持つ。Windows でのサンドボックス検証手段は実装時に実機確認 (§6 リスク参照) |
| **Claude Code** | ⛔ **MVP 対象外**・手動承認のまま (将来課題) | 受講者の Claude Code は基本 DeepSeek 駆動。かつ Claude のネイティブ金庫 (`sandbox.enabled`) は macOS / Linux(WSL2) のみで、**普通の Windows では効かない**。無理に deny-list だけで開けると「ネット遮断」を保証できず看板に反する |

### 決定事項 (確定済み)

1. **主対象**: 教室の受講者 (リスク許容度は低め、迷わせない UX 最優先)。
2. **解放トリガー**: **明示オプトイン** (専用 launcher または `--auto` フラグ) **かつ** doctor が金庫を検証して全 green のときだけ。意図しない全自動を防ぎ、「承認を読む」教育方針とも両立。
3. **オートのレベル**: 承認プロンプトを外す。OS 金庫 + hook + deny は維持。
   - Codex: `--ask-for-approval` を `untrusted` から **`on-failure`** に下げる (危険時=コマンド失敗時のみ承認を挟む。暴走の最終ストッパーを残しつつ正常作業は止めない。`never` にするかはレビューで再検討)。
   - agy: auto-run 系設定を有効化 (`--sandbox` は維持)。
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

1. **隔離検証ロジック** (新規) — doctor 内に engine 別の「金庫実ドリル」関数として実装し、launcher からも軽量に呼べる形にする。
2. **doctor の軽量サブコマンド** `doctor.sh --isolation-check <engine>` (新規) — その engine の ①②③ だけを高速に実行。全 green なら exit 0。フル `doctor.sh` (引数なし) は従来どおり全ドリル + 隔離チェックを内包し `pass=/fail=` サマリを出す。
3. **launcher の `--auto` 分岐** (`launch-codex-safe.{sh,ps1}` / `launch-agy-safe.{sh,ps1}` を変更) — `--auto` 受付 → doctor 検証 → green で承認解放 / 赤でフォールバック。
4. **フォールバック表示** — 「何が」「なぜ」赤かを 1 行で受講者に示す。

### データフロー

- launcher は `--auto` を受けると、起動前に doctor 軽量サブコマンドを子プロセスとして実行し、**終了コード**で分岐する (標準出力の文字列パースに依存しない fail-closed 設計)。
- doctor 側はドリル結果を `pass=/fail=` 形式 + 終了コードで返す。赤・保留はいずれも非 0。

---

## 4. doctor の実証検証ドリル (安全の心臓部)

**原則: 設定値を読むだけ (宣言) では信用しない。実際にやらせてみて弾かれるか (実証) で判定する。**

### ① workspace 外への書き込み遮断ドリル

- 金庫の中から workspace の **外** のファイルに書き込みを試みる → ファイルが**作られなければ PASS**。
- Codex 分は既存 (`scripts/macos/doctor.sh` の `codex sandbox macos -C <inside> /bin/sh -lc "echo pwn > <outside>"`)。
- **agy 用にも追加**。agy がサンドボックス内コマンド実行を外部から呼べるか実装時に確認。呼べなければ「agy プロセスを起動して境界外に書かせ、作られないことを確認」する代替ドリル。

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

### agy 版

- doctor green なら auto-run 系設定を有効化して起動 (`--sandbox` は維持)。
- agy CLI が auto-run をフラグ / 設定ファイルで制御できるか実装時に確認。制御できなければ「recommended-settings の auto-run を ON にする案内 + doctor 検証」に縮退し、その旨を正直に明記。

### フォールバック表示の原則

- **必ず「何が」「なぜ」赤かを 1 行で**示す (例:「外部ネット遮断を確認できませんでした → 安全のため都度承認モードで起動します。直すには doctor を実行してください」)。
- 受講者が次に何をすればよいか分かる文言にする。

---

## 6. エラー処理・リスク

- **doctor 軽量チェック自体が失敗 (実行不能・例外)** → フェイルクローズ。オートを開けず通常モードへ。
- **ネット遮断ドリルの環境依存** → 「拒否 vs 到達不能」を区別。区別不能は赤 (§4 ②)。
- **agy のサンドボックス検証手段が無い場合** → 代替ドリルへフォールバック。それも無理なら **agy は「設定強制 + 起動フラグ」までしか保証できない**と正直に明記し、agy オートの可否を実装時に再判断 (保証できないなら agy も対象外に降格しうる)。
- **Codex `on-failure` の妥当性** → OS 金庫で封じ込めた上での `on-failure` は安全と判断するが、`never` との比較はレビューで再検討。

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

1. `doctor.sh` / `doctor.ps1` に engine 別の隔離実証ドリル (①②③) と `--isolation-check <engine>` 軽量サブコマンドが入り、テストで「金庫あり=green / 壊した=赤 / オフライン=赤」を出せる。
2. `launch-codex-safe.{sh,ps1}` / `launch-agy-safe.{sh,ps1}` が `--auto` を受け、doctor green で承認解放・赤で理由付きフォールバックする。`--auto` 無しの従来動作は不変 (回帰テスト green)。
3. フォールバック時に「何が・なぜ」赤かが 1 行で受講者に表示される。
4. Mac で Codex の①②③ドリルが実機 green。Windows は実機で doctor + launcher 分岐を確認。
5. agy のサンドボックス検証可否を実機判定し、保証レベルを spec/docs に正直に反映。
6. Claude は MVP 対象外であること、将来対応の必須事項 (§7) が docs に記録される。
