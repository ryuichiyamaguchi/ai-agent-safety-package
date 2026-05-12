# 既知の問題

v1.0 時点で把握している既知の問題と回避策。

## Windows

### `doctor.ps1` 起動時に PowerShell の実行ポリシー警告

回避：`-ExecutionPolicy Bypass` を付ける。

```
powershell -ExecutionPolicy Bypass -File <スクリプトパス>
```

### Codex CLI の Windows サンドボックスが効かない

`codex sandbox windows` が `elevated`（Admin 必要）モードでしか強力に動かないケース。`unelevated` は弱い。

→ hook 層で同等の防御を行うため、サンドボックス単独で守られない場合も hook で塞がる。`doctor` で確認可能。

### Windows Defender SmartScreen の警告

未署名 `.ps1` / `.cmd` をダウンロード元タグ付きで実行しようとすると警告が出ることがある。

回避：
1. ZIP をプロパティから「ブロック解除」する
2. または「詳細情報 → 実行」で初回のみ許可
3. 講師 PC で事前に動作確認した版を配布する

### ZIP 解凍で日本語ファイル名が文字化け

回避：Windows 標準の「すべて展開」を使う。Lhaplus 等の古いツールは UTF-8 ZIP を扱えないことがある。

このパッケージはファイル名をすべて ASCII にしているので、内容上の文字化けは発生しないはず。

## macOS

### `.command` ファイルが「開発元が未確認」で開けない

回避：
1. Finder で `.command` を右クリック →「開く」を選択
2. 警告ダイアログで「開く」をクリック
3. 一度許可すれば、次回からは普通に動く

### ZIP 解凍で実行権限が落ちる

回避：

```bash
chmod +x ~/Downloads/ai-agent-safety-package-v1/scripts/macos/*.sh
chmod +x ~/Downloads/ai-agent-safety-package-v1/scripts/macos/lib/*.sh
```

または、install スクリプトを `bash` で明示的に起動する。

```bash
bash scripts/macos/install.sh ~/Documents/my-ai-workspace
```

### Apple Silicon Mac で Codex CLI が動かない

`codex` コマンドが `command not found` または起動失敗。

回避：Rosetta 経由で再インストール。

```bash
arch -x86_64 npm install -g @openai/codex
```

それでも動かない場合、Codex CLI を諦めて Claude Code（Mac native）または Cursor 拡張に切り替え。

### Seatbelt サンドボックスの既知バグ

特定のシンボリックリンク経由でサンドボックスを抜けるバグが報告されている。

→ hook 層で同等の防御を行うため、Seatbelt 単独で守られない場合も hook で塞がる。

## 共通

### 「fail closed」の挙動

hook スクリプトが何らかの理由（PowerShell 不在、bash 不在、policy.json 破損等）で起動できない場合、**操作は全てブロック**される設計（fail closed）。

→ 安全側に倒すための仕様。回避が必要ならスクリプトを修復してから使う。`doctor` で原因を特定できる。

### 業務プロジェクトを上書きインストールした場合

既存の `.claude/`、`.codex/`、`.gemini/` 設定は `~/.ai-safety/backups/<timestamp>/` にバックアップされる。

復旧：`restore.ps1` または `restore.sh` を使う。

### CLI メジャーアップデート後に hook が動かない

Codex / Claude / Gemini CLI が hook の仕様を変更した場合に発生する可能性。

回避：`update-safety.ps1` / `update-safety.sh` を実行して、互換性チェック付きで再インストール。

それでも直らない場合、講師に連絡（CLI バージョン情報を `collect-status` で添付）。

## レポートしたい問題があれば

- GitHub Issues（リポジトリの Issues ページ）
- または講師の連絡先まで

具体的な再現手順、エラーメッセージ、`collect-status` の出力ファイルを添えると修正が早いです。
