# 動作確認済みバージョン

v1.0 リリース時点（2026-05-12）で動作確認した CLI のバージョン。

## CLI

| ツール | 確認済みバージョン | 備考 |
|---|---|---|
| Codex CLI | 0.135.0 | 主たる対象。Safe Auto Mode の隔離ドリル/launcher は 0.135 の新 sandbox 構文(`codex sandbox --permissions-profile`)と profile 分離(`safe.config.toml`)前提 |
| Claude Code | **2.1.201（動作確認済み・固定）** | 導入スクリプト（`0_AIツールをまとめて入れる`）は `@2.1.201` を固定インストール。期待版の SSOT は `policy/safety-policy.json` の `testedClaudeCodeVersion`。`launch-claude-safe.{sh,ps1}` と `診断.ps1` が実版と照合し差異を日本語警告する。hook 仕様準拠（v1.2.1 から `permissions.deny` 内部ツール対応） |
| Gemini CLI | **0.41.2（凍結版）** | BeforeAgent / BeforeTool / AfterModel / AfterAgent hook。**2026-06-18 で公式廃止**（後継: Antigravity CLI） |
| Antigravity CLI (`agy`) | **1.0.0 / 1.0.1** | v1.3.0 で `launch-agy-safe.{sh,ps1}` を追加し並立対応。`--sandbox` 強制起動 + `proceed-in-sandbox` permission mode で防御。設定ファイル経由の deny キー有効性は未確認（v1.3.1 で実機受講者環境にて再検証） |

> **Claude Code の版を更新するときは、`policy/safety-policy.json` の `testedClaudeCodeVersion`（SSOT）と、
> user-facing に直書きされた `@x.y.z` リテラルを必ず同時に更新する**こと。直書き箇所:
> `0_AIツールをまとめて入れる-Mac.command` / `0_AIツールをまとめて入れる-Windows.bat` / `docs/05_Claude_Codeを安全に使う.md` /
> `docs/09_各AIのインストール.md` / `スタート.html` / `launch-claude-safe.{sh,ps1}` の不在時案内。
> 片方だけ変えると導入は旧版のまま入り、`launch-claude-safe`/`診断.ps1` の版差警告が全受講者に毎回出るドリフトになる。

## ⚠ Gemini CLI → Antigravity CLI 移行ステータス（v1.3.0 時点）

| 項目 | 状態 |
|---|---|
| Gemini CLI 公式廃止期限 | **2026-06-18**（Pro / Ultra / 無料ティア。Enterprise / Workspace は対象外） |
| Antigravity CLI 実機検証 | **完了**（agy 1.0.0 / 1.0.1 を yamaguchi 開発機で確認） |
| 本パッケージの agy 対応 | **v1.3.0 で並立対応**（Gemini CLI launcher と agy launcher の両方を提供） |

### agy 1.0.0 実機検証で判明した破壊的変更

- **CLI フラグ消失**: `--approval-mode` / `--policy` が agy には**存在しない**。現存フラグは `--add-dir` / `--sandbox` / `--dangerously-skip-permissions` / `--print` / `--prompt-interactive` のみ
- **設定パス**: `~/.gemini/antigravity-cli/settings.json`（互換ディレクトリ）
- **トップレベルキー**: `colorScheme` / `enableTelemetry` / `trustedWorkspaces` を確認。**`permissions.deny` 相当の glob deny スキーマは未確認**
- **MCP**: `url` フィールドが `serverUrl` に rename（破壊的）
- **Plugin import**: `agy plugin import gemini` で旧拡張を変換可能

### 講座運用での当面の方針（v1.3.0）

1. **Gemini CLI 利用者は引き続き `launch-gemini-safe.{sh,ps1}` を使う**（廃止期限 2026-06-18 まで）
2. **agy 利用者は `launch-agy-safe.{sh,ps1}` を使う**（v1.3.0 で新規追加）
3. 受講者が agy / Gemini CLI のどちらを入れていても、本パッケージの launcher 経由なら最低限の防御が効く
4. agy 起動後は `/settings` UI を開いて `configs/agy/recommended-settings.json` の値に揃えるよう案内
5. 2026-06-18 以降は Gemini CLI launcher を段階的に deprecate（v1.3.x で削除予定）

## OS

## OS

| OS | 確認済み | 備考 |
|---|---|---|
| macOS Sonoma 14.x | ✅ | doctor 10/10 PASS |
| Windows 10 21H2+ | 講師PC検証予定 | PowerShell 5.1 |
| Windows 11 | 講師PC検証予定 | PowerShell 5.1 / 7.x 両対応 |

## アップデートとの付き合い方

上記より新しいバージョンの CLI が出た場合：

1. `update-safety` スクリプトを実行
2. `doctor` を再実行
3. fail があれば、講師に連絡

仕様が大きく変わった場合は、本パッケージの新バージョンを待ってください。

## 配布物 SHA-256 ハッシュ一覧（H6: 配布物改ざん検知）

`install.sh` / `install.ps1` 起動時、以下のファイルの SHA-256 を本表と照合する。
mismatch が出た場合、配布 URL すり替えや手動改変・破損の可能性があるため、
**既定でインストールを中止する**（何もコピーする前に exit 非0＝破損配布を弾く。2026-07 B1）。
講師が意図的に policy 等をカスタマイズする運用では、本表のハッシュを更新するか、
環境変数 `AI_SAFE_ALLOW_HASH_MISMATCH=1` を設定したときのみ警告付きで続行できる。

講師は新リリース時にこの表を更新すること。値は `shasum -a 256 <file>`（macOS）
または `Get-FileHash -Algorithm SHA256 <file>`（Windows）で算出する。

> ⚠️ **節の順序を入れ替えないこと。** installer は同じファイルの行が複数あっても
> **最初に見つかった 1 行しか見ない**（first-match）。そのため**現行版の節を必ず最上位に
> 置く**必要がある。古い版の節が上に来ると installer が過去のハッシュを引き、
> 全ファイルが不一致になって誰も導入できなくなる。
> この並び順は `scripts/release-version-check.sh` が検査しているので、
> 崩すとリリース前チェックが FAIL する。

### v1.0.x（過去履歴）

> これらは v1.0.x 時点のハッシュです。現行バージョンとは一致しません。参照のみ。
> install スクリプトはこのセクションを読みません（引用ブロック化により grep 対象外）。
>
> | ファイル (v1.0.x) | SHA-256 |
> |---------|---------|
> | [v1.0.x] policy/safety-policy.json | 6d4b9b3a2f7f37572d63f0a3c877b02072b38d91056234d3655a48935c1d73d5 |
> | [v1.0.x] configs/codex/hooks.mac.json | 6f03deee71871c40dd81d098867a4860284700f98135fbb05730936738a729ca |
> | [v1.0.x] configs/codex/hooks.windows.json | 9e7292426dd844ebe4d6ffa20f92f2283e9c1f6e704412bb1321117d4eb62d6a |
> | [v1.0.x] configs/claude/settings.mac.json | 03c7d38c28529afc4866ed500254ca8178426ae16f065b5248d662d7a156231f |
> | [v1.0.x] configs/claude/settings.windows.json | 460045ffb8d55636e98c529647fba93ea3bcd970a36b05af9bf673ee3f479444 |
> | [v1.0.x] configs/gemini/settings.mac.json | b9f45bac5583930c6b44a07a2351c6bd21722503de82983e63cd5f38db2a6213 |
> | [v1.0.x] configs/gemini/settings.windows.json | f061d04699ce366887ae829d0f6fd78ac8d597c9bbaac80bb985332f32d1f012 |
> | [v1.0.x] configs/codex/config.mac.toml | 0261597fa7cc1b4ba057d40e0b8dd05a0da0234e308efa42fcfb952d79d1b295 |
> | [v1.0.x] configs/codex/config.windows.toml | 6deb434337bb80bc4d0ed97c4b430ff844599bca27b90f1fc90310cce0340e00 |
> | [v1.0.x] configs/gemini/policies/safety.toml | d63830fc7548c9987a1d84b7ec0212b6527f639a6af808ee29d00427ceb87f3c |
> | [v1.0.x] workspace-template/aiexclude.template | 9fee69aa1fa5dc7253ebb1419bc1f28b4ca24c8c794f5c6fcc011a1c4a2e444b |

### v1.14.1（現行HEAD、OpenCode承認モニター連携＋OpenCode日本語ハーネス）

> 実測日: 2026-07-26。OpenCode 1.18.4 + ローカル擬似OpenAI互換Providerで実測。
> `permission.asked` をBouncerへ表示し、非対話モードの `reject` を監査ログへ反映。
> 承認対象コマンドは実行されず、プラグインready・承認要求・回答の一連を確認。
> OpenCodeの複合読み取りコマンドを、検索対象・検索語・件数制限・変更有無・外部送信有無まで固定ルールで説明。右パネルから全コマンドと意味を再展開できることを1580×1100の実ブラウザ表示で確認。
> Geminiの `finishReason=MAX_TOKENS` は未完成回答として破棄し、出力上限を4096へ拡大。Nodeテスト118件が全件成功。
> d-claudeをMac / Windows統合ランチャーの正式な選択肢へ追加。`AI_SAFE_AGENT=d-claude` としてモニターを起動し、送信検査Gateway必須表示、Claude安全フック経由、Mac dry-runを確認。

> 実測日: 2026-07-28（配布検証まわり）。実行環境: macOS (Darwin 25.5.0) / PowerShell 7.6.2 / Node.js 同梱テストランナー。
> 配布ハッシュ検証を fail-closed 化。(1) 本表 `docs/tested_versions.md` 自体が無いときは検証を丸ごと飛ばさず install を中止する。(2) AI に読ませる指示書のうち `workspace-template/opencode-harness/` と `dist-opencode/` 配下は `.md` を再帰的に列挙し、ハッシュ行が無いファイルが 1 つでもあれば中止する。`dist-skills/` は再帰列挙ではなく、既知の `hearing-ladder/SKILL.md` 1 本だけを同じ fail-closed 検査にかける（＝`dist-skills/` に未登録のファイルを置いても install は止まらない。2026-07-28 レビュー 3 巡目 YELLOW-N1 の既知の限界として残している）。それ以外の一般ファイルは従来どおり警告のみで続行（受講者の導入は止めない）。講師向けの明示 override は `AI_SAFE_ALLOW_HASH_MISMATCH=1` と `AI_SAFE_ALLOW_UNLISTED_HARNESS=1`。
> Windows 版 `scripts/windows/install.ps1` は本表を `-Encoding UTF8` で読むよう修正。本表は BOM なし UTF-8 のため、未指定だと Windows PowerShell 5.1 が既定 ANSI（日本語環境では CP932）として復号し、日本語名のコマンドファイル 5 本が一覧照合もハッシュ照合も素通りしていた。pwsh で「同じ表を ANSI 読みすると日本語行が 0 行・UTF8 読みなら 1 行」「`-Encoding UTF8` だけを ANSI に差し替えた影武者関数は同じ改ざんを見逃す」ことを実測。
> `scripts/release-version-check.sh` に (a) 本表と `policy/safety-policy.json` のハッシュ照合 (b) 決定的 deny の規則本数の下限検査 を追加。`dangerousCommandRegex` を 20 本から 1 本に削ると RESULT: FAIL になることを実測（従来は PASS だった）。実バイト検査には `.bat` / `.cmd` の CP932 復号確認を追加し、OK=141 / FAIL=0。
> mac の Bouncer 起動スクリプト `bouncer-gateway/scripts/run-local.zsh` を Windows 版と同じ判定（running / stopped / unknown）にそろえ、判定不能・空出力は日本語メッセージで中止するよう修正。偽の `lms` を使った実走 9 ケースで確認。
> 実バイト検査の CRLF 判定を厳密化。CR と LF の個数一致だけでは、行の途中に紛れた CR と CR の付かない LF が相殺して素通りするため（例: `a<CR><LF>b<CR>c<LF>`）、「LF で区切って CR で終わる行の数＝CRLF の個数」も一致することまで見るようにした。相殺ケースを実際に作って検出することを確認済み。
> 検査自体が空振りしていないかの点検も実施。`release-version-check.sh` の各検査を 1 つずつ壊して（.ps1 の BOM 除去 / .bat の LF 化 / 行頭 chcp 65001 / .bat の UTF-8 化 / 表のハッシュ書き換え / 表の削除）**6 件すべてが FAIL として検出され、復元すると PASS に戻る**ことを実測した。PowerShell 側のテストは「中止したこと」だけでなく「中止の理由」まで照合するようにし、期待文言をわざと外すとテストが落ちることも確認した。
> テスト件数: `node --test scripts/common/test/*.test.js scripts/common/test/*.test.mjs` = 256 件すべて成功（2026-07-29 実測。レビュー 3 巡目の修正で 248 → 256。増えた 8 件は `>&` 形のリダイレクト・記述子の複製が誤検知にならないこと・宛先の部分クォート／エスケープ・Windows 形式パス・grep 出力の CRLF・解釈できない形式を伏せること・空白入りパス・一致 0 件の回帰テスト）。mac シェルテスト 10 本すべて成功（`onboarding.test.sh` は ALL PASS に復帰、新規 `install-hash-guard.test.sh` 7 件、新規 `run-local-zsh.test.sh` 9 件）。pwsh テスト 8 本中 7 本成功（新規 `install-hash.test.ps1` 11 件成功。`auto-mode.test.ps1` の 24 pass / 14 fail は mac 上で実行したときの既知差）。`scripts/release-version-check.sh` は RESULT: PASS（実バイト検査 OK=141 / FAIL=0）。

| ファイル | SHA-256 | 備考 |
|---------|---------|------|
| policy/safety-policy.json | eae761dd737ad59ba9b48f491c8f340ffd7435d2c716b2b6c9530acb2b44d15f | 2026-07-28 (中核ガード最終): `protectedPathRegex` の境界を `(^|[^A-Za-z0-9._-])` へ拡張し、引用符が直前に来る形も捕捉。**現物（このハッシュの中身）の規則本数は dangerousCommandRegex 21 / protectedPathRegex 16 / redirectProtectedPathRegex 11 / secretRegex 9**。以下の履歴に出てくる `redirectProtectedPathRegex` 7 本は、レビュー 3 巡目で 11 本へ拡張する前の値。旧 hash=7f11c54a…。 2026-07-28 (レビュー3巡目・redirectProtectedPathRegex を 7→11 本に拡張。Windows の PowerShell プロファイルとスタートアップフォルダを保護対象に追加。旧 hash=9017ce71…) / (レビュー2巡目・カンマ区切り複合指定に対応。`chmod a+x,o+w` のように危険な指定が2番目以降にある形を捕捉。旧 hash=8cf8c321…) / (レビュー1巡目・中核ガード確定版): 決定的 deny 床の拡充にともなう最終版。`dangerousCommandRegex` は 21 本（`icacls` を追加）、`protectedPathRegex` 16 本、`redirectProtectedPathRegex` 7 本、`secretRegex` 9 本。旧 hash=05c8b768…。 同日の中間状態: `protectedPathRegex` に `.ai-safety` を追加、書き込み先専用の `redirectProtectedPathRegex` を新設、`chmod` の 777 指定を `-R` / `a+rwx` 形まで捕捉。旧 hash=fcd9fcd5…。このハッシュは install（両OS）と scripts/release-version-check.sh の両方が照合するため、ポリシーを変えたら必ずここも更新すること。 v1.14.1でpackageVersionを更新。旧hash=81dd4925…。2026-07-07 (C): `testedClaudeCodeVersion` キー (=2.1.201) を追加。Claude Code 動作確認済み版の SSOT。install が本ハッシュと照合するため更新必須。旧 hash=2276db83…（内容は下記 v1.12.1 の deny floor と同一）。v1.12.1 deny floor 網羅性修正（レビュー RED-A/B ＋ Codex 追補対応）: `cat${IFS}.env`・`.envrc`・`-execdir rm`・PowerShell alias(`del -Recurse`/`ls -r\|rm`)・`rd/s`・`diskutil eraseDisk`/`Remove-Partition`・`--output`系2段DL も追加捕捉。旧 v1.12.1 中間 hash=a932cb93…。 再帰削除を長オプション前置(`rm --force -r`)・split flags・`find -delete`/`-exec rm`・PowerShell 省略形(`-rec`/`-re`)・`gci -r \| rm` まで捕捉／`.env` 読取を head/tail/grep/sed/awk/cp/strings 等に拡大＋引用符・`@`前置・pathlib・curl 流出も捕捉／`format` を drive/slash 必須化し `git format-patch` 過剰ブロック解消＋`Clear-Disk`/`Format-Volume` 追加／`dd of="/dev/"` 引用符・backtick `\`curl\``・2段DL実行・空白 fork bomb・`pnpm/yarn/npm --workspace publish` を追加／`del /q` 単独の過剰ブロック撤廃。mac grep・.NET -match 両エンジンで 83 ケース(BLOCK 57/PASS 26)一致・本物 guard-bash 実機立証。packageVersion 1.12.1。旧 v1.12.0 hash=8acb93c5… |
| configs/codex/hooks.mac.json | 6f03deee71871c40dd81d098867a4860284700f98135fbb05730936738a729ca | v1.0.x から変更なし |
| configs/codex/hooks.windows.json | 4e55cf8fbffbe44f1023455c902934f00d4a81d2637ba54c495cfaded18ca97c | v1.7.2 で Codex 二重包み対策に -File 形式へ変更 |
| configs/claude/settings.mac.json | 892644e1038b6484f2f6c372b7129291b7322eafddb5052cb17a2f1b2669fb27 | 2026-07-28: `.ai-safety` 配下の Read / Write / Edit を deny に追加（安全パッケージ自身の書き換えを Claude Code 経路でも止める）。旧 hash=accffeaa…。 v1.12.0 教室プロファイル: defaultMode acceptEdits + allow 大幅拡大（読取/ビルド/install/git 定型/curl/wget）+ ask（git push/reset/checkout/rebase/sudo）。hooks は不変。初回体験修正で allow に低ストレス系 sed/awk/tar/unzip を追加（deny/ask は不変）。※`make*` はレシピ内で任意コマンドを hook 不可視に実行しうるため allow から除外し ask 層に戻した（Codex 指摘）。旧 hash=ac3a7b72…/76cfddc8… |
| configs/claude/settings.windows.json | 916a62db46c8361faf4731a3ca40e24906edc2d8e852a540037c94b3c3d613a0 | 2026-07-28: 同上（`.ai-safety` 配下の Read / Write / Edit を deny に追加）。旧 hash=83ead913…。 v1.12.0 教室プロファイル: 同上（PowerShell 系 allow 込み）。hooks は不変。初回体験修正で allow に低ストレス系 sed/awk/tar/unzip を追加（deny/ask は不変）。※`make*` は同上の理由で除外。旧 hash=39bc6b63…/64d653fe… |
| configs/gemini/settings.mac.json | b9f45bac5583930c6b44a07a2351c6bd21722503de82983e63cd5f38db2a6213 | v1.0.x から変更なし |
| configs/gemini/settings.windows.json | f061d04699ce366887ae829d0f6fd78ac8d597c9bbaac80bb985332f32d1f012 | v1.0.x から変更なし |
| configs/codex/config.mac.toml | 19503171cbcf7a3e828a523a73a3824ef7d620d9f802de684ff1ca7404eff23d | v1.12.0 教室プロファイル: approval_policy on-request + approvals_reviewer auto_review + network_access true |
| configs/codex/safe.config.toml | c96b62c2f748edb87a2aeb87b95f9f2ccedb2733c2fa78c5a19d36c5f93b857a | v1.12.0 教室プロファイル: on-request + auto_review + network_access true（config.*.toml と同期） |
| configs/codex/config.windows.toml | a29d775b798716fa523703831e146eed883e56ba8f8306a4fe2c524c18bc170c | v1.12.0 教室プロファイル: approval_policy on-request + approvals_reviewer auto_review + network_access true |
| configs/gemini/policies/safety.toml | d63830fc7548c9987a1d84b7ec0212b6527f639a6af808ee29d00427ceb87f3c | v1.0.x から変更なし |
| workspace-template/aiexclude.template | 9fee69aa1fa5dc7253ebb1419bc1f28b4ca24c8c794f5c6fcc011a1c4a2e444b | v1.0.x から変更なし |
| workspace-template/dist-skills/hearing-ladder/SKILL.md | daa3f5261db91d2eac54952b82112727f96f2ecae7f0198ea96161bd1848332f | 2026-07-06 追加: やさしい階段型ヒアリング(壁打ち)スキル。install が $workspace/.claude/skills/ へ配置し d-claude/claude が読む。Claude に読ませる prompt=実質コード相当のため配布ハッシュ検証対象に含める。2026-07-28 改訂: 階段の運用ルール・選択肢の作り方・詰まったときの逃がし方・輪テンプレ4種を追補。2026-07-28 配置先追加: install が `$workspace/.ai-safety/dist-skills/` にも同じものを置き、OpenCode 統合ランチャーが起動ごとに `$XDG_CONFIG_HOME/opencode/skills/<名前>/` へ配置する（OPENCODE_DISABLE_PROJECT_CONFIG=1 下では `.opencode/skills` は読まれないため）。 |
| workspace-template/opencode-harness/AGENTS.md | 08c562b40feede61632b45db4e8cdaa883bcaac7fa6824577bc0f61e3cb74481 | 2026-07-28 追加: OpenCode 用の日本語ハーネス本体。install が `workspace-template/opencode-harness/` 配下の `*.md` を再帰的にハッシュ検証して `$workspace/.ai-safety/opencode-harness/` へ配置し、起動時にランチャーが `$XDG_CONFIG_HOME/opencode/` へ毎回コピーする（OPENCODE_DISABLE_PROJECT_CONFIG=1 下では作業フォルダ側の指示書が届かないため）。モデルに読ませる指示書=実質コード相当のため検証対象。**この 7 ファイルは文面を 1 文字でも直したらハッシュ更新必須**（不一致で install が中止する）。更新は `find workspace-template/opencode-harness -type f -name '*.md' \| sort \| while read -r f; do echo "\| $f \| $(shasum -a 256 "$f" \| awk '{print $1}') \|"; done` で再生成する。 |
| workspace-template/opencode-harness/agents/sensei.md | d2e0b1f073dea1d7e6bbd7dfe42be68b72c79e8e0047f791de29d510f3c35cff | **`agents/*.md` の frontmatter 3 原則（追加・改訂時は必ず守る）**: (1) bash/edit/write は `permission:` ではなく **`tools:` で false** にする（`permission:` で書くと解決済み設定が `bash: {"*":"deny"}` になり、起動前の権限自己検証がエージェントによる上書きとみなして起動拒否する）。(2) **`tools:` に `question: true` の明示が必須**（Markdown で定義したエージェントは question ツールが既定 false になり、明示しないと選択肢での聞き返しができず自由記述に落ちる。組み込みの build/plan と設定 JSON 内で定義したbouncer は既定 true）。(3) **`read: true` と `grep: true` は書かないこと** — エージェント個別 permission は共通ルールの後ろに連結され最後に一致した行が勝つため、`read: true` と書くと共通側の `.env` 禁止がこのエージェントだけ外れる（実測: せんせいで `.env` の中身がモデルに渡った）。2026-07-28 (3) の穴を塞ぐため `read: true` の 1 行を削除してハッシュ更新。旧 hash=1d3f3a54…。 2026-07-28 追加: 読み取り専用「せんせい」エージェント。frontmatter は `tools:` で bash/edit/write を false にすること（`permission:` で書くと解決済み設定が `bash: {"*":"deny"}` になり、起動前の権限自己検証がエージェントによる上書きとみなして起動拒否する）。また **`tools:` に `question: true` の明示が必須**（Markdown で定義したエージェントは question ツールが既定 false になり、明示しないと選択肢での聞き返しができず自由記述に落ちる。組み込みの build/plan と設定 JSON 内で定義した bouncer は既定 true）。今後 `agents/*.md` を追加するときも同じ明示が必要。 |
| workspace-template/opencode-harness/commands/あんぜん.md | 8e4985be88cf1487f3066d8a4e784ef8849f4da3d5b03bd5d1299f2bb10539d2 | 2026-07-28 追加: 日本語スラッシュコマンド。1.18.4 は `{command,commands}/**/*.md` を読む（単数・複数どちらでも可）。**コマンド本文に `` !`コマンド` `` を書いてはいけない**: テンプレート展開時に受講者のシェルへ直接渡されて実行され、permission の確認も承認モニターの決定的 deny 床も通らない（バイナリ内 `/!\`([^\`]+)\`/g` → shell 実行を実測）。ランチャーが起動前に**配置後の実ファイル**を検査し、1 つでもあれば起動を中止する。 |
| workspace-template/opencode-harness/commands/しらべて.md | 0f79ac7049fb9f437824c93f07313e7467d884bf22f08b426304fe3ad6aa4e87 | 2026-07-28 追加: 同上 |
| workspace-template/opencode-harness/commands/せつめい.md | 7173cac59c65af404fc8b91500ab5c7c07aa628894007c931dfb02160f2c20aa | 2026-07-28 追加: 同上 |
| workspace-template/opencode-harness/commands/そうだん.md | 1b417f451d820c8e44bc1c64e7709d162c9a25d85b8ceb48748a023ab25aef38 | 2026-07-28 追加: 同上 |
| workspace-template/opencode-harness/commands/なおして.md | 66256c904c24dac63ca96672ca1aa0b74992011c7df74df46cd0f8d4e945aa12 | 2026-07-28 追加: 同上 |

### v1.14.0（Bouncer統合版、Version SSOT 統一 + release-version-check.sh 新規）

> 実測日: 2026-05-28。`shasum -a 256 <file>` (macOS) で計測。
> v1.13.0 からの変更: Bouncer/OpenCode統合に伴い packageVersion を 1.14.0 に bump。
> 全 active docs / installer / workspace-template の version 表記を v1.14.0 に統一。
> `scripts/release-version-check.sh` 新規作成（SSOT drift 検出スクリプト）。
> 個別ファイルの SHA-256 一覧は、現行版である上の v1.14.1 節の表に集約した（v1.14.0 時点の値は git 履歴を参照）。

### v1.4.3（BOM 二重 hotfix）

> 実測日: 2026-05-28。`shasum -a 256 <file>` (macOS) で計測。
> v1.4.2 の追加致命バグ (doctor.ps1 / launch-claude-safe.ps1 に BOM が二重に入っており PS 5.1 起動不能) を緊急 hotfix。v1.4.2 の Release は未公開のままスキップし、v1.4.3 を正規リリースとする。

| ファイル | SHA-256 | 備考 |
|---------|---------|------|
| policy/safety-policy.json | 92a525342e5bb79e6138f47f8e5189c8bdc6a76bb7d2953d716bc9696abc737a | v1.4.3 で packageVersion を 1.4.3 に bump |
| configs/codex/hooks.mac.json | 6f03deee71871c40dd81d098867a4860284700f98135fbb05730936738a729ca | v1.0.x から変更なし |
| configs/codex/hooks.windows.json | 4e55cf8fbffbe44f1023455c902934f00d4a81d2637ba54c495cfaded18ca97c | v1.7.2 で Codex 二重包み対策に -File 形式へ変更 |
| configs/claude/settings.mac.json | 38b720bbe14be938574c7411913ad7c01313bfb4c8ebefd02d0f5d8d6b4740d6 | v1.4.1 で env exfil deny 追加 |
| configs/claude/settings.windows.json | 2886773553d02d868cb01501a1ce3683891bea2dc88e803654f4d8c24dc79661 | v1.4.1 で env exfil deny 追加 |
| configs/gemini/settings.mac.json | b9f45bac5583930c6b44a07a2351c6bd21722503de82983e63cd5f38db2a6213 | v1.0.x から変更なし |
| configs/gemini/settings.windows.json | f061d04699ce366887ae829d0f6fd78ac8d597c9bbaac80bb985332f32d1f012 | v1.0.x から変更なし |
| configs/codex/config.mac.toml | ba8c3ec6603ae2812918683a8f46c828a79cc432f22323ea9c218672aa029791 | v1.4.1 で `features.hooks=true` 修正 |
| configs/codex/config.windows.toml | 005fbee210b77482cb68912610b551a124608a192992346956a57cc724388537 | v1.4.1 で `features.hooks=true` 修正 |
| configs/gemini/policies/safety.toml | d63830fc7548c9987a1d84b7ec0212b6527f639a6af808ee29d00427ceb87f3c | v1.0.x から変更なし |
| workspace-template/aiexclude.template | 9fee69aa1fa5dc7253ebb1419bc1f28b4ca24c8c794f5c6fcc011a1c4a2e444b | v1.0.x から変更なし |

## v1.1.0 配布 zip 全体

| ファイル | SHA-256 |
|---------|---------|
| ai-agent-safety-package-v1.1.0.zip | d906e3f025f95d7cf9fc1e9066eb1bcdef088bd561fd07947fd002a88b0299bf |

このハッシュは配布元と受講者で一致することを確認してください:
`shasum -a 256 ai-agent-safety-package-v1.1.0.zip` (mac) / `Get-FileHash ai-agent-safety-package-v1.1.0.zip` (win)

## v1.2.0 配布 zip 全体

v1.2.0 では agent-monitor（承認時の解説カードと監視ビューア）を追加。
個別ファイル（policy/safety-policy.json 等）の SHA-256 は v1.1.0 から変更なし。
新規ファイル群（`configs/safety/cards/`, `scripts/{macos,windows}/monitor.{sh,ps1}`,
`scripts/{macos,windows}/lib/{explainer.sh,Explainer.ps1}`）はパッケージ zip 全体
のハッシュで検証する。

| ファイル | SHA-256 |
|---------|---------|
| ai-agent-safety-package-v1.2.0.zip | b7e5417d372c2ed4c60b12ed5c8603ea17b08bcdb68976ae24756eaaf3fb8281 |

このハッシュは配布元と受講者で一致することを確認してください:
`shasum -a 256 ai-agent-safety-package-v1.2.0.zip` (mac) / `Get-FileHash ai-agent-safety-package-v1.2.0.zip` (win)

## バックアップ整合性検証（H7: zip-slip / 改ざん）

`backup.sh` / `backup.ps1` は zip 作成時に同名の `.sha256` ファイルを出力する。
`restore.sh` / `restore.ps1` は復元前に以下を検証する。

1. **ハッシュ照合**: `<zip>.sha256` が存在すれば zip の SHA-256 と照合し、不一致なら exit 1
2. **zip-slip 検知**: エントリ名に `../` を含む場合、悪意あるアーカイブとして exit 1
3. 上記が通った場合のみ展開

`.sha256` ファイルが無い場合（旧バックアップ等）はハッシュ照合をスキップするが、
zip-slip 検知は常に実行する。
