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
#    ファイル（.ai-safety/... のガードやランチャー）を呼ぶラッパーだけ。
#    npm でツールを入れるだけのラッパーのように作業フォルダの場所を知る必要が
#    ないものは、この要件の対象外にする。
#    免除の条件は「作業フォルダを一切参照しないこと」で、$HERE を使って別の場所を
#    組み立てているファイルは免除しない（免除の乱用防止）。
for f in "$START_DIR/"*.command; do
  bash -n "$f" || { note "FAIL syntax: $f"; fail=1; }
  if grep -q '\.ai-safety' "$f"; then
    grep -q 'HERE/\.\.' "$f" || { note "FAIL: ws 解決(HERE/..)なし: $f"; fail=1; }
  else
    grep -q 'HERE' "$f" && { note "FAIL: 作業フォルダを参照しないのに \$HERE を組み立てている: $f"; fail=1; }
  fi
done

# 7) workspace 内ラッパー（.bat）相対解決 + ターゲット呼び出し
for f in "$START_DIR/"*.bat; do
  grep -q '%HERE%' "$f" || { note "FAIL: %HERE% なし: $f"; fail=1; }
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
for f in "$ROOT"/0_*.bat "$ROOT"/1_*.bat "$START_DIR/"*.bat; do
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

# 9) 期待される番号ファイルが揃う（v1.17.1 番号再編後: 基本 1..11 と 上級1..15）
#    v1.17.1: 「5_セーフOpenCodeを起動」を基本枠へ入れ、旧 5〜12 を 1 つずつ繰り下げた。
#    これで AI 4 種（Codex / Claude / AntiGravity / OpenCode）が 2〜5 に並ぶ。
for base in "1_AIをまとめて起動" "2_セーフCodexを起動" "3_セーフClaudeを起動" "4_セーフAntiGravityを起動" "5_セーフOpenCodeを起動" "6_見守りモニターを起動" "7_AIコーチのキーを登録" "8_安全パッケージを最新版に更新" "9_AIツールを最新版に更新" "10_困ったとき診断" "11_野良d-claudeを退治" "（上級）1_DeepSeekキーを登録" "（上級）2_DeepSeek-Claudeを起動" "（上級）3_モニターをコンソールで見る" "（上級）4_ステータスラインを入れる" "（上級）5_このPC全体に最低限の安全設定を入れる" "（上級）6_PC全体の安全設定を解除" "（上級）7_DeepSeekキーを削除" "（上級）8_Bufferのキーを登録" "（上級）9_プラグインの置き場を開く" "（上級）14_新しい作業フォルダを安全にする" "（上級）15_長時間おまかせモードで起動"; do
  [ -f "$START_DIR/$base.command" ] || { note "FAIL: $base.command がない"; fail=1; }
  [ -f "$START_DIR/$base.bat" ] || { note "FAIL: $base.bat がない"; fail=1; }
done
# Windows だけの追加ボタン（.command は無い）。番号の繰り下げに追従しているか。
for base in "12_PowerShellを開く" "13_作業フォルダを開く"; do
  [ -f "$START_DIR/$base.bat" ] || { note "FAIL: $base.bat がない"; fail=1; }
done
# 旧番号が残っていないこと（旧新併存で番号が重複すると受講者が迷う）。
for old in "5_見守りモニターを起動" "6_AIコーチのキーを登録" "7_安全パッケージを最新版に更新" \
           "8_AIツールを最新版に更新" "9_困ったとき診断" "10_野良d-claudeを退治" \
           "11_PowerShellを開く" "12_作業フォルダを開く"; do
  for ext in command bat; do
    [ -f "$START_DIR/$old.$ext" ] && { note "FAIL: 旧番号のボタンが残っている: $old.$ext"; fail=1; }
  done
done
# install の旧名掃除リストに旧番号が入っているか（更新した受講者の手元で二重に残らないため）。
for old in "5_見守りモニターを起動.command" "6_AIコーチのキーを登録.command" "7_安全パッケージを最新版に更新.command" \
           "8_AIツールを最新版に更新.command" "9_困ったとき診断.command" "10_野良d-claudeを退治.command" \
           "11_PowerShellを開く.bat" "12_作業フォルダを開く.bat"; do
  grep -Fq "$old" "$ROOT/scripts/macos/install.sh" || { note "FAIL: install.sh の旧名掃除リストに $old がない"; fail=1; }
  grep -Fq "$old" "$ROOT/scripts/windows/install.ps1" || { note "FAIL: install.ps1 の旧名掃除リストに $old がない"; fail=1; }
done

# 9a) セーフ OpenCode 単独ボタン（v1.17.1 新設）は既存の安全起動口 oc-safe を呼ぶ。
grep -q 'oc-safe' "$START_DIR/5_セーフOpenCodeを起動.command" || { note "FAIL: 5_セーフOpenCode .command が oc-safe を呼ばない"; fail=1; }
grep -q 'oc-safe.ps1' "$START_DIR/5_セーフOpenCodeを起動.bat" || { note "FAIL: 5_セーフOpenCode .bat が oc-safe.ps1 を呼ばない"; fail=1; }
grep -Fq '5_セーフOpenCodeを起動' "$HTML" || { note "FAIL: スタート.html に 5_セーフOpenCodeを起動 の案内がない"; fail=1; }

# 9b) PC 全体の安全設定（上級5）と その解除（上級6）が正しい wrapper を呼ぶ（4 エンジン対応）
grep -q 'apply-global-guard.sh' "$START_DIR/（上級）5_このPC全体に最低限の安全設定を入れる.command" || { note "FAIL: 上級5 .command が apply-global-guard.sh を呼ばない"; fail=1; }
grep -q 'apply-global-guard.ps1' "$START_DIR/（上級）5_このPC全体に最低限の安全設定を入れる.bat" || { note "FAIL: 上級5 .bat が apply-global-guard.ps1 を呼ばない"; fail=1; }
grep -q 'uninstall-global-guard.sh' "$START_DIR/（上級）6_PC全体の安全設定を解除.command" || { note "FAIL: 上級6 .command が uninstall-global-guard.sh を呼ばない"; fail=1; }
grep -q 'uninstall-global-guard.ps1' "$START_DIR/（上級）6_PC全体の安全設定を解除.bat" || { note "FAIL: 上級6 .bat が uninstall-global-guard.ps1 を呼ばない"; fail=1; }
grep -Fq '（上級）5' "$HTML" || { note "FAIL: スタート.html に 上級5 の案内がない"; fail=1; }
grep -Fq '（上級）6' "$HTML" || { note "FAIL: スタート.html に 上級6 の案内がない"; fail=1; }

# 9c) 新しい作業フォルダを安全にする（上級14）が protect-folder を呼ぶ
grep -q 'protect-folder.sh' "$START_DIR/（上級）14_新しい作業フォルダを安全にする.command" || { note "FAIL: 上級14 .command が protect-folder.sh を呼ばない"; fail=1; }
grep -q 'protect-folder.ps1' "$START_DIR/（上級）14_新しい作業フォルダを安全にする.bat" || { note "FAIL: 上級14 .bat が protect-folder.ps1 を呼ばない"; fail=1; }
grep -Fq '（上級）14' "$HTML" || { note "FAIL: スタート.html に 上級14 の案内がない"; fail=1; }

# 9c-2) 長時間おまかせモード（上級15）。v1.17.1 で 4 エンジン × 2 OS に対応した。
#       壁（OS サンドボックス）がある環境では従来どおり、壁が無い環境では一度だけ確認を取る。
#       「Windows では起動しない」旧仕様に戻っていないこともここで見る。
grep -q 'launch-longrun.sh' "$START_DIR/（上級）15_長時間おまかせモードで起動.command" || { note "FAIL: 上級15 .command が launch-longrun.sh を呼ばない"; fail=1; }
grep -q 'launch-longrun.ps1' "$START_DIR/（上級）15_長時間おまかせモードで起動.bat" || { note "FAIL: 上級15 .bat が launch-longrun.ps1 を呼ばない"; fail=1; }
grep -Fq '（上級）15' "$HTML" || { note "FAIL: スタート.html に 上級15 の案内がない"; fail=1; }
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
