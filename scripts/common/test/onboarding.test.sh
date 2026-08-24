#!/bin/bash
# オンボーディング入口の健全性テスト（依存ゼロ・mac 開発機で実行）。
# 検証: HTML 自己完結 / コピーボタン / OS トグル / ラッパー構文 / 相対 ws 解決。
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HTML="$ROOT/スタート.html"
START_DIR="$ROOT/workspace-template/スタート"
fail=0
note(){ echo "[onboarding-test] $1"; }

# 1) HTML 存在
[ -f "$HTML" ] || { note "FAIL: スタート.html がない"; exit 1; }

# 2) HTML 自己完結（許可リンク=nodejs.org / target=_blank / rel=noopener 以外の外部参照なし）
if grep -nE 'https?://' "$HTML" | grep -vE 'nodejs\.org|antigravity\.google|rel="noopener"|target="_blank"' >/tmp/onb_ext.txt 2>/dev/null; then
  if [ -s /tmp/onb_ext.txt ]; then note "FAIL: 外部参照あり"; cat /tmp/onb_ext.txt; fail=1; fi
fi

# 3) コピーボタン >= 6
n=$(grep -c 'onclick="copyText' "$HTML")
[ "$n" -ge 6 ] || { note "FAIL: コピーボタン数=$n (<6)"; fail=1; }

# 4) OS トグル要素
grep -q 'show-win' "$HTML" && grep -q 'show-mac' "$HTML" || { note "FAIL: OS トグルがない"; fail=1; }

# 5) ルート Step1 導入ラッパー存在 + mac 側構文
[ -f "$ROOT/1_安全パッケージを準備-Mac.command" ] || { note "FAIL: Step1 Mac ラッパーがない"; fail=1; }
[ -f "$ROOT/1_安全パッケージを準備-Windows.bat" ] || { note "FAIL: Step1 Win ラッパーがない"; fail=1; }
bash -n "$ROOT/1_安全パッケージを準備-Mac.command" || { note "FAIL: Step1 Mac 構文"; fail=1; }
grep -q '"%ComSpec%" /k call "%TARGET%"' "$ROOT/1_安全パッケージを準備-Windows.bat" || { note "FAIL: Step1 Win ラッパーが同じ画面に残る cmd /k で installer を起動しない"; fail=1; }

# 5b) Windows で .bat が PowerShell に流れた/ブロックされた時の代替導線
grep -Fq '.bat の中身を PowerShell に貼らない' "$HTML" || { note "FAIL: PowerShell に .bat 中身を貼らない注意がない"; fail=1; }
grep -Fq 'Unblock-File -ErrorAction SilentlyContinue; powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\windows\install.ps1"' "$HTML" || { note "FAIL: Step1 の PowerShell 代替コマンドがない"; fail=1; }
grep -Fq 'powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\windows\install.ps1"' "$ROOT/docs/00_クイックスタート.md" || { note "FAIL: クイックスタートに PowerShell 代替コマンドがない"; fail=1; }

# 6) workspace 内ラッパー（.command）構文 + 相対 ws 解決
#
#    「自分の場所から親をたどる」($HERE/..) 解決が要るのは、作業フォルダ配下の
#    ファイル（.ai-safety/... のガードやランチャー、workspace の docs/）を呼ぶ
#    ラッパーだけ。Codex デスクトップアプリの起動のように作業フォルダの場所を
#    知る必要がないものは、この要件の対象外にする。
#    免除の条件は「作業フォルダを一切参照しないこと」で、$HERE を使って別の場所を
#    組み立てているファイルは免除しない（免除の乱用防止）。
#    v1.18.0: サブフォルダ「キーと金庫」の .command も同じ規律で見る。
for f in "$START_DIR/"*.command "$START_DIR/キーと金庫/"*.command; do
  bash -n "$f" || { note "FAIL syntax: $f"; fail=1; }
  if grep -qE '\.ai-safety|docs/' "$f"; then
    grep -q 'HERE/\.\.' "$f" || { note "FAIL: ws 解決(HERE/..)なし: $f"; fail=1; }
  else
    grep -q 'HERE' "$f" && { note "FAIL: 作業フォルダを参照しないのに \$HERE を組み立てている: $f"; fail=1; }
  fi
done

# 7) workspace 内ラッパー（.bat）相対解決 + ターゲット呼び出し
#    作業フォルダ（WORKSPACE）を使う .bat は %HERE% から相対で解決すること。
#    作業フォルダを一切参照しない .bat（例: Codex デスクトップアプリの起動）は対象外。
for f in "$START_DIR/"*.bat "$START_DIR/キーと金庫/"*.bat; do
  if LC_ALL=C grep -q 'WORKSPACE' "$f"; then
    grep -q '%HERE%' "$f" || { note "FAIL: %HERE% なし: $f"; fail=1; }
  else
    LC_ALL=C grep -q '%HERE%' "$f" && { note "FAIL: 作業フォルダを参照しないのに %HERE% を組み立てている: $f"; fail=1; }
  fi
done

# 7b) オンボーディング入口の .bat は CP932 + 行頭 chcp 932 に固定
#
#     旧版のこの検査は逆に「GitHub の画面で文字化けしないように UTF-8 + chcp 65001」を
#     要求していた。しかし UTF-8 + chcp 65001 の .bat を配ると、日本語 Windows の教室 PC で
#     実行した瞬間に文字化けして即閉じになる事故が実際に起きている。GitHub 上の見た目より
#     「配った PC で実行できること」を優先し、SSOT は CP932 + chcp 932 とする
#     (SSOT の実物は scripts/windows/install-one-click.bat)。
#     旧ルールは対象 21 本中 18 本が破ったまま放置され、検査として機能していなかった。
#
#     判定基準は scripts/release-version-check.sh の実バイト検査と揃えてある
#     (そちらはパッケージ内の .bat/.cmd 全部の CRLF と行頭 chcp を見る)。
#     行頭以外の chcp 65001 は対象外 (start で開く別ウィンドウ側を UTF-8 に
#     切り替えるのは正当な用途のため)。
cp932_probe="/tmp/onboarding-cp932.$$"
for f in "$ROOT"/0_*.bat "$ROOT"/1_*.bat "$START_DIR/"*.bat "$START_DIR/キーと金庫/"*.bat; do
  [ -f "$f" ] || continue
  if ! iconv -f CP932 -t UTF-8 "$f" > "$cp932_probe" 2>/dev/null; then
    note "FAIL: CP932 ではない: $f"; fail=1
  fi
  # chcp 932 は日本語を含む .bat にだけ要求する (ASCII だけの .bat は指定なしでよい)。
  if LC_ALL=C tr -d '\000-\177' < "$f" | grep -q .; then
    if ! LC_ALL=C grep -qiE '^[[:space:]]*@?chcp[[:space:]]+932' "$f"; then
      note "FAIL: 非ASCII .bat なのに行頭 chcp 932 がない: $f"; fail=1
    fi
  fi
  # chcp 65001 の禁止は中身によらず全部に効かせる (ASCII だけの .bat でも、後から
  # 日本語を足した瞬間に教室 PC で文字化けするため)。release-version-check.sh と同基準。
  if LC_ALL=C grep -qiE '^[[:space:]]*@?chcp[[:space:]]+65001' "$f"; then
    note "FAIL: 行頭で chcp 65001 を指定している: $f"; fail=1
  fi
done
rm -f "$cp932_probe"

# 8) install が スタート/ を配置する追記を含む（両 OS）
grep -q 'workspace-template/スタート' "$ROOT/scripts/macos/install.sh" || { note "FAIL: install.sh に スタート 配置追記なし"; fail=1; }
grep -q 'workspace-template\\\\スタート' "$ROOT/scripts/windows/install.ps1" || grep -q 'workspace-template\\スタート' "$ROOT/scripts/windows/install.ps1" || { note "FAIL: install.ps1 に スタート 配置追記なし"; fail=1; }

# 8b) Windows は install-one-click.bat の最後の pause より前に スタート フォルダを開く
win_installer_txt="/tmp/onboarding-win-installer.$$"
if iconv -f CP932 -t UTF-8 "$ROOT/scripts/windows/install-one-click.bat" > "$win_installer_txt" 2>/dev/null; then
  open_line=$(grep -n 'start "" explorer' "$win_installer_txt" | tail -1 | cut -d: -f1)
  last_pause_line=$(grep -n '^pause' "$win_installer_txt" | tail -1 | cut -d: -f1)
  if [ -z "$open_line" ] || [ -z "$last_pause_line" ] || [ "$open_line" -gt "$last_pause_line" ]; then
    note "FAIL: Windows installer が最後の pause 前に スタート フォルダを開かない"
    fail=1
  fi
else
  note "FAIL: install-one-click.bat を CP932 として読めない"
  fail=1
fi
rm -f "$win_installer_txt"

# 9) 期待される番号ファイルが揃う（v1.18.0 再編後: 直下 基本 1..9 + Windows 専用 10..12、
#    サブフォルダ「キーと金庫」1..13）。
#    v1.18.0: 個別のセーフ起動ボタンは「4_AIを起動する」（統合ランチャー）へ集約し、
#    「（上級）」プレフィックスを全廃。キー・金庫系は「キーと金庫」へ移した。
VAULT_DIR="$START_DIR/キーと金庫"
for base in "1_安全パッケージを最新版にする" "2_AIツールをまとめて入れる" "3_じぶんに合うAIを選ぶ" "4_AIを起動する" "5_Codexデスクトップアプリを起動" "6_長時間おまかせモードで起動" "7_見守りモニターを起動" "8_使い方ガイドを開く" "9_困ったとき診断"; do
  [ -f "$START_DIR/$base.command" ] || { note "FAIL: $base.command がない"; fail=1; }
  [ -f "$START_DIR/$base.bat" ] || { note "FAIL: $base.bat がない"; fail=1; }
done
for base in "1_DeepSeekキーを登録" "2_DeepSeekキーを削除" "3_AIコーチのキーを登録" "4_AIコーチのキーを削除" "5_Bufferのキーを登録" "6_Bufferのキーを削除" "7_金庫に秘密をしまう" "8_金庫から秘密を取り出す" "9_金庫の秘密を消す" "10_コピーした文章から秘密を伏せる" "11_伏せた文章を元に戻す" "12_PC全体に安全設定を入れる" "13_PC全体の安全設定を解除"; do
  [ -f "$VAULT_DIR/$base.command" ] || { note "FAIL: キーと金庫/$base.command がない"; fail=1; }
  [ -f "$VAULT_DIR/$base.bat" ] || { note "FAIL: キーと金庫/$base.bat がない"; fail=1; }
done
# Windows だけの追加ボタン（.command は無い）。
#   12 は v1.17.2 新設のアクセス権修復ボタン。Windows の ACL 固有の事故（install が
#   USERDOMAIN\USERNAME という解決できない名前に権限を与え、本人まで締め出す）への
#   回復口なので mac 版は無い。
for base in "10_PowerShellを開く" "11_作業フォルダを開く" "12_フォルダのアクセス権を直す"; do
  [ -f "$START_DIR/$base.bat" ] || { note "FAIL: $base.bat がない"; fail=1; }
done
grep -q 'repair-permissions.ps1' "$START_DIR/12_フォルダのアクセス権を直す.bat" || { note "FAIL: 12 のボタンが repair-permissions.ps1 を呼ばない"; fail=1; }
grep -Fq '12_フォルダのアクセス権を直す' "$HTML" || { note "FAIL: スタート.html に 12_フォルダのアクセス権を直す の案内がない"; fail=1; }
# 旧番号が残っていないこと（旧新併存で番号が重複すると受講者が迷う）。
for old in "1_AIをまとめて起動" "2_セーフCodexを起動" "3_セーフClaudeを起動" \
           "4_セーフAntiGravityを起動" "5_セーフOpenCodeを起動" "9_AIツールを最新版に更新" \
           "10_困ったとき診断" "11_野良d-claudeを退治" "（上級）2_DeepSeek-Claudeを起動" \
           "（上級）15_長時間おまかせモードで起動" "（上級）16_金庫に秘密をしまう"; do
  for ext in command bat; do
    [ -f "$START_DIR/$old.$ext" ] && { note "FAIL: 旧番号のボタンが残っている: $old.$ext"; fail=1; }
  done
done
# install の旧名掃除リストに旧番号が入っているか（更新した受講者の手元で二重に残らないため）。
for old in "1_AIをまとめて起動.command" "2_セーフCodexを起動.command" "5_セーフOpenCodeを起動.command" \
           "8_安全パッケージを最新版に更新.command" "9_AIツールを最新版に更新.command" "10_困ったとき診断.command" \
           "11_野良d-claudeを退治.command" "12_PowerShellを開く.bat" "13_作業フォルダを開く.bat" \
           "14_フォルダのアクセス権を直す.bat" "（上級）2_DeepSeek-Claudeを起動.command" \
           "（上級）14_新しい作業フォルダを安全にする.command" "（上級）15_長時間おまかせモードで起動.command" \
           "（上級）16_金庫に秘密をしまう.command" "（上級）17_金庫から秘密を取り出す.command" "（上級）18_金庫の秘密を消す.command"; do
  grep -Fq "$old" "$ROOT/scripts/macos/install.sh" || { note "FAIL: install.sh の旧名掃除リストに $old がない"; fail=1; }
  grep -Fq "$old" "$ROOT/scripts/windows/install.ps1" || { note "FAIL: install.ps1 の旧名掃除リストに $old がない"; fail=1; }
done

# 9a) OpenCode の起動導線は「4_AIを起動する」（統合ランチャー）に集約された。
#     ボタンはメニューの正本（launch-integrated の menu モード）へ委譲し、
#     メニューから OpenCode を standard で起動できること。
grep -q 'menu standard' "$START_DIR/4_AIを起動する.command" || { note "FAIL: 4_AIを起動する .command が menu モードへ委譲しない"; fail=1; }
LC_ALL=C grep -q -- '-Agent menu' "$START_DIR/4_AIを起動する.bat" || { note "FAIL: 4_AIを起動する .bat が menu モードへ委譲しない"; fail=1; }
grep -q 'agent="opencode"; profile="standard"' "$ROOT/scripts/macos/launch-integrated.sh" || { note "FAIL: 統合ランチャーのメニューから OpenCode を起動できない"; fail=1; }
grep -Fq '4_AIを起動する' "$HTML" || { note "FAIL: スタート.html に 4_AIを起動する の案内がない"; fail=1; }

# 9b) PC 全体の安全設定（キーと金庫 12）と その解除（キーと金庫 13）が正しい wrapper を呼ぶ（4 エンジン対応）
grep -q 'apply-global-guard.sh' "$VAULT_DIR/12_PC全体に安全設定を入れる.command" || { note "FAIL: キーと金庫12 .command が apply-global-guard.sh を呼ばない"; fail=1; }
grep -q 'apply-global-guard.ps1' "$VAULT_DIR/12_PC全体に安全設定を入れる.bat" || { note "FAIL: キーと金庫12 .bat が apply-global-guard.ps1 を呼ばない"; fail=1; }
grep -q 'uninstall-global-guard.sh' "$VAULT_DIR/13_PC全体の安全設定を解除.command" || { note "FAIL: キーと金庫13 .command が uninstall-global-guard.sh を呼ばない"; fail=1; }
grep -q 'uninstall-global-guard.ps1' "$VAULT_DIR/13_PC全体の安全設定を解除.bat" || { note "FAIL: キーと金庫13 .bat が uninstall-global-guard.ps1 を呼ばない"; fail=1; }
grep -Fq 'キーと金庫/12_PC全体に安全設定を入れる' "$HTML" || { note "FAIL: スタート.html に キーと金庫12 の案内がない"; fail=1; }
grep -Fq 'キーと金庫/13_PC全体の安全設定を解除' "$HTML" || { note "FAIL: スタート.html に キーと金庫13 の案内がない"; fail=1; }

# 9c) 「新しい作業フォルダを安全にする」ボタンは v1.18.0 で廃止（スタートの絞り込み）。
#     旧ボタンが配布物に残っておらず、既存ワークスペースからも掃除されること。
for ext in command bat; do
  [ -f "$START_DIR/（上級）14_新しい作業フォルダを安全にする.$ext" ] && { note "FAIL: 廃止した 上級14 ボタンが残っている (.$ext)"; fail=1; }
done

# 9c-2) 長時間おまかせモード（6 番）。v1.17.1 で 4 エンジン × 2 OS に対応した。
#       壁（OS サンドボックス）がある環境では従来どおり、壁が無い環境では一度だけ確認を取る。
#       「Windows では起動しない」旧仕様に戻っていないこともここで見る。
grep -q 'launch-longrun.sh' "$START_DIR/6_長時間おまかせモードで起動.command" || { note "FAIL: 6 番 .command が launch-longrun.sh を呼ばない"; fail=1; }
grep -q 'launch-longrun.ps1' "$START_DIR/6_長時間おまかせモードで起動.bat" || { note "FAIL: 6 番 .bat が launch-longrun.ps1 を呼ばない"; fail=1; }
grep -Fq '6_長時間おまかせモード' "$HTML" || { note "FAIL: スタート.html に 6_長時間おまかせモード の案内がない"; fail=1; }

# 9c-3) 汎用の金庫ボタン（キーと金庫 7 しまう / 8 取り出す / 9 消す）。
#       固定枠（AIコーチ・Buffer 等）とは別の「自由枠」で、受講者が名前を付けて
#       任意の文字列をしまう。3 本とも secret-store.js の自由枠 CLI を呼ぶこと。
grep -q 'secret-store.js' "$VAULT_DIR/7_金庫に秘密をしまう.command" || { note "FAIL: 金庫7 .command が secret-store.js を呼ばない"; fail=1; }
grep -q -- '--user-set' "$VAULT_DIR/7_金庫に秘密をしまう.command" || { note "FAIL: 金庫7 .command が --user-set を呼ばない"; fail=1; }
grep -q -- '--user-list' "$VAULT_DIR/8_金庫から秘密を取り出す.command" || { note "FAIL: 金庫8 .command が --user-list を呼ばない"; fail=1; }
grep -q -- '--user-copy' "$VAULT_DIR/8_金庫から秘密を取り出す.command" || { note "FAIL: 金庫8 .command が --user-copy を呼ばない"; fail=1; }
grep -q -- '--user-remove' "$VAULT_DIR/9_金庫の秘密を消す.command" || { note "FAIL: 金庫9 .command が --user-remove を呼ばない"; fail=1; }
# 値を画面に出さない（7 は read -s、8 はクリップボード経由）ことを固定する。
grep -q 'read -r -s' "$VAULT_DIR/7_金庫に秘密をしまう.command" || { note "FAIL: 金庫7 .command が中身をエコーしない入力になっていない"; fail=1; }
grep -q 'AsSecureString' "$VAULT_DIR/7_金庫に秘密をしまう.bat" || { note "FAIL: 金庫7 .bat が中身をエコーしない入力になっていない"; fail=1; }
# .bat 側も同じ CLI を呼ぶ（CP932 なので grep は復号してから）。
for _n in 7 8 9; do
  case "$_n" in
    7) _bat="7_金庫に秘密をしまう.bat"; _need='--user-set' ;;
    8) _bat="8_金庫から秘密を取り出す.bat"; _need='--user-copy' ;;
    9) _bat="9_金庫の秘密を消す.bat"; _need='--user-remove' ;;
  esac
  _tmp="$(mktemp)"
  if iconv -f CP932 -t UTF-8 "$VAULT_DIR/$_bat" > "$_tmp" 2>/dev/null; then
    grep -q -- "$_need" "$_tmp" || { note "FAIL: 金庫$_n .bat が $_need を呼ばない"; fail=1; }
  else
    note "FAIL: 金庫$_n .bat を CP932 として読めない"; fail=1
  fi
  rm -f "$_tmp"
done
grep -Fq 'キーと金庫/7_金庫に秘密をしまう' "$HTML" || { note "FAIL: スタート.html に 金庫7 の案内がない"; fail=1; }
grep -Fq 'キーと金庫/8_金庫から秘密を取り出す' "$HTML" || { note "FAIL: スタート.html に 金庫8 の案内がない"; fail=1; }
grep -Fq 'キーと金庫/9_金庫の秘密を消す' "$HTML" || { note "FAIL: スタート.html に 金庫9 の案内がない"; fail=1; }
for _need in 'sandbox-exec' 'sandbox.enabled' 'disableBypassPermissionsMode' 'p.ask = \[\]' 'mktemp -d'; do
  grep -q "$_need" "$ROOT/scripts/macos/launch-longrun.sh" || { note "FAIL: 長時間おまかせモードに $_need の守りがない"; fail=1; }
done
grep -q 'bypassPermissions' "$ROOT/scripts/macos/launch-longrun.sh" || { note "FAIL: 長時間おまかせモードが bypassPermissions を封じる記述を失っている"; fail=1; }
# 4 エンジン分の経路が mac / Windows の両方にあること。
for _engine in 'launch-codex-safe' 'launch-agy-safe' 'launch-integrated'; do
  grep -q "$_engine" "$ROOT/scripts/macos/launch-longrun.sh" || { note "FAIL: 長時間おまかせモード(mac)に $_engine 経路がない"; fail=1; }
  grep -q "$_engine" "$ROOT/scripts/windows/launch-longrun.ps1" || { note "FAIL: 長時間おまかせモード(win)に $_engine 経路がない"; fail=1; }
done
grep -q 'disableBypassPermissionsMode' "$ROOT/scripts/windows/launch-longrun.ps1" || { note "FAIL: Windows の長時間おまかせモードが bypassPermissions を封じていない"; fail=1; }
grep -q 'いまは Mac でだけ使えます' "$ROOT/scripts/windows/launch-longrun.ps1" && { note "FAIL: Windows の長時間おまかせモードが起動拒否の旧仕様に戻っている"; fail=1; }

# 9d) 全体設定の反映／解除ラッパーが 4 エンジン分の実体を呼ぶ
for _js in apply-global-guard.js apply-global-codex.js apply-global-agy.js apply-global-opencode.js; do
  grep -q "$_js" "$ROOT/scripts/macos/apply-global-guard.sh" || { note "FAIL: apply-global-guard.sh が $_js を呼ばない"; fail=1; }
  grep -q "$_js" "$ROOT/scripts/macos/uninstall-global-guard.sh" || { note "FAIL: uninstall-global-guard.sh が $_js を呼ばない"; fail=1; }
  grep -q "$_js" "$ROOT/scripts/windows/apply-global-guard.ps1" || { note "FAIL: apply-global-guard.ps1 が $_js を呼ばない"; fail=1; }
  grep -q "$_js" "$ROOT/scripts/windows/uninstall-global-guard.ps1" || { note "FAIL: uninstall-global-guard.ps1 が $_js を呼ばない"; fail=1; }
done

if [ $fail -eq 0 ]; then note "ALL PASS"; else note "FAILURES ABOVE"; exit 1; fi
