#!/bin/bash
# run-local-zsh.test.sh — Bouncer ローカル Gateway の mac 起動スクリプト
# (bouncer-gateway/scripts/run-local.zsh) の異常系テスト。
#
# 偽の lms / python3 を PATH と HOME に置いて出荷スクリプトをそのまま実走させ、
# 「LM Studio の状態を読み違えたまま先へ進まないこと」を終了コードと呼び出し記録で見る。
# Windows 版 run-local.ps1 と同じ分類 (running / stopped / unknown) にそろっているかの
# パリティ検査でもある。
#
# 守りたい退行:
#   - status の失敗・空・未知の文言を「停止」とみなして server start へ進む (fail-open)
#   - lms ps の失敗・空出力を「モデル無し」とみなして二重 load へ進む
#   - 異常時のメッセージが英語のまま
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/bouncer-gateway/scripts/run-local.zsh"
pass=0
fail=0
note(){ echo "[run-local-zsh] $1"; }
ok(){ note "PASS $1"; pass=$((pass + 1)); }
ng(){ note "FAIL $1"; fail=$((fail + 1)); }

if ! command -v zsh >/dev/null 2>&1; then
  note "SKIP: zsh がありません"
  exit 0
fi
[ -f "$SCRIPT" ] || { ng "run-local.zsh がない: $SCRIPT"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run-local-zsh.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

# 出荷スクリプトを同じ相対配置 (<root>/scripts/run-local.zsh) で複製する。
mkdir -p "$TMP/task/scripts" "$TMP/task/src" "$TMP/bin" "$TMP/home/.lmstudio/bin"
cp "$SCRIPT" "$TMP/task/scripts/run-local.zsh"

cat > "$TMP/home/.lmstudio/bin/lms" <<'FAKE'
#!/bin/bash
echo "lms $*" >> "$LMS_LOG"
if [ "$1" = "server" ] && [ "$2" = "status" ]; then
  printf '%s' "${FAKE_STATUS_OUT-}"
  exit "${FAKE_STATUS_RC:-0}"
fi
if [ "$1" = "ps" ]; then
  printf '%s' "${FAKE_PS_OUT-}"
  exit "${FAKE_PS_RC:-0}"
fi
if [ "$1" = "server" ] && [ "$2" = "start" ]; then exit "${FAKE_START_RC:-0}"; fi
if [ "$1" = "load" ]; then exit "${FAKE_LOAD_RC:-0}"; fi
exit 0
FAKE
chmod +x "$TMP/home/.lmstudio/bin/lms"

cat > "$TMP/bin/python3" <<'FAKE'
#!/bin/bash
echo "python3 $*" >> "$LMS_LOG"
exit 0
FAKE
chmod +x "$TMP/bin/python3"

seq_no=0
# run_case <期待 ok|abort> <説明> <status出力> <status終了コード> <ps出力> <ps終了コード>
# 戻り: $LOG に呼び出し記録 / $OUT に標準エラー
run_case() {
  local expect="$1" label="$2" s_out="$3" s_rc="$4" p_out="$5" p_rc="$6"
  seq_no=$((seq_no + 1))
  LOG="$TMP/log$seq_no.txt"
  OUT="$TMP/out$seq_no.txt"
  : > "$LOG"
  ( export HOME="$TMP/home" PATH="$TMP/bin:$PATH" LMS_LOG="$LOG" \
      FAKE_STATUS_OUT="$s_out" FAKE_STATUS_RC="$s_rc" FAKE_PS_OUT="$p_out" FAKE_PS_RC="$p_rc"
    zsh "$TMP/task/scripts/run-local.zsh" ) >"$OUT" 2>&1
  RC=$?
  if [ "$expect" = "ok" ] && [ "$RC" -ne 0 ]; then
    ng "$label — 起動できなかった (exit ${RC})"; sed -n '1,5p' "$OUT"; return 1
  fi
  if [ "$expect" = "abort" ] && [ "$RC" -eq 0 ]; then
    ng "$label — 中止せず先へ進んだ (exit 0)"; return 1
  fi
  return 0
}

logged(){ grep -qF "$1" "$LOG"; }

# --- 判定不能 (unknown) は中止する -------------------------------------------
if run_case abort "status が未知の文言なら中止する" "Something unexpected happened" 0 "" 0; then
  if logged "lms server start"; then ng "未知の文言なのに server start を呼んだ"
  elif ! grep -q "判定できませんでした" "$OUT"; then ng "未知の文言: 日本語の中止メッセージが出ない"
  else ok "status が未知の文言なら日本語で中止し、server start を呼ばない"; fi
fi

if run_case abort "status が空なら中止する" "" 0 "" 0; then
  if logged "lms server start"; then ng "status が空なのに server start を呼んだ"
  else ok "status が空なら中止し、server start を呼ばない"; fi
fi

if run_case abort "status コマンド自体が失敗したら中止する" "" 127 "" 0; then
  if logged "lms server start"; then ng "status 失敗なのに server start を呼んだ"
  else ok "status コマンドが失敗したら中止し、server start を呼ばない"; fi
fi

# --- running / stopped を取り違えない ----------------------------------------
if run_case ok "稼働中なら server start を呼ばない" "The server is running on port 1234" 0 "bouncer-gemma  loaded" 0; then
  if logged "lms server start"; then ng "稼働中なのに server start を呼んだ"
  elif logged "lms server stop"; then ng "自分で起動していないサーバーを停止した"
  else ok "稼働中: server start を呼ばず、他人のサーバーを停止もしない"; fi
fi

if run_case ok "停止中なら server start を呼ぶ" "The server is not running." 0 "bouncer-gemma  loaded" 0; then
  if logged "lms server start" && logged "lms server stop"; then
    ok "停止中: server start を呼び、終了時に自分が起動した分だけ停止する"
  else
    ng "停止中: server start / 終了時の server stop が記録されていない"
  fi
fi

# --- lms ps の異常 ------------------------------------------------------------
if run_case abort "ps が空なら中止する" "The server is running" 0 "" 0; then
  if logged "lms load"; then ng "ps が空なのに load を呼んだ"
  elif ! grep -q "確認できませんでした" "$OUT"; then ng "ps 空: 日本語の中止メッセージが出ない"
  else ok "ps が空なら日本語で中止し、load を呼ばない"; fi
fi

if run_case abort "ps コマンド自体が失敗したら中止する" "The server is running" 0 "" 1; then
  if logged "lms load"; then ng "ps 失敗なのに load を呼んだ"
  else ok "ps コマンドが失敗したら中止し、load を呼ばない"; fi
fi

# --- 正常系 (モデル未読込) ----------------------------------------------------
if run_case ok "モデル未読込なら load して起動する" "The server is running" 0 "他のモデル  loaded" 0; then
  if logged "lms load google/gemma-4-12b" && logged "python3 -m bouncer serve" && logged "lms unload bouncer-gemma"; then
    ok "モデル未読込: load → serve → 終了時 unload まで通る"
  else
    ng "モデル未読込: load / serve / unload のいずれかが記録されていない"
  fi
fi

# --- メッセージが日本語であること --------------------------------------------
# 受講者に出る異常メッセージ (print -u2) に日本語が 1 文字も無い行があれば落とす。
ascii_msgs="$(python3 - "$SCRIPT" <<'PY'
import sys
for i, line in enumerate(open(sys.argv[1], encoding='utf-8'), 1):
    if 'print -u2' in line and all(ord(c) < 128 for c in line):
        print(f"{i}: {line.strip()}")
PY
)"
if [ -n "$ascii_msgs" ]; then
  ng "英語のみの異常メッセージが残っている"
  echo "$ascii_msgs"
else
  ok "異常時のメッセージがすべて日本語"
fi

note "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
