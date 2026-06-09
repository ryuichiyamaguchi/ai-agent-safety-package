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
for f in "$START_DIR/"*.command; do
  bash -n "$f" || { note "FAIL syntax: $f"; fail=1; }
  grep -q 'HERE/\.\.' "$f" || { note "FAIL: ws 解決(HERE/..)なし: $f"; fail=1; }
done

# 7) workspace 内ラッパー（.bat）相対解決 + ターゲット呼び出し
for f in "$START_DIR/"*.bat; do
  grep -q '%HERE%' "$f" || { note "FAIL: %HERE% なし: $f"; fail=1; }
done

# 7b) GitHub で文字化けしないよう、オンボーディング入口の .bat は UTF-8 + chcp 65001 に固定
for f in "$ROOT"/0_*.bat "$ROOT"/1_*.bat "$START_DIR/"*.bat; do
  [ -f "$f" ] || continue
  iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1 || { note "FAIL: UTF-8 ではない: $f"; fail=1; }
  if LC_ALL=C tr -d '\000-\177' < "$f" | grep -q .; then
    grep -q 'chcp 65001' "$f" || { note "FAIL: 非ASCII .bat なのに chcp 65001 ではない: $f"; fail=1; }
  fi
done

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

# 9) 期待される番号ファイルが揃う（2..5 と 上級1/2/9）
for base in "2_セーフCodexを起動" "3_セーフClaudeを起動" "4_セーフAntiGravityを起動" "5_見守りモニターを起動" "（上級）1_DeepSeekキーを登録" "（上級）2_DeepSeek-Claudeを起動" "（上級）9_DeepSeekキーを削除"; do
  [ -f "$START_DIR/$base.command" ] || { note "FAIL: $base.command がない"; fail=1; }
  [ -f "$START_DIR/$base.bat" ] || { note "FAIL: $base.bat がない"; fail=1; }
done

if [ $fail -eq 0 ]; then note "ALL PASS"; else note "FAILURES ABOVE"; exit 1; fi
