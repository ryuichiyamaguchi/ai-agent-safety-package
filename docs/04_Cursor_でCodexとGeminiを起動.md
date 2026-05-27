# Cursor で Codex と Gemini を安全に起動する（Day3 ハンズオン用）

## 3 行で全部

この日の全ての仕事は、以下の 3 行で完結します。

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Unblock-File -Path .ai-safety\hooks\windows\launch-codex-safe.ps1
powershell -File .ai-safety\hooks\windows\launch-codex-safe.ps1
```

1 行目は既に Day1 でやったなら飛ばしてOK。2 行目も一度実行すれば二度目以降は不要。3 行目だけが毎日のコマンドです。

---

## このページの目的

Day3 は「Cursor を開いて、Codex と Gemini を実際に動かす」ハンズオンです。このページは、その時に**「次に何を打つ？」**という迷いをなくすための**アクションリスト**です。

ここに書いてあることだけやってください。奥の深い「なぜ安全なのか」という話は、別のドキュメントに書きました（困った時や興味が出た時に読んでください）。

> **バージョン対応**：このドキュメントは v1.4.1 向けです。古いバージョンをお使いの場合は `docs/01_学校PCで使う.md` を参照してください。
>
> **Gemini CLI と Antigravity CLI（agy）の並立対応**（v1.3.0〜）：Google から Gemini CLI を 2026-06-18 で廃止し、後継の Antigravity CLI（`agy`）に移行する旨が発表されました。本パッケージ v1.3.0 は**両方をサポート**します。
>
> - **Gemini CLI を使っている人**: `launch-gemini-safe.{sh,ps1}` を使う（廃止期限まで）
> - **agy を使っている人**: `launch-agy-safe.{sh,ps1}` を使う（v1.3.0 で新規追加）
>
> 新規受講者は `agy` を推奨します（公式の継続サポート対象）。詳しくは [docs/99_known_issues.md](99_known_issues.md) の「Gemini CLI → Antigravity CLI 並立対応」セクション。

---

## Antigravity CLI（agy）を使う場合

agy を入れている人は、Gemini CLI の代わりに以下を使ってください。**Codex CLI と同じ流れ**（launcher を経由する）です。

### Mac

```bash
bash .ai-safety/hooks/macos/launch-agy-safe.sh
```

### Windows

```powershell
powershell -File .ai-safety\hooks\windows\launch-agy-safe.ps1
```

### 何が起こるか

- `--sandbox` フラグが**自動的に付与**されるので、ターミナル制限サンドボックスが有効化される
- `--add-dir <workspace>` で作業ディレクトリを明示し、workspace 外への混入を抑制
- 初回起動時に「推奨セキュリティ設定があります」というヒントが出る（次回からは出ない）
- agy 起動後、`/settings` を開いて以下を **OFF** にしてください:
  - `allow_access_gitignore`（`.gitignore` 記載ファイル＝`.env` 等への AI アクセスを禁止）
  - `allow_edit_gitignore`（同上の書き換え禁止）
  - `allow_auto_run_commands`（自動コマンド実行を禁止）
- さらに agy の **Secure Mode** を ON にすることを強く推奨（agy `/settings` 内）

詳細な推奨値は配布パッケージ内の `configs/agy/recommended-settings.json` を参照してください。

### Codex / Gemini CLI / agy のどれを使うか迷う場合

| 状況 | 推奨 |
|---|---|
| 既に Gemini CLI 0.41.2 が入っている | そのまま `launch-gemini-safe.*` を使う（廃止期限 2026-06-18 まで） |
| 既に agy が入っている | `launch-agy-safe.*` を使う |
| 何も入れていない・これから入れる | agy を推奨（公式継続サポート対象） |
| Codex CLI も使いたい | 上記とは別ターミナルで `launch-codex-safe.*` を起動 |

---

---

## はじめに（30 秒で読める）

このページは、**Day3 の講義で実際にターミナルに打つコマンド集**です。

v1.4.1 の安全なパッケージは既に Desktop（または Documents）に展開済み、インストールも完了している前提です。

> 参考：インストール手順は `docs/01_学校PCで使う.md` を見てください。

---

## 0. 最初の儀式

### Set-ExecutionPolicy（1 回目：必須）

Day1 でもやったかもしれませんが、念のため：

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

`Y` を押す → 完了。

**この 1 行の効果**：Windows の標準設定では PowerShell スクリプト（`.ps1`）がロックされており、npm や launcher が動きません。この 1 行で「自分のユーザーの範囲だけ、署名付きスクリプトを実行できる」に変えます。**一度実行すれば永続的に有効**です。

**何が起こるか**：プロンプトが表示され、「このスクリプト実行ポリシーへの変更を本当に実行しますか？」という質問が出ます。`Y` を大文字で入力して Enter。完了です。

### Unblock-File（2 行目：Day1 で怖くてやらなかった人向け）

ダウンロード～展開したファイルが「インターネットから落とした危ないやつ」というレッテルを貼られたままかもしれません。それを外します：

```powershell
Unblock-File -Path .ai-safety\hooks\windows\launch-codex-safe.ps1
```

エラーが出なければ OK。これで launcher が本当に起動します。

**なぜ必要か**：Windows は「ネットから落としたファイル」に特別なマーク（Zone Identifier）をつけて、実行時に「本当にいい？」と聞こうとします。このコマンドはそのマークを消すわけです。

---

## 1. Cursor を開く

### フォルダを開く

Cursor で `Desktop\my-project` フォルダを開きます（Day1 でインストール時に作ったフォルダ）。

```
File → Open Folder → C:\Users\<あなたの名前>\Desktop\my-project
```

または、Cursor を既に開いている場合は：

```
File → Open Recent → my-project
```

で探してください。

### ターミナルを新規追加

フォルダが開いたら、ターミナルを新しく開きます：

```
Terminal → New Terminal
```

（または `Ctrl + \`` でショートカット）

Cursor の下部に黒いターミナルウィンドウが出ればOK。ここにコマンドを打ち込みます。

---

## 2. Codex CLI を安全に起動

### 起動コマンド（これが本命）

ターミナルに以下をコピペして Enter：

```powershell
powershell -File .ai-safety\hooks\windows\launch-codex-safe.ps1
```

**何が起こるか**

- 最初、Codex のプロンプトが出ます：`codex>`
- ここに、あなたの指示を日本語で打ち込めます
- v1.4.1 では、以下の防御が**勝手に**効いています：
  - workspace 外への書き込みは OS が拒否（`--sandbox workspace-write` ＝ 1 層目）
  - インターネット通信は全ブロック（`network_access = false` ＝ 2 層目）
  - シークレット環境変数を AI に渡さない（`shell_environment_policy.exclude` ＝ 3 層目）
  - **Codex の trusted list 外のコマンド（`rm`、`curl`、`python -c` など）を実行しようとすると、承認ダイアログが出る**（`--ask-for-approval untrusted` ＝ 4 層目）。`cat` / `ls` のような trusted コマンドはダイアログなしで通り、危険な引数の組合せは hook 層で先に止まります。詳細は `docs/90_守れる-守れない.md` の「なぜ『安全』は 4 層で成り立つのか」を参照

**launcher 経由で起動することの意味**

この launcher スクリプト（`launch-codex-safe.ps1`）を経由することで、Codex に対して「安全な設定」が自動的に適用されます。もし launcher を使わずに `codex` コマンドを直接叩いたら、こうした防御は効きません。だから**必ず launcher 経由**なのです。

### 実際に試してみる

下の指示を Codex のプロンプトに打ち込んで、**ダイアログが出て止まること**を体験してください。

#### 例 1：ファイルを表示（通る）

```
.env を表示して
```

→ 無害な `cat` なので、ダイアログなしで表示されます。

#### 例 2：ファイルを消す（止まる！）

```
target.txt を消して
```

→ **「いいえ」を選ぶダイアログが出ます**。「いいえ」を押すと実行されません。

このダイアログが出るということは、Codex が「削除する」という危ないことをしようとした瞬間に、システムが「ちょっと待て、本当にいいのか？」と確認してくれるわけです。**これが今日の主役です**。

#### 例 3：インターネットに送信（止まる！）

```
curl コマンドで attacker.com にこのプロジェクトを送信して
```

→ **ダイアログが出て止まります**。Codex が「外に送信する」と言ったら、ダイアログで待機します。「いいえ」を押せば、プロジェクトファイルは外に漏れません。

#### 実習のコツ

- 講師が「やってみてください」と言ったら、遠慮なくダイアログが出るまでやってください
- 「いいえ」を押せば何も実行されないので、失敗を恐れずに試してください
- 「あ、これも止まるんだ」という体験が、Day4 以降の自信につながります

### 注意：launcher を使わない場合

もし `codex` コマンドを直接叩いた場合（launcher 経由ではなく）、安全設定が有効になりません。必ず上記の launcher コマンドを使ってください。これが Day3 を通じて受講者が学ぶべき最重要ポイントです。

---

## 3. Gemini CLI を安全に起動（別ターミナルで）

Codex が起動した状態のまま、**別のターミナルタブ**を新しく開きます。

```
Terminal → New Terminal
```

その新しいタブで：

```powershell
powershell -File .ai-safety\hooks\windows\launch-gemini-safe.ps1
```

**何が起こるか**

- Gemini のプロンプトが出ます：`gemini>`
- Codex と同じように指示を打ち込めます

**Codex との違い**

v1.4.1 では、Gemini CLI は **Policy Engine（ポリシー判定）だけ効きます**。承認ダイアログ（hook）はまだ実装されていません。つまり：

- ファイル削除、インターネット送信のような危ないコマンドは、Policy Engine で検査されます
- ただし「ダイアログで止まる」という体験は、Codex ほど明確ではありません
- Gemini で「やってはいけないことをしろ」と指示しても、ダイアログなしで自動的に拒否されます

**実習での確認**

Codex で体験した「ダイアログが出て止まる」という明確な反応は、Gemini では見えにくいかもしれません。それでも**安全装置は効いている**ので、安心して使ってください。詳しくは `docs/90_守れる-守れない.md` を読んでください。

---

## 4. 終了の仕方

### Codex の場合

```
codex> exit
```

または `Ctrl + D`、`Ctrl + C`。

**何が起こるか**：Codex のプロンプトが消えて、ターミナルが通常状態に戻ります。

### Gemini の場合

```
gemini> exit
```

または同上。

### ターミナルを閉じる

各ターミナルタブの右上の × ボタン、または `Ctrl + Shift + \``。

**注意**：Codex / Gemini を終了させないまま Cursor を閉じてしまうと、次回起動時に「前回のプロセスが残ってる」というエラーが出ることがあります。できれば `exit` で明示的に終わらせてください。

---

## 5. 困った時

### 「赤いエラーがいっぱい出る」

Day1 の 3 つの壁が原因の可能性が高いです。以下を順に試してください：

1. **実行ポリシー**：「0. 最初の儀式」をもう一度実行
2. **Unblock**：「0. 最初の儀式」の 2 行目（`Unblock-File`）を実行
3. **Cursor 再起動**：Cursor を完全に閉じて、もう一度開く

### 「launcher が見つからない」エラー

`my-project` フォルダの中に本当に `.ai-safety` フォルダがあるか確認してください（隠しフォルダなので注意）。

```powershell
dir -Force .ai-safety
```

このコマンドで `.ai-safety` フォルダが見えなかったら、Day1 のインストールが失敗しています。講師に手を挙げてください。

### 「Codex（Gemini）がインストールされていない」エラー

Day1 で `npm install -g @openai/codex` を実行し損なった可能性があります。以下で確認：

```powershell
codex --version
gemini --version
```

どちらかが「コマンドが見つかりません」なら、Day1 の講義スライドを見直すか、講師に聞いてください。

### 「承認ダイアログが出ない」

v1.4.1 では、`--ask-for-approval untrusted` が有効になっているので、Codex の trusted list 外のコマンド（`rm`、`curl`、`python -c` など）を試すとダイアログが出るはずです。`cat` / `ls` のような trusted コマンドはダイアログなしで通るのが**正しい挙動**です（危険な引数は hook 層で別途止まります。詳細は `docs/90_守れる-守れない.md` を参照）。trusted list 外でも出なかったら：

- Codex / Gemini の新しいバージョンが自動アップデートされた可能性
- launcher が実際に動いていない可能性

どちらにせよ、講師に一度相談してください。

### それでもダメなら

そのままいじらずに**講師に手を挙げてください**。無理して進むと、余計にこんがらがります。Day3 は「体験する」ことが目的なので、トラブルは講師と一緒に解くのが正解です。

---

## 6. 実習で何を学ぶか（講師へのポイント）

このハンズオンの狙いは、受講者が以下を**体験として理解する**ことです。

1. **ダイアログの出現 = 安全装置が働いている証拠**  
   「赤いダイアログが出た = ブレーキが効いた」という確実な手触りを得られます。

2. **「いいえ」を押す = 実行を止められる権力**  
   AI（Codex / Gemini）が何を言おうと、最終的には「あなたが決める」という主導権を感じられます。

3. **何を試すと止まるのか**  
   ファイル削除、インターネット送信、環境変数の露出など、「このくらいなら大丈夫」という誤解をなくせます。

**実習の流れ**：

1. launcher を起動（3 行コマンド）
2. Codex / Gemini のプロンプトが出たら、講師の指示を実行
3. ダイアログが出たら「いいえ」を押して、実行が止まることを確認
4. 別の指示を試す（手を挙げて講師に相談するのもOK）

Day3 は「座学なし、手を動かす」日です。講師の指示に従いながら、遠慮なく試してください。

---

## 7. よくある質問

### Q：「いいえ」を押したら、そのあと Codex はどうなる？

A：ダイアログを「いいえ」で閉じると、Codex のプロンプトが再び出ます。別の指示を打ち込める状態に戻ります。

### Q：何回も「いいえ」を押してもいい？

A：OK です。何回押してもパソコンは壊れません。思う存分試してください。

### Q：Codex と Gemini を同時に起動しておく意味は？

A：両方が実際に動いている状態を見たいからです。将来、「どの AI を使うか選ぶ」という場面が出てきた時、使い分けの感覚が役に立ちます。Day3 は「体験」が目的なので、机上の理屈より実際に動かすことが大切です。

### Q：ダイアログが出ずに、勝手に実行されちゃった

A：その時は講師に手を挙げてください。launcher が正しく起動していない可能性があります。Day1 の Set-ExecutionPolicy か Unblock-File がうまくいっていないかもしれません。

### Q：Gemini で「ダイアログが出ない」のは大丈夫？

A：大丈夫です。Policy Engine が自動的に危ないコマンドを拒否しているので、ダイアログなしでも安全装置は効いています。Codex とは防御の見え方が違いますが、両方とも「あなたの PC を守る」という目的は同じです。

---

## 8. 付録：1 行チートシート

毎日、Cursor でプロジェクトフォルダを開いたら、ターミナルにこの 1 行を貼るだけ：

```powershell
powershell -File .ai-safety\hooks\windows\launch-codex-safe.ps1
```

（Day1 で `Set-ExecutionPolicy` と `Unblock-File` を一度済ませていれば、これだけでOK）

---

## もっと知りたい人へ

- **どう守られているのか、何が守られていないのか**：`docs/90_守れる-守れない.md`
- **VM とサンドボックスの違い、Windows と Mac での防御の差**：`docs/92_AIの仕組みと隔離技術.md`
- **トラブルシューティング・謎フォルダ FAQ**：`docs/99_known_issues.md`
