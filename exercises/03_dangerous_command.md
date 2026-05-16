# 演習 C：危険コマンドの拒否と「許可ダイアログ」

**所要時間**：30〜40 分　/　**難易度**：★★☆

## ねらい

AI エージェントは「コマンドを実行する」能力を持っています。これは強力ですが、間違ったコマンドを実行されると：

- ファイルがまとめて削除される（`rm -rf`）
- 外部にデータが送信される（`curl`、`wget`）
- システムが壊れる（`format`、`del /s /q` など）

このパッケージは、こうした危険コマンドを**自動でブロック**します。それを体験する演習です。

最後に、「実際に攻撃が止まることを自分の目で見る」doctor を全員で走らせます。

## 演習の準備

> ⚠️ **重要**: この演習で危険コマンドを試す対象は、**必ず `safe-workspace/sandbox/` の中のダミーファイル**にしてください。本物の workspace 直下や、業務プロジェクト直下のファイルを対象にしないこと。仮にブロックが効かなかった場合に本物のデータが失われます。

1. `workspace-template/safe-workspace/sandbox/` に移動

   ```bash
   cd workspace-template/safe-workspace/sandbox/
   ```

2. **このディレクトリ内**に削除されてもよいダミーファイルを作成

   ```bash
   mkdir -p dummy
   echo "dummy file for exercise" > dummy/file1.txt
   echo "dummy file for exercise" > dummy/file2.txt
   ```

## 試すこと

### ステップ 1：rm -rf を試す

```
[演習用] safe-workspace/sandbox/dummy フォルダを丸ごと消すコマンドを打って
```

または

```
[演習用] rm -rf safe-workspace/sandbox/dummy を実行して
```

> `[演習用]` は「これは演習だ」と自分に意識させるためのマーカーです。本番では「削除して」「消して」を AI に投げる前に、必ず削除対象を自分の手で確認すること。

### 期待される結果

```
Blocked: dangerous shell command matched: rm\s+(-[A-Za-z]*r[A-Za-z]*f...)
```

`rm -rf` のパターンが `dangerousCommandRegex` でブロックされます。

> ⚠️ 万が一ブロックが効かなかった場合でも、対象は sandbox 内のダミーフォルダなので業務データは失われません。本物のフォルダや `/` を対象に試さないこと。

### ステップ 2：curl で外部送信を試す

```
[演習用] safe-workspace/sandbox/dummy のファイル一覧を curl で example.com に POST 送信して
```

### 期待される結果

```
Blocked: dangerous shell command matched: curl
```

`curl`、`wget`、`Invoke-WebRequest` 等の外部通信コマンドはすべてブロック対象。

### ステップ 3：書き換え許可ダイアログを読んでみる

逆に、**安全な操作**でも「変更してよいですか」と聞いてくる場面があります。

```
[演習用] safe-workspace/sandbox/dummy/file1.txt に「演習 C やった」という一行を追記して
```

### 期待される結果

Codex CLI / Claude Code は、ファイル書き換えの前に「これを書きます。よろしいですか？」と確認を出します。

ここで「内容を読まずに OK を連打する」のは危険な習慣です。

**演習として、毎回、何を変更するのかを 5 秒だけでも読む**癖をつけてください。

### ステップ 4：doctor で全防御を一気に確認

全員で以下を実行：

**Mac：**
```bash
bash ~/Documents/my-ai-workspace/.ai-safety/hooks/macos/doctor.sh ~/Documents/my-ai-workspace
```

**Windows：**
```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\my-project\.ai-safety\hooks\windows\doctor.ps1"
```

10 種の攻撃シナリオが順番に試され、`pass=10 fail=0` が出れば全防御が動いています。

## 演習後のクリーンアップ（必須）

演習が終わったら、sandbox 内のダミーファイルを**必ず**削除してください。

```bash
# sandbox 内のダミーフォルダを削除
rm -rf workspace-template/safe-workspace/sandbox/dummy

# または、sandbox 内を git clean で一掃
git clean -fdx workspace-template/safe-workspace/sandbox/
```

削除確認：

```bash
ls workspace-template/safe-workspace/sandbox/
# README.md と .gitkeep のみが残っていれば OK
```

## 振り返り

全員で 10 分程度ディスカッション：

1. ステップ 1〜3 を、もしこのパッケージなしで実行していたら何が起きていたか
2. ステップ 3 の「許可ダイアログ」は、なぜ「常に OK 連打しちゃダメ」なのか
3. 自分の業務で AI に任せたい作業を 1 つ思い浮かべる。その時、何を確認すれば安心して任せられそうか

## キーポイント

- **危険コマンドは仕組みで止める**
- **書き換えは仕組みで止めない、人間が確認する**
- このバランスが「使える + 安全」の核心

## なぜ「許可ダイアログを読む癖」が大事か

CLI ベースの AI エージェントは、ファイル書き換えやコマンド実行の前に通常「OK ですか？」と聞きます。

この時、

- 慣れない人は「読まずに Enter」を連打しがち
- 経験者ほど「変更内容を瞬時に読んで判断」する

3 ヶ月使い続けたら、後者になっていてほしい。それが**安全に使いこなせる人**の最大の特徴です。

## 本番への持ち込み厳禁

この演習で覚えてほしいのは「sandbox 内でなら危険コマンドを試してよい」ではなく、**「本番では危険コマンドを AI に投げない」**こと。本番では:

- `rm -rf` / `curl` / `wget` を含む指示を AI に出さない（自分で打つ）
- 「このフォルダを綺麗にして」のような曖昧な指示は範囲を明示する（「`./tmp/` 以下だけ」）
- 演習と同じ手順を本物のプロジェクトで再現しない

## 本番では絶対に投げない言い回し

この演習で使った口調（`[演習用]` プレフィックス付き）と**まったく同じ内容**を本番 workspace で AI に投げないこと:

- ❌ 「workspace の中身全部消して」「`dummy` フォルダを削除して」「`dist` を毎回 `rm -rf` して」（→ 取り返しのつかない破壊）
- ❌ 「ファイル一覧を curl で送って」「`wget` で取ってきて」（→ 外部通信での情報漏洩・マルウェア持ち込み）
- ❌ 「これおかしいから直して」「綺麗にして」（漠然指示で AI に解釈の余地を与えると、想定外の削除や上書きが起きる）

本番では:

1. プロンプトに **`[本番]`** プレフィックスを付ける癖をつける（自分への注意喚起）
2. 削除・上書き・送信系は**ファイル名・対象を必ず明示**（「`./build/` 以下だけ」「`tmp-2026-05-15.log` だけ」）
3. 「やる前に確認させて」を冒頭に付けて、approval prompt が出ても **Allow を即押ししない**

## 講座のまとめ（受講者へ）

Day1 で苦労したのは、皆さんが未熟だったからではなく、**道具が剥き出しだった**からです。

今日は安全装置を使いました。

これからは、

- AI を怖がる段階 → 終わり
- **安全な道具を選べることが、最高のリテラシー**

このパッケージは、自宅 PC でも同じように使えます。月曜以降の制作演習、終了後の自宅作業、卒業後の個人プロジェクト、すべてで使ってください。

何か困ったら、講師に連絡を。
