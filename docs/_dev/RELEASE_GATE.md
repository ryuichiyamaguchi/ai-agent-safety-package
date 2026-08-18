# Release Gate（リリース承認条件）

v1.4.4 から導入された、本パッケージのリリース承認条件を定める文書です。**この条件をすべて満たさない限り、`git push`/`gh release create` は実行しません**。これは v1.4.0 → v1.4.3 で 18 時間に 4 回 hotfix を連発した事故を反省して導入した運用ルールです。

Sena (Claude Code 側) と Zena (Codex 側) の round 002 で合意。

---

## ゲート条件（必須）

リリース前にすべての項目で証跡を残し、Sena / Zena / ryuichi の 3 者で確認します。

### A. macOS doctor pass=13/13

仮想 workspace で install + doctor を実行し、以下が全 PASS:

```bash
TEST_WS="/tmp/release-gate-qa-$$"
bash scripts/macos/install.sh "$TEST_WS"
bash "$TEST_WS/.ai-safety/hooks/macos/doctor.sh" "$TEST_WS"
```

期待出力:

```
PASS 1 prompt asks protected read
PASS 1 shell protected read
PASS 2 shell network command
PASS 3 scripted protected read
PASS 4 write outside workspace
PASS 5 recursive forced delete
PASS 6 generated script protected read
PASS 7 WebFetch unauthorized domain
PASS control allowed docs domain
PASS codex mac sandbox blocks outside write
PASS drill fail-closed without policy.json
PASS drill fail-closed with broken policy JSON
PASS drill fail-closed with missing required key (secretRegex)
doctor summary: pass=13 fail=0
```

**1 件でも fail があれば release 不可**。fail-closed drill (新規 3 件: policy 不在 / 破損 / 必須 key 欠落) は v1.4.4 から追加された Mac SSOT 化対応の検証。

### B. release-version-check.sh で SSOT drift なし

`policy/safety-policy.json` の `packageVersion` を SSOT として、全 active docs / installer / workspace-template の version 表記が一致:

```bash
bash scripts/release-version-check.sh
```

期待出力（末尾）:

```
Summary: OK=NN WARN=NN FAIL=0
RESULT: PASS
```

**FAIL>0 なら release 不可**。WARN は許容（changelog / history / 引用ブロック内の歴史的言及）。

### C. Windows representative env での one-click 実機検証

以下のいずれかの環境で `install-one-click.bat` をダブルクリックし、完走 + doctor pass=11/11 (もしくは Windows 用 doctor の同等 PASS):

- **講師 PC**: 山口さんの講座運用 Windows 機
- **representative env**: PS 5.1 + 管理者権限なし + 日本語ユーザー名 + SmartScreen 有効

検証項目:

1. ZIP ダウンロード → ブロック解除 → 展開 → `install-one-click.bat` ダブルクリック
2. SmartScreen 警告で「詳細情報 → 実行」を選んで進めること
3. install 完了画面に「**毎回この手順で起動してください**」+ `launch-codex-safe.ps1` のフルコマンドが表示されること
4. doctor.ps1 を実行して pass 11+ 件、fail=0
5. `launch-codex-safe.ps1` が `policy/safety-policy.json` を読み込めること（Mac の SSOT 化と整合）

**未実施なら release を `not classroom-ready` と明示**して止めるか、Windows 実機検証を完了させてから push する。

### D. Release notes に検証コマンドと結果を記録

`gh release create` の `--notes` で以下を明記:

- Mac doctor 実行コマンドと最終行（`doctor summary: pass=13 fail=0`）
- `release-version-check.sh` の Summary 行
- Windows 実機検証の有無（実施したなら誰の PC で / いつ / 結果）

検証未実施の場合は「**not classroom-ready**」タグを title に付与（例: `v1.4.4 (not classroom-ready)`）。

### E. diff scope が Slice に収まっていること

v1.4.4 は Slice 1 (release blocker) の合意範囲のみ。以下のディレクトリ外を git diff で変更していないこと:

- `scripts/macos/lib/safety_policy.sh`
- `scripts/macos/doctor.sh`
- `scripts/windows/install-one-click.bat`
- `scripts/macos/install-one-click.command`
- `docs/00_クイックスタート.md`
- `docs/90_守れる-守れない.md`
- `scripts/release-version-check.sh` (新規)
- `policy/safety-policy.json` (packageVersion bump のみ)
- 全 active docs の version 表記
- `docs/tested_versions.md` の v1.4.4 セクション
- `workspace-template/AGENTS.md` の version 表記
- `install-one-click.{bat,command}` のヘッダ version 表記

スコープ外（Slice 2 候補）が混入していたら、commit を分離するか release を v1.5.0 に格上げ判断。

---

## 承認フロー

```
[Slice 1 実装完了]
    ↓
[Phase C: A + B 実機検証 (Sena 側で実施)]
    ↓
[Zena 再合流: 上記 A〜E の証跡 review]
    ↓
[ryuichi 最終 Go]
    ↓
[Sena が commit / tag / push / ZIP / Release create]
```

**Zena の review pass なし、または ryuichi の Go なし**で commit / push しない。

---

## v1.4.4 リリース時の証跡（2026-05-28 Sena 側実測）

| 項目 | 結果 | 実測 |
|---|---|---|
| A. doctor pass=13/13 | ✅ PASS | `doctor summary: pass=13 fail=0` |
| B. release-version-check.sh | ✅ PASS | `Summary: OK=13 WARN=77 FAIL=0` |
| C. Windows one-click 実機 | ⏳ 未実施 | 山口さん講師 PC での検証待ち |
| D. Release notes | ⏳ 準備中 | 本ゲート通過後に作成 |
| E. diff scope | ⏳ 確認待ち | Zena 再合流時に最終確認 |

C が未実施の場合、v1.4.4 release は **「not classroom-ready」タグ付き** で公開し、講師 PC 検証後に v1.4.5 で classroom-ready に格上げする運用も選択肢。

---

## 過去事故からの学び（運用ルール固定）

| 事故 | リリース | 学び |
|---|---|---|
| 教室 13 名同時インストール失敗 | v1.4.0 | macOS ドライランだけで release を切らない。Windows 実機検証必須 |
| 全 .ps1 が BOM+LF で PS 5.1 起動不能 | v1.4.1 → v1.4.2 で hotfix | BOM 付与時は CRLF 化も同時に。Lane 完了基準に文字エンコーディング検証を含める |
| doctor.ps1 / launch-claude-safe.ps1 BOM 二重 | v1.4.2 → v1.4.3 で hotfix | Lane 内でファイル別 BOM チェックを必須化 |
| Mac safety_policy.sh が policy.json を読まない | v1.4.4 で修正 | SSOT 約束はコード側で検証可能にする。doctor drill に fail-closed テストを必ず含める |
| install-one-click が素の `codex` を案内 | v1.4.4 で修正 | install 完了画面と Quickstart は **launcher 経由起動を強制誘導** する文言固定 |
| 全 docs に version drift | v1.4.4 で修正 | `policy.packageVersion` を SSOT、`release-version-check.sh` で CI 検証 |

---

## 関連

- engagement: `.sena/engagements/2026-05-28-safety-package-review/`
- Sena/Zena dialog: `dialog/zena-to-sena-001.md` 〜 `dialog/sena-to-zena-002.md`
- 過去引き継ぎ: `HANDOVER_v1.4.3.md` (v1.4.3 まで) / `HANDOVER_v1.4.4.md` (本リリース)
