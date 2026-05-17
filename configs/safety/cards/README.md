# agent-monitor 解説カード

承認プロンプトが出る瞬間に、「いま AI が何をしようとしているか」を日本語で解説するカード集です。

## 仕組み

1. AI が tool（Bash / Write / WebFetch など）を呼ぼうとする
2. ガード hook が起動し、`safety_policy.sh` の `explain()` が `index.tsv` を上から評価
3. 最初にヒットしたパターンの `<card_id>.md` を採用
4. カード本文を `~/.ai-safety/logs/now.md` に書き出す
5. 受講者は **別ターミナル** の `monitor.sh` でこの now.md を見る

## ファイル

- `index.tsv` — 索引（tool × pattern → card_id）。上から評価
- `<card_id>.md` — 個別カード本文（frontmatter で risk / icon / title）
- `default-<tool>.md` — どのパターンにもヒットしなかった時のフォールバック

## カードの書き方

```markdown
---
risk: high | medium | low
icon: ⚠️ | 🚨 | 🌐 | 🔐 | 🔑 | 💻 | 📝 | 💬 | 📤
title: 一行で「いま何をしようとしているか」
---

# このコマンドは何？
...2〜3行...

# 承認前にチェック
- ...

# 「許可しない」を選ぶべき
- ...

# パッケージの守りの状態
...
```

## カードを追加するとき

1. `<card_id>.md` を新規作成
2. `index.tsv` の **default-\* より前** に行を追加（評価順に注意）
3. `scripts/macos/monitor.sh` で表示確認

## カードを編集するとき

- frontmatter を壊さない（YAML パースが必要なので）
- `title` は 1 行で完結させる（モニターのヘッダー表示に使う）

## ライセンス

このカード本文の文体・構成は受講者教材として書かれています。改変・流用自由。
