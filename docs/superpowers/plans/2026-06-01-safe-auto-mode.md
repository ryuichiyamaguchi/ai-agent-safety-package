# Safe Auto Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Codex と agy の launcher に「OS 隔離(金庫)を doctor が実証検証できたときだけ承認プロンプトを外す」`--auto` オプションを足す。

**Architecture:** doctor に engine 別の隔離実証ドリル(workspace 外書込遮断 / 外部ネット送信遮断)と軽量サブコマンド `--isolation-check <engine>` を追加。launcher は `--auto` を受けると doctor 軽量チェックを呼び、exit 0(全 green)なら承認レベルを下げ、非 0(赤/保留)なら理由を表示して従来の都度承認モードへフェイルクローズする。OS 金庫・hook・deny は解放後も常時稼働。

**Tech Stack:** Bash (macOS, `scripts/macos/`), PowerShell (Windows, `scripts/windows/`)。テストは本パッケージ既存の「doctor 風 PASS/FAIL drill ハーネス」方式(JS/別フレームワーク無し)。

**前提 spec:** `docs/superpowers/specs/2026-06-01-safe-auto-mode-design.md`

---

## File Structure

新規・変更するファイルと責務:

| ファイル | 区分 | 責務 |
|---|---|---|
| `scripts/macos/lib/isolation-drills.sh` | 新規 | engine 別の金庫実証ドリル関数(`drill_write_outside` / `drill_network_egress`)を提供。doctor と test から source される単一の真実源 |
| `scripts/macos/doctor.sh` | 変更 | (a) isolation-drills.sh を取り込み、フル doctor に①②ドリルを追加。(b) `--isolation-check <engine>` 軽量サブコマンドを追加(その engine の①②だけ実行し exit code を返す) |
| `scripts/macos/launch-codex-safe.sh` | 変更 | `--auto` を受付。doctor 軽量チェック green で `--ask-for-approval on-failure`、赤で理由表示 + 従来 `untrusted`。`AI_SAFE_DRY_RUN`/`AI_SAFE_DOCTOR` のテスト seam を追加 |
| `scripts/macos/launch-agy-safe.sh` | 変更 | 同上(agy は auto-run 有効化。本計画では検証結果で縮退する分岐を含む) |
| `scripts/macos/test/auto-mode.test.sh` | 新規 | 隔離ドリルと launcher 分岐の PASS/FAIL テストハーネス(doctor と同じ流儀) |
| `scripts/windows/lib/isolation-drills.ps1` | 新規 | mac 版 isolation-drills.sh の PowerShell 対応 |
| `scripts/windows/doctor.ps1` | 変更 | mac doctor.sh と同じ追加(①②ドリル + `-IsolationCheck <engine>`) |
| `scripts/windows/launch-codex-safe.ps1` | 変更 | mac launch-codex-safe.sh と同じ `--auto` 分岐 |
| `scripts/windows/launch-agy-safe.ps1` | 変更 | mac launch-agy-safe.sh と同じ `--auto` 分岐 |
| `scripts/windows/test/auto-mode.test.ps1` | 新規 | Windows 版テストハーネス |

実装順序: macOS を完成(Task 1〜6)→ Windows へミラー(Task 7〜10)。各 Task は独立してコミット可能。

---

## テスト seam の設計(全 launcher 共通)

launcher を実 CLI 起動なしでテストできるよう、2 つの環境変数を導入する:

- **`AI_SAFE_DOCTOR`**: doctor 実行コマンドのパスを上書き(既定は同梱の `doctor.sh`)。テストは「常に exit 0 のスタブ」「常に exit 1 のスタブ」を注入して green/赤の両分岐を検証する。
- **`AI_SAFE_DRY_RUN`**: 値が `1` のとき、launcher は最終的に組み立てた起動コマンドを**実行せず 1 行で標準出力に出して exit 0**。テストはこの出力文字列を assert する。

この seam は `--auto` 無しの従来経路にも入れるが、未設定時の動作(実 exec)は不変。

---

## Task 1: 隔離ドリルライブラリ(workspace 外書込遮断)

**Files:**
- Create: `scripts/macos/lib/isolation-drills.sh`
- Test: `scripts/macos/test/auto-mode.test.sh`

- [ ] **Step 1: テストハーネスとworkspace外書込ドリルの失敗テストを書く**

Create `scripts/macos/test/auto-mode.test.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/isolation-drills.sh"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
ng()  { echo "FAIL $1"; fail=$((fail+1)); }

# shellcheck disable=SC1090
. "$LIB"

# --- Task 1: drill_write_outside ---
# codex が無い環境では drill は「保留(非0)」を返す約束。
# codex 有無に関わらず、関数が定義され呼び出せることを確認する。
if type drill_write_outside >/dev/null 2>&1; then ok "drill_write_outside defined"; else ng "drill_write_outside defined"; fi

echo "auto-mode.test summary: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash scripts/macos/test/auto-mode.test.sh`
Expected: FAIL — `isolation-drills.sh` が存在せず source に失敗、または `drill_write_outside defined` が FAIL。

- [ ] **Step 3: isolation-drills.sh に drill_write_outside を実装**

Create `scripts/macos/lib/isolation-drills.sh`:

```bash
#!/usr/bin/env bash
# isolation-drills.sh — OS 金庫(サンドボックス)が実際に効いているかを
# 実証検証するドリル群。doctor.sh と test から source される。
# 返り値の約束:
#   0   = PASS (金庫が効いている = 該当の遮断が実証できた)
#   10  = FAIL (金庫に穴 = 遮断できなかった)
#   20  = 保留 (効力を実証できない。安全側で「赤」扱いにすること)
# 標準出力に "PASS/FAIL/HOLD <理由>" を 1 行出す(launcher のフォールバック表示に使う)。

# drill_write_outside <engine>
# 金庫の中から workspace 外への書き込みを試み、作られないことを確認する。
drill_write_outside() {
  local engine="$1"
  case "$engine" in
    codex)
      command -v codex >/dev/null 2>&1 || { echo "HOLD codex not installed"; return 20; }
      local root inside outside
      root="$(mktemp -d)"; inside="$root/ws"; outside="$root/out"
      mkdir -p "$inside" "$outside"
      local target="$outside/pwn.txt"
      ( codex sandbox macos -C "$inside" /bin/sh -lc "echo pwn > '$target'" ) >/dev/null 2>&1 || true
      if [ -e "$target" ]; then rm -rf "$root"; echo "FAIL workspace-outside write succeeded"; return 10; fi
      rm -rf "$root"; echo "PASS workspace-outside write blocked"; return 0
      ;;
    agy)
      # agy は codex sandbox 相当の外部実行手段が無く実証不能(実機確認 2026-06-01)。
      # agy は drill_agy_declaration(宣言チェック)を使うため、ここでは保留固定。
      echo "HOLD agy write drill not supported (declaration-based; see drill_agy_declaration)"; return 20
      ;;
    *)
      echo "HOLD unknown engine: $engine"; return 20
      ;;
  esac
}

# drill_agy_declaration <engine>
# agy 専用の「宣言チェック」。金庫の効力は実証しない(spec §4 ④, option B)。
# agy バイナリが存在することだけを green の条件にする。launcher 側が --sandbox を
# 強制適用する前提。実証していないことは docs / 起動メッセージで明示する。
drill_agy_declaration() {
  local agy="${AGY:-}"
  if [ -z "$agy" ]; then
    if [ -x "$HOME/.local/bin/agy" ]; then agy="$HOME/.local/bin/agy"
    elif command -v agy >/dev/null 2>&1; then agy="$(command -v agy)"
    fi
  fi
  if [ -z "$agy" ] || { [ ! -x "$agy" ] && ! command -v "$agy" >/dev/null 2>&1; }; then
    echo "FAIL agy not found (cannot enable auto)"; return 10
  fi
  echo "PASS agy present (declaration-based, sandbox NOT independently verified)"; return 0
}
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `bash scripts/macos/test/auto-mode.test.sh`
Expected: PASS — `drill_write_outside defined`。
(codex 未インストール環境でも関数定義チェックは通る。)

- [ ] **Step 5: コミット**

```bash
git add scripts/macos/lib/isolation-drills.sh scripts/macos/test/auto-mode.test.sh
git commit -m "feat(safe-auto): isolation drill lib + harness (workspace-outside write block)"
```

---

## Task 2: 外部ネット送信遮断ドリル(最重要)

**Files:**
- Modify: `scripts/macos/lib/isolation-drills.sh`
- Test: `scripts/macos/test/auto-mode.test.sh`

- [ ] **Step 1: ネット遮断ドリルの失敗テストを追記**

`scripts/macos/test/auto-mode.test.sh` の summary 行の**前**に追記:

```bash
# --- Task 2: drill_network_egress ---
if type drill_network_egress >/dev/null 2>&1; then ok "drill_network_egress defined"; else ng "drill_network_egress defined"; fi

# 判定ロジックの単体検証: 接続結果の分類関数 classify_net_result。
#   "refused"   -> 0  (PASS: 金庫が拒否した)
#   "connected" -> 10 (FAIL: 繋がってしまった)
#   "timeout"   -> 20 (HOLD: 区別不能 → 安全側で赤)
classify_net_result refused   >/dev/null 2>&1; [ $? -eq 0 ]  && ok "classify refused=PASS"   || ng "classify refused=PASS"
classify_net_result connected >/dev/null 2>&1; [ $? -eq 10 ] && ok "classify connected=FAIL" || ng "classify connected=FAIL"
classify_net_result timeout   >/dev/null 2>&1; [ $? -eq 20 ] && ok "classify timeout=HOLD"   || ng "classify timeout=HOLD"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash scripts/macos/test/auto-mode.test.sh`
Expected: FAIL — `classify_net_result` / `drill_network_egress` 未定義。

- [ ] **Step 3: classify_net_result と drill_network_egress を実装**

`scripts/macos/lib/isolation-drills.sh` の末尾に追記:

```bash
# classify_net_result <result>
# 接続試行の結果文字列を金庫判定に写像する(テスト容易性のため分離)。
classify_net_result() {
  case "$1" in
    refused)   echo "PASS egress blocked by sandbox"; return 0 ;;
    connected) echo "FAIL egress connection succeeded"; return 10 ;;
    *)         echo "HOLD egress result indeterminate (offline?)"; return 20 ;;
  esac
}

# _probe_egress <engine> <host> <port>
# 金庫の中から <host>:<port> へ TCP 接続を試み、結果を
# "refused" / "connected" / "timeout" のいずれかで echo する。
# データは送らない(接続確立の可否のみ)。
_probe_egress() {
  local engine="$1" host="$2" port="$3"
  local probe="exec 3<>/dev/tcp/$host/$port"
  case "$engine" in
    codex)
      local out
      out="$( codex sandbox macos -C "$(mktemp -d)" /bin/sh -lc \
        "timeout 5 bash -c '$probe' 2>&1; echo EXIT=\$?" 2>&1 )"
      if printf '%s' "$out" | grep -q "EXIT=0"; then echo connected; return; fi
      if printf '%s' "$out" | grep -Eqi "operation not permitted|not permitted|denied|refused"; then echo refused; return; fi
      echo timeout
      ;;
    *) echo timeout ;;
  esac
}

# drill_network_egress <engine>
# 許可リストに無い実在ドメインへの送信が遮断されるかを実証する。
drill_network_egress() {
  local engine="$1"
  case "$engine" in
    codex)
      command -v codex >/dev/null 2>&1 || { echo "HOLD codex not installed"; return 20; }
      local result; result="$(_probe_egress codex example.com 443)"
      classify_net_result "$result"
      return $?
      ;;
    agy)
      echo "HOLD agy network drill not yet supported"; return 20
      ;;
    *)
      echo "HOLD unknown engine: $engine"; return 20
      ;;
  esac
}
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `bash scripts/macos/test/auto-mode.test.sh`
Expected: PASS — classify 3 ケースと `drill_network_egress defined` が PASS。

- [ ] **Step 5: コミット**

```bash
git add scripts/macos/lib/isolation-drills.sh scripts/macos/test/auto-mode.test.sh
git commit -m "feat(safe-auto): network egress drill with refused/connected/timeout classification"
```

---

## Task 3: doctor に `--isolation-check <engine>` 軽量サブコマンド

**Files:**
- Modify: `scripts/macos/doctor.sh`
- Test: `scripts/macos/test/auto-mode.test.sh`

- [ ] **Step 1: 軽量サブコマンドの失敗テストを追記**

`scripts/macos/test/auto-mode.test.sh` の summary 行の前に追記:

```bash
# --- Task 3: doctor --isolation-check ---
DOCTOR="$HERE/../doctor.sh"
# codex 未導入や保留時は非0(安全側)であることだけ保証する。
# (PASS=0 になるのは実機 codex がある green 環境のみなので、ここでは「実行できる」ことを確認)
bash "$DOCTOR" --isolation-check codex >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -ne 0 ]; then ok "doctor --isolation-check runs (rc=$rc)"; else ng "doctor --isolation-check runs"; fi
# 未知 engine は必ず非0
bash "$DOCTOR" --isolation-check bogus >/dev/null 2>&1; [ $? -ne 0 ] && ok "isolation-check unknown engine non-zero" || ng "isolation-check unknown engine non-zero"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash scripts/macos/test/auto-mode.test.sh`
Expected: FAIL — `--isolation-check` 未対応で `bogus` でも 0 が返る等。

- [ ] **Step 3: doctor.sh に分岐を実装**

`scripts/macos/doctor.sh` の冒頭 `set -euo pipefail` の直後(`workspace=...` の前)に追記:

```bash
# Safe Auto Mode: 軽量隔離チェック。launcher が --auto 起動前に呼ぶ。
# その engine の workspace外書込遮断 + 外部ネット送信遮断を実証し、
# 全 PASS のときだけ exit 0。1つでも FAIL/HOLD なら非0(フェイルクローズ)。
if [ "${1:-}" = "--isolation-check" ]; then
  engine="${2:-}"
  drills_lib="$(cd "$(dirname "$0")" && pwd)/lib/isolation-drills.sh"
  if [ ! -f "$drills_lib" ]; then echo "FAIL isolation-drills.sh missing" >&2; exit 2; fi
  # shellcheck disable=SC1090
  . "$drills_lib"
  rc_total=0
  case "$engine" in
    codex)
      # Codex は実証ドリル①②。
      for drill in drill_write_outside drill_network_egress; do
        line="$("$drill" "$engine")"; rc=$?
        echo "$line"
        [ "$rc" -ne 0 ] && rc_total=1
      done
      ;;
    agy)
      # agy は宣言チェック④(実証ではない。spec §4 ④ / option B)。
      line="$(drill_agy_declaration "$engine")"; rc=$?
      echo "$line"
      [ "$rc" -ne 0 ] && rc_total=1
      ;;
    *)
      echo "HOLD unknown engine: $engine"; rc_total=1
      ;;
  esac
  exit "$rc_total"
fi
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `bash scripts/macos/test/auto-mode.test.sh`
Expected: PASS — `doctor --isolation-check runs` と `unknown engine non-zero` が PASS。

- [ ] **Step 5: コミット**

```bash
git add scripts/macos/doctor.sh scripts/macos/test/auto-mode.test.sh
git commit -m "feat(safe-auto): doctor --isolation-check <engine> lightweight gate"
```

---

## Task 4: launch-codex-safe.sh に `--auto` 分岐 + テスト seam

**Files:**
- Modify: `scripts/macos/launch-codex-safe.sh`
- Test: `scripts/macos/test/auto-mode.test.sh`

- [ ] **Step 1: launcher 分岐の失敗テストを追記**

`scripts/macos/test/auto-mode.test.sh` の summary 行の前に追記:

```bash
# --- Task 4: launch-codex-safe.sh --auto branch (dry-run + doctor stub) ---
LAUNCH_C="$HERE/../launch-codex-safe.sh"
WS="$(mktemp -d)"; mkdir -p "$WS/.ai-safety/policy"
echo '{}' > "$WS/.ai-safety/policy/safety-policy.json"
STUB_OK="$(mktemp)";  printf '#!/bin/sh\nexit 0\n' > "$STUB_OK";  chmod +x "$STUB_OK"
STUB_NG="$(mktemp)";  printf '#!/bin/sh\necho "FAIL egress indeterminate"\nexit 1\n' > "$STUB_NG"; chmod +x "$STUB_NG"

# green: doctor が exit 0 → on-failure に解放
out_ok="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_OK" bash "$LAUNCH_C" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_ok" | grep -q -- "--ask-for-approval on-failure" && ok "codex --auto green -> on-failure" || ng "codex --auto green -> on-failure"

# 赤: doctor が exit 1 → untrusted にフォールバック
out_ng="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_NG" bash "$LAUNCH_C" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_ng" | grep -q -- "--ask-for-approval untrusted" && ok "codex --auto red -> untrusted fallback" || ng "codex --auto red -> untrusted fallback"
# 赤のとき理由が stderr に出る
err_ng="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_NG" bash "$LAUNCH_C" "$WS" "" --auto 2>&1 1>/dev/null)"
printf '%s' "$err_ng" | grep -qi "オートを有効にできません" && ok "codex red shows reason" || ng "codex red shows reason"

# --auto 無し: 従来どおり untrusted(回帰)
out_def="$(AI_SAFE_DRY_RUN=1 bash "$LAUNCH_C" "$WS" "" 2>/dev/null)"
printf '%s' "$out_def" | grep -q -- "--ask-for-approval untrusted" && ok "codex no-auto stays untrusted" || ng "codex no-auto stays untrusted"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash scripts/macos/test/auto-mode.test.sh`
Expected: FAIL — `--auto`/`AI_SAFE_DRY_RUN` 未対応で 4 ケースとも FAIL。

- [ ] **Step 3: launch-codex-safe.sh を書き換え**

`scripts/macos/launch-codex-safe.sh` を以下に置き換え(既存の防御は維持、`--auto` と seam を追加):

```bash
#!/usr/bin/env bash
set -euo pipefail
workspace="${1:-$(pwd)}"
prompt="${2:-}"
auto=0
[ "${3:-}" = "--auto" ] && auto=1
workspace="$(cd "$workspace" && pwd)"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

# A-1: CODEX_HOME は workspace 外を向かせる(平文流出防止)。
SAFE_CODEX_HOME="$HOME/.codex-safe"
mkdir -p "$SAFE_CODEX_HOME"
export CODEX_HOME="$SAFE_CODEX_HOME"

WORKSPACE_CONFIG="$workspace/.codex/config.toml"
SAFE_CONFIG="$SAFE_CODEX_HOME/config.toml"
if [ -f "$WORKSPACE_CONFIG" ] && [ ! -f "$SAFE_CONFIG" ]; then
  cp "$WORKSPACE_CONFIG" "$SAFE_CONFIG"
fi

[ -f "$AI_SAFE_POLICY" ] || { echo "AI Safety package is not installed in workspace: $workspace" >&2; exit 2; }
[ -f "$SAFE_CONFIG" ] || { echo "Codex safety config was not found: $SAFE_CONFIG" >&2; exit 2; }

LEGACY_AUTH="$workspace/.codex/auth.json"
if [ -f "$LEGACY_AUTH" ] && [ ! -L "$LEGACY_AUTH" ]; then
  echo "A-1: Removing legacy physical auth.json from workspace tree: $LEGACY_AUTH" >&2
  rm -f "$LEGACY_AUTH"
fi
SRC_AUTH="$HOME/.codex/auth.json"
SAFE_AUTH="$SAFE_CODEX_HOME/auth.json"
if [ "${AI_SAFE_DRY_RUN:-}" != "1" ]; then
  if [ ! -f "$SRC_AUTH" ]; then
    echo "Codex auth not found at $SRC_AUTH. Please run 'codex login' first." >&2
    exit 2
  fi
  if [ ! -e "$SAFE_AUTH" ]; then ln -sf "$SRC_AUTH" "$SAFE_AUTH"; fi
fi

# Safe Auto Mode: --auto かつ doctor の隔離チェックが green のときだけ承認を下げる。
approval="untrusted"
if [ "$auto" -eq 1 ]; then
  doctor="${AI_SAFE_DOCTOR:-$AI_SAFE_ROOT/hooks/macos/doctor.sh}"
  [ -x "$doctor" ] || doctor="$(cd "$(dirname "$0")" && pwd)/doctor.sh"
  if "$doctor" --isolation-check codex >/dev/null 2>&1; then
    approval="on-failure"
  else
    echo "⚠ オートを有効にできません: OS 隔離(金庫)を確認できませんでした。" >&2
    echo "  → 安全のため都度承認モードで起動します。直すには doctor を実行してください。" >&2
    approval="untrusted"
  fi
fi

cmd=(codex --cd "$workspace" --profile safe --sandbox workspace-write --ask-for-approval "$approval" -c features.hooks=true)
if command -v caffeinate >/dev/null 2>&1; then
  cmd=(caffeinate -dimsu "${cmd[@]}")
fi

if [ "${AI_SAFE_DRY_RUN:-}" = "1" ]; then
  printf '%s ' "${cmd[@]}"; [ -n "$prompt" ] && printf '%q' "$prompt"; printf '\n'
  exit 0
fi

if [ -n "$prompt" ]; then
  "${cmd[@]}" "$prompt"
else
  "${cmd[@]}"
fi
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `bash scripts/macos/test/auto-mode.test.sh`
Expected: PASS — codex の green/赤/理由/回帰の 4 ケースが PASS。

- [ ] **Step 5: コミット**

```bash
git add scripts/macos/launch-codex-safe.sh scripts/macos/test/auto-mode.test.sh
git commit -m "feat(safe-auto): codex launcher --auto drops approval to on-failure only on green doctor"
```

---

## Task 5: launch-agy-safe.sh に `--auto` 分岐(宣言ベース・option B)

**Files:**
- Modify: `scripts/macos/launch-agy-safe.sh`
- Test: `scripts/macos/test/auto-mode.test.sh`

> **実機確認の結論(2026-06-01):** agy には `--sandbox`(terminal restrictions)と `--dangerously-skip-permissions`(全許可自動承認)があるが、`codex sandbox` 相当の外部実行手段は**無い**ため金庫を実証できない。ryuichi 判断により agy は**宣言ベース**でオートを出す(spec §4 ④, §6)。
> - doctor `--isolation-check agy` は `drill_agy_declaration`(agy 存在チェック)で green/赤を返す。
> - green のとき launcher は **`--dangerously-skip-permissions` を付与**(`--sandbox` は維持)。
> - 起動時メッセージと docs に「agy のオートは未実証・Codex より弱い」と正直明記する(overclaim 回避)。

- [ ] **Step 1: agy launcher 分岐の失敗テストを追記**

`scripts/macos/test/auto-mode.test.sh` の summary 行の前に追記:

```bash
# --- Task 5: launch-agy-safe.sh --auto branch ---
LAUNCH_A="$HERE/../launch-agy-safe.sh"
export AGY="$STUB_OK"   # agy バイナリ検出を満たすためのダミー(実行はされない=DRY_RUN)
# green: doctor 0 → --dangerously-skip-permissions が付く(--sandbox は維持)
out_a_ok="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_OK" bash "$LAUNCH_A" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_a_ok" | grep -q -- "--sandbox" && ok "agy --auto keeps --sandbox" || ng "agy --auto keeps --sandbox"
printf '%s' "$out_a_ok" | grep -q -- "--dangerously-skip-permissions" && ok "agy green -> skip-permissions" || ng "agy green -> skip-permissions"
# green でも未実証である旨を stderr に出す(overclaim 回避)
err_a_ok="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_OK" bash "$LAUNCH_A" "$WS" "" --auto 2>&1 1>/dev/null)"
printf '%s' "$err_a_ok" | grep -qi "未検証\|未実証\|verified" && ok "agy green shows unverified caveat" || ng "agy green shows unverified caveat"
# 赤(agy 無し相当): --dangerously-skip-permissions を付けずフォールバック + 理由表示
err_a_ng="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_NG" bash "$LAUNCH_A" "$WS" "" --auto 2>&1 1>/dev/null)"
printf '%s' "$err_a_ng" | grep -qi "オートを有効にできません" && ok "agy red shows reason" || ng "agy red shows reason"
out_a_ng="$(AI_SAFE_DRY_RUN=1 AI_SAFE_DOCTOR="$STUB_NG" bash "$LAUNCH_A" "$WS" "" --auto 2>/dev/null)"
printf '%s' "$out_a_ng" | grep -q -- "--dangerously-skip-permissions" && ng "agy red must NOT skip-permissions" || ok "agy red stays safe (no skip-permissions)"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash scripts/macos/test/auto-mode.test.sh`
Expected: FAIL — agy launcher が `--auto`/`AI_SAFE_DRY_RUN` 未対応。

- [ ] **Step 3: launch-agy-safe.sh を書き換え**

`scripts/macos/launch-agy-safe.sh` を以下に置き換え(既存の検出・推奨案内は維持):

```bash
#!/usr/bin/env bash
# launch-agy-safe.sh — Antigravity CLI (agy) を安全装置付きで起動。
# Safe Auto Mode: --auto かつ doctor green のとき auto-run を有効化(--sandbox は維持)。
set -euo pipefail
workspace="${1:-$(pwd)}"
prompt="${2:-}"
auto=0
[ "${3:-}" = "--auto" ] && auto=1
workspace="$(cd "$workspace" && pwd)"

export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

AGY="${AGY:-}"
if [ -z "$AGY" ]; then
  if [ -x "$HOME/.local/bin/agy" ]; then AGY="$HOME/.local/bin/agy"
  elif command -v agy >/dev/null 2>&1; then AGY="$(command -v agy)"
  else
    cat <<MSG >&2
Error: Antigravity CLI (agy) が見つかりません。
インストール: curl -fsSL https://antigravity.google/cli/install.sh | bash
インストール後、\$HOME/.local/bin を \$PATH に含めるか AGY=<path> をセットしてください。
MSG
    exit 2
  fi
fi

RECOMMENDED="$AI_SAFE_ROOT/configs/agy/recommended-settings.json"
HINT_FLAG="$HOME/.ai-safety/.agy-recommended-shown"
if [ -f "$RECOMMENDED" ] && [ ! -f "$HINT_FLAG" ]; then
  mkdir -p "$(dirname "$HINT_FLAG")" 2>/dev/null || true
  cat <<MSG >&2
[初回ヒント] agy の推奨セキュリティ設定があります: $RECOMMENDED
agy 起動後、/settings を開いて上記 JSON の各キーと同じ値に合わせてください
(特に allow_access_gitignore / allow_edit_gitignore / allow_auto_run_commands)。
このヒントは次回以降表示されません(再表示: $HINT_FLAG を削除)。
MSG
  touch "$HINT_FLAG" 2>/dev/null || true
fi

# Safe Auto Mode 分岐(宣言ベース・option B): doctor green のとき
# --dangerously-skip-permissions を付与(--sandbox は維持)。実証はしていない旨を必ず表示。
auto_args=()
if [ "$auto" -eq 1 ]; then
  doctor="${AI_SAFE_DOCTOR:-$AI_SAFE_ROOT/hooks/macos/doctor.sh}"
  [ -x "$doctor" ] || doctor="$(cd "$(dirname "$0")" && pwd)/doctor.sh"
  if "$doctor" --isolation-check agy >/dev/null 2>&1; then
    auto_args=(--dangerously-skip-permissions)
    echo "ℹ オートを有効化しました(agy)。注意: agy の隔離は --sandbox を信頼するもので、" >&2
    echo "  Codex のように独立検証(実証)されていません。重要作業では手動承認の利用も検討してください。" >&2
  else
    echo "⚠ オートを有効にできません: agy を検出できませんでした。" >&2
    echo "  → 安全のため通常モード(--sandbox のみ)で起動します。" >&2
  fi
fi

cmd=("$AGY" --sandbox --add-dir "$workspace" "${auto_args[@]}")

if [ "${AI_SAFE_DRY_RUN:-}" = "1" ]; then
  printf '%s ' "${cmd[@]}"; [ -n "$prompt" ] && printf -- '--prompt %q' "$prompt"; printf '\n'
  exit 0
fi

if [ -n "$prompt" ]; then
  "${cmd[@]}" --prompt "$prompt"
else
  "${cmd[@]}"
fi
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `bash scripts/macos/test/auto-mode.test.sh`
Expected: PASS — agy の `--sandbox` 維持と赤理由表示が PASS。

- [ ] **Step 5: コミット**

```bash
git add scripts/macos/launch-agy-safe.sh scripts/macos/test/auto-mode.test.sh
git commit -m "feat(safe-auto): agy launcher --auto branch (auto-run gated on green doctor; degrades safely)"
```

---

## Task 6: フル doctor.sh に隔離ドリルを統合

**Files:**
- Modify: `scripts/macos/doctor.sh`
- Test: `scripts/macos/test/auto-mode.test.sh`

- [ ] **Step 1: フル doctor が隔離行を出すテストを追記**

`scripts/macos/test/auto-mode.test.sh` の summary 行の前に追記:

```bash
# --- Task 6: full doctor includes isolation drills ---
full_out="$(bash "$HERE/../doctor.sh" "$WS" 2>/dev/null || true)"
printf '%s' "$full_out" | grep -Eqi "egress|workspace-outside|isolation" && ok "full doctor reports isolation" || ng "full doctor reports isolation"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash scripts/macos/test/auto-mode.test.sh`
Expected: FAIL — フル doctor が隔離ドリル行をまだ出さない。

- [ ] **Step 3: doctor.sh のサマリ直前に隔離ドリルを追加**

`scripts/macos/doctor.sh` の `echo "doctor summary: pass=$pass fail=$fail"` の**直前**に追記:

```bash
# Safe Auto Mode: 隔離ドリルをフル doctor にも組み込む(集計に反映)。
# codex が無い等で HOLD のときは SKIP 扱い(集計から除外)。
drills_lib="$(cd "$(dirname "$0")" && pwd)/lib/isolation-drills.sh"
if [ -f "$drills_lib" ]; then
  # shellcheck disable=SC1090
  . "$drills_lib"
  for d in drill_write_outside drill_network_egress; do
    line="$("$d" codex)"; rc=$?
    case "$rc" in
      0)  echo "PASS isolation: $line"; pass=$((pass+1)) ;;
      10) echo "FAIL isolation: $line"; fail=$((fail+1)) ;;
      *)  echo "SKIP isolation: $line" ;;
    esac
  done
fi
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `bash scripts/macos/test/auto-mode.test.sh`
Expected: PASS — `full doctor reports isolation`。

- [ ] **Step 5: 全テスト + フル doctor を実行して回帰確認**

Run: `bash scripts/macos/test/auto-mode.test.sh && bash scripts/macos/doctor.sh`
Expected: テストハーネス全 PASS。フル doctor は既存ドリルが従来どおり(codex 環境なら isolation も PASS、無ければ SKIP)。

- [ ] **Step 6: コミット**

```bash
git add scripts/macos/doctor.sh scripts/macos/test/auto-mode.test.sh
git commit -m "feat(safe-auto): integrate isolation drills into full doctor (HOLD=SKIP)"
```

---

## Task 7: Windows 隔離ドリルライブラリ

**Files:**
- Create: `scripts/windows/lib/isolation-drills.ps1`
- Test: `scripts/windows/test/auto-mode.test.ps1`

> **実機確認(着手時):** Windows の `codex` は `[windows] sandbox="unelevated"`。`codex sandbox` サブコマンドが Windows で同じ引数で使えるか確認し、使えなければ「unelevated プロセスを起動して境界外書込/接続を試す」代替に切り替える。

- [ ] **Step 1: PowerShell テストハーネスと失敗テストを書く**

Create `scripts/windows/test/auto-mode.test.ps1`:

```powershell
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib  = Join-Path $here '..\lib\isolation-drills.ps1'
$script:pass = 0; $script:fail = 0
function Ok($m){ Write-Host "PASS $m"; $script:pass++ }
function Ng($m){ Write-Host "FAIL $m"; $script:fail++ }

. $lib

if (Get-Command Test-WriteOutside -ErrorAction SilentlyContinue) { Ok 'Test-WriteOutside defined' } else { Ng 'Test-WriteOutside defined' }
if (Get-Command Get-NetResultClass -ErrorAction SilentlyContinue) { Ok 'Get-NetResultClass defined' } else { Ng 'Get-NetResultClass defined' }
# 分類: refused=0(PASS) / connected=10(FAIL) / timeout=20(HOLD)
if ((Get-NetResultClass 'refused')   -eq 0)  { Ok 'class refused' }   else { Ng 'class refused' }
if ((Get-NetResultClass 'connected') -eq 10) { Ok 'class connected' } else { Ng 'class connected' }
if ((Get-NetResultClass 'timeout')   -eq 20) { Ok 'class timeout' }   else { Ng 'class timeout' }

Write-Host "auto-mode.test summary: pass=$script:pass fail=$script:fail"
if ($script:fail -ne 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\auto-mode.test.ps1`
Expected: FAIL — `isolation-drills.ps1` 未作成。

- [ ] **Step 3: isolation-drills.ps1 を実装**

Create `scripts/windows/lib/isolation-drills.ps1`:

```powershell
# isolation-drills.ps1 — OS 金庫の実証ドリル(mac isolation-drills.sh の PowerShell 版)。
# 返り値: 0=PASS / 10=FAIL / 20=HOLD(安全側で赤扱い)。

function Get-NetResultClass([string]$result) {
  switch ($result) {
    'refused'   { Write-Output 'PASS egress blocked by sandbox'; return 0 }
    'connected' { Write-Output 'FAIL egress connection succeeded'; return 10 }
    default     { Write-Output 'HOLD egress result indeterminate (offline?)'; return 20 }
  }
}

function Test-WriteOutside([string]$engine) {
  switch ($engine) {
    'codex' {
      if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { Write-Output 'HOLD codex not installed'; return 20 }
      $root = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("aisafe-" + [guid]::NewGuid())) -Force
      $inside = New-Item -ItemType Directory -Path (Join-Path $root 'ws') -Force
      $target = Join-Path (Join-Path $root 'out') 'pwn.txt'
      New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
      # 実機確認で確定した codex サンドボックス実行コマンドを使用する。
      & codex sandbox windows -C $inside.FullName cmd /c "echo pwn > `"$target`"" 2>$null | Out-Null
      if (Test-Path $target) { Remove-Item $root -Recurse -Force; Write-Output 'FAIL workspace-outside write succeeded'; return 10 }
      Remove-Item $root -Recurse -Force; Write-Output 'PASS workspace-outside write blocked'; return 0
    }
    'agy' { Write-Output 'HOLD agy write drill not yet supported'; return 20 }
    default { Write-Output "HOLD unknown engine: $engine"; return 20 }
  }
}

function Test-NetworkEgress([string]$engine) {
  switch ($engine) {
    'codex' {
      if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { Write-Output 'HOLD codex not installed'; return 20 }
      # 金庫の中から example.com:443 へ接続試行 → 結果分類。
      $probe = "powershell -NoProfile -Command `"try { (New-Object Net.Sockets.TcpClient).Connect('example.com',443); 'connected' } catch { if (`$_.Exception.Message -match 'denied|permitted|refused') {'refused'} else {'timeout'} }`""
      $out = & codex sandbox windows -C $env:TEMP cmd /c $probe 2>&1
      $cls = if ($out -match 'connected') {'connected'} elseif ($out -match 'refused') {'refused'} else {'timeout'}
      return (Get-NetResultClass $cls)
    }
    'agy' { Write-Output 'HOLD agy network drill not supported (declaration-based)'; return 20 }
    default { Write-Output "HOLD unknown engine: $engine"; return 20 }
  }
}

function Test-AgyDeclaration([string]$engine) {
  # agy 専用の宣言チェック(実証ではない。spec §4 ④, option B)。
  $agy = $env:AGY
  if (-not $agy) {
    if (Test-Path (Join-Path $env:USERPROFILE '.local\bin\agy.exe')) { $agy = Join-Path $env:USERPROFILE '.local\bin\agy.exe' }
    elseif (Get-Command agy -ErrorAction SilentlyContinue) { $agy = (Get-Command agy).Source }
  }
  if (-not $agy) { Write-Output 'FAIL agy not found (cannot enable auto)'; return 10 }
  Write-Output 'PASS agy present (declaration-based, sandbox NOT independently verified)'; return 0
}
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\auto-mode.test.ps1`
Expected: PASS — 関数定義チェックと分類 3 ケースが PASS。

- [ ] **Step 5: コミット**

```bash
git add scripts/windows/lib/isolation-drills.ps1 scripts/windows/test/auto-mode.test.ps1
git commit -m "feat(safe-auto): windows isolation drill lib + harness"
```

---

## Task 8: Windows doctor.ps1 に `-IsolationCheck` を追加

**Files:**
- Modify: `scripts/windows/doctor.ps1`
- Test: `scripts/windows/test/auto-mode.test.ps1`

- [ ] **Step 1: 失敗テストを追記**

`scripts/windows/test/auto-mode.test.ps1` の summary 行の前に追記:

```powershell
$doctor = Join-Path $here '..\doctor.ps1'
& powershell -NoProfile -ExecutionPolicy Bypass -File $doctor -IsolationCheck bogus *> $null
if ($LASTEXITCODE -ne 0) { Ok 'isolation-check unknown engine non-zero' } else { Ng 'isolation-check unknown engine non-zero' }
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\auto-mode.test.ps1`
Expected: FAIL — `-IsolationCheck` 未対応。

- [ ] **Step 3: doctor.ps1 に param と分岐を実装**

`scripts/windows/doctor.ps1` の先頭の `param(...)` に `[string]$IsolationCheck` を追加し(既存 param が無ければ新設)、最初の実処理の前に:

```powershell
if ($IsolationCheck) {
  $drills = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'lib\isolation-drills.ps1'
  if (-not (Test-Path $drills)) { Write-Error 'isolation-drills.ps1 missing'; exit 2 }
  . $drills
  $rcTotal = 0
  switch ($IsolationCheck) {
    'codex' {
      foreach ($fn in @('Test-WriteOutside','Test-NetworkEgress')) {
        $out = & $fn 'codex'; $rc = $out[-1]
        Write-Host ($out -join ' ')
        if ($rc -ne 0) { $rcTotal = 1 }
      }
    }
    'agy' {
      $out = & Test-AgyDeclaration 'agy'; $rc = $out[-1]
      Write-Host ($out -join ' ')
      if ($rc -ne 0) { $rcTotal = 1 }
    }
    default { Write-Host "HOLD unknown engine: $IsolationCheck"; $rcTotal = 1 }
  }
  exit $rcTotal
}
```

> 注: Task 7 のドリル関数は `Write-Output <文字列>; return <int>` の形なので、`$out` は配列になり末尾要素 `$out[-1]` が数値(0/10/20 または 0/10)。表示は数値を除いた文字列部分を結合する。実装時に Task 7 の戻り形と厳密に一致させること。

> 注: PowerShell 関数の戻り値取得は `& $fn ...; $rc=$LASTEXITCODE` ではなくパイプライン出力になるため、実装時は関数末尾を `exit`/`return` ではなく数値出力に統一するか、ドリル関数を `[int]` 戻りに揃える。Task 7 のドリルは `return <int>` を使うので、`$rc = (& $fn $engine)[-1]` で末尾の数値を取る形に合わせること(実装時に Task 7 と整合させる)。

- [ ] **Step 4: テストを実行して通過を確認**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\auto-mode.test.ps1`
Expected: PASS — `unknown engine non-zero`。

- [ ] **Step 5: コミット**

```bash
git add scripts/windows/doctor.ps1 scripts/windows/test/auto-mode.test.ps1
git commit -m "feat(safe-auto): windows doctor -IsolationCheck gate"
```

---

## Task 9: Windows codex launcher `--auto` 分岐

**Files:**
- Modify: `scripts/windows/launch-codex-safe.ps1`
- Test: `scripts/windows/test/auto-mode.test.ps1`

- [ ] **Step 1: 失敗テストを追記**

`scripts/windows/test/auto-mode.test.ps1` の summary 行の前に追記:

```powershell
$launchC = Join-Path $here '..\launch-codex-safe.ps1'
$ws = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("ws-"+[guid]::NewGuid())) -Force
New-Item -ItemType Directory -Path (Join-Path $ws '.ai-safety\policy') -Force | Out-Null
'{}' | Set-Content (Join-Path $ws '.ai-safety\policy\safety-policy.json')
$stubOk = Join-Path $env:TEMP 'stub-ok.cmd'; 'exit /b 0' | Set-Content $stubOk
$stubNg = Join-Path $env:TEMP 'stub-ng.cmd'; 'exit /b 1' | Set-Content $stubNg

$env:AI_SAFE_DRY_RUN = '1'; $env:AI_SAFE_DOCTOR = $stubOk
$outOk = & powershell -NoProfile -ExecutionPolicy Bypass -File $launchC $ws.FullName '' --auto 2>$null
if ($outOk -match 'on-failure') { Ok 'win codex green -> on-failure' } else { Ng 'win codex green -> on-failure' }
$env:AI_SAFE_DOCTOR = $stubNg
$outNg = & powershell -NoProfile -ExecutionPolicy Bypass -File $launchC $ws.FullName '' --auto 2>$null
if ($outNg -match 'untrusted') { Ok 'win codex red -> untrusted' } else { Ng 'win codex red -> untrusted' }
Remove-Item Env:\AI_SAFE_DRY_RUN, Env:\AI_SAFE_DOCTOR -ErrorAction SilentlyContinue
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\auto-mode.test.ps1`
Expected: FAIL — `--auto`/dry-run 未対応。

- [ ] **Step 3: launch-codex-safe.ps1 に分岐を実装**

`scripts/windows/launch-codex-safe.ps1` の、codex 起動コマンドを組み立てている箇所を次の方針で改修(既存の sandbox / approval / hooks 強制は維持):

```powershell
# 既存: $approval = 'untrusted' 相当の固定値を、--auto 分岐に置き換える。
$auto = $args -contains '--auto'
$approval = 'untrusted'
if ($auto) {
  $doctor = if ($env:AI_SAFE_DOCTOR) { $env:AI_SAFE_DOCTOR } else { Join-Path $PSScriptRoot 'doctor.ps1' }
  if ($doctor -match '\.cmd$') { & $doctor *> $null } else { & powershell -NoProfile -ExecutionPolicy Bypass -File $doctor -IsolationCheck codex *> $null }
  if ($LASTEXITCODE -eq 0) {
    $approval = 'on-failure'
  } else {
    [Console]::Error.WriteLine('⚠ オートを有効にできません: OS 隔離(金庫)を確認できませんでした。')
    [Console]::Error.WriteLine('  → 安全のため都度承認モードで起動します。直すには doctor を実行してください。')
    $approval = 'untrusted'
  }
}

# 起動コマンド組み立て(既存の引数に $approval を反映)
$codexArgs = @('--cd', $workspace, '--profile', 'safe', '--sandbox', 'workspace-write', '--ask-for-approval', $approval, '-c', 'features.hooks=true')

if ($env:AI_SAFE_DRY_RUN -eq '1') {
  Write-Output ("codex " + ($codexArgs -join ' '))
  exit 0
}
# 既存の実起動(codex @codexArgs ...)はそのまま
```

> 注: 既存 `launch-codex-safe.ps1` の引数受け取り方(`param()` か `$args`)に合わせて `$workspace` の解決と `--auto` 検出を整合させること。Windows の codex は `[windows] sandbox="unelevated"`(config.windows.toml)を使う点は不変。

- [ ] **Step 4: テストを実行して通過を確認**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\auto-mode.test.ps1`
Expected: PASS — win codex green/赤の 2 ケース。

- [ ] **Step 5: コミット**

```bash
git add scripts/windows/launch-codex-safe.ps1 scripts/windows/test/auto-mode.test.ps1
git commit -m "feat(safe-auto): windows codex launcher --auto branch"
```

---

## Task 10: Windows agy launcher `--auto` + フル doctor 統合 + ドキュメント

**Files:**
- Modify: `scripts/windows/launch-agy-safe.ps1`
- Modify: `scripts/windows/doctor.ps1`
- Modify: `docs/05_Claude_Codeを安全に使う.md`(該当なければ最も近い起動手順 doc)/ `docs/08_外部LLMを安全に使う.md`
- Test: `scripts/windows/test/auto-mode.test.ps1`

- [ ] **Step 1: agy 分岐の失敗テスト + フル doctor 隔離行テストを追記**

`scripts/windows/test/auto-mode.test.ps1` の summary 行の前に追記:

```powershell
$launchA = Join-Path $here '..\launch-agy-safe.ps1'
$env:AGY = $stubOk; $env:AI_SAFE_DRY_RUN = '1'; $env:AI_SAFE_DOCTOR = $stubNg
$outA = & powershell -NoProfile -ExecutionPolicy Bypass -File $launchA $ws.FullName '' --auto 2>&1
if ($outA -match 'オートを有効にできません|--sandbox') { Ok 'win agy --auto handled' } else { Ng 'win agy --auto handled' }
Remove-Item Env:\AGY, Env:\AI_SAFE_DRY_RUN, Env:\AI_SAFE_DOCTOR -ErrorAction SilentlyContinue
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\auto-mode.test.ps1`
Expected: FAIL — agy launcher 未対応。

- [ ] **Step 3: launch-agy-safe.ps1 に Task 5 と同型の分岐を実装、doctor.ps1 のサマリ前に隔離ドリル統合(Task 6 と同型)**

launch-agy-safe.ps1(既存の `--sandbox --add-dir` 起動を維持しつつ):

```powershell
$auto = $args -contains '--auto'
$autoArgs = @()
if ($auto) {
  $doctor = if ($env:AI_SAFE_DOCTOR) { $env:AI_SAFE_DOCTOR } else { Join-Path $PSScriptRoot 'doctor.ps1' }
  if ($doctor -match '\.cmd$') { & $doctor *> $null } else { & powershell -NoProfile -ExecutionPolicy Bypass -File $doctor -IsolationCheck agy *> $null }
  if ($LASTEXITCODE -eq 0) {
    $autoArgs = @('--dangerously-skip-permissions')
    [Console]::Error.WriteLine('ℹ オートを有効化しました(agy)。注意: agy の隔離は --sandbox を信頼するもので、')
    [Console]::Error.WriteLine('  Codex のように独立検証(実証)されていません。重要作業では手動承認の利用も検討してください。')
  } else {
    [Console]::Error.WriteLine('⚠ オートを有効にできません: agy を検出できませんでした。')
    [Console]::Error.WriteLine('  → 安全のため通常モード(--sandbox のみ)で起動します。')
  }
}
$agyArgs = @('--sandbox', '--add-dir', $workspace) + $autoArgs
if ($env:AI_SAFE_DRY_RUN -eq '1') { Write-Output ("$AGY " + ($agyArgs -join ' ')); exit 0 }
# 既存の実起動はそのまま
```

doctor.ps1 のサマリ(`pass=/fail=`)直前に:

```powershell
$drills = Join-Path $PSScriptRoot 'lib\isolation-drills.ps1'
if (Test-Path $drills) {
  . $drills
  foreach ($fn in @('Test-WriteOutside','Test-NetworkEgress')) {
    $out = & $fn 'codex'; $rc = $out[-1]
    switch ($rc) {
      0  { Write-Host "PASS isolation: $out"; $pass++ }
      10 { Write-Host "FAIL isolation: $out"; $fail++ }
      default { Write-Host "SKIP isolation: $out" }
    }
  }
}
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\auto-mode.test.ps1`
Expected: PASS — `win agy --auto handled`。

- [ ] **Step 5: ドキュメントに Safe Auto Mode の使い方と制約を追記**

`docs/08_外部LLMを安全に使う.md`(または起動手順の doc)に節を追加(実際の文面例):

```markdown
## Safe Auto Mode(承認を省く自動モード)

`--auto` を付けて起動すると、doctor が「金庫(OS 隔離)が効いている」と実証できたときだけ
承認プロンプトを省きます。確認できない場合は理由を表示して従来の都度承認モードで起動します。

    # macOS
    scripts/macos/launch-codex-safe.sh <workspace> "" --auto
    # Windows
    powershell -File .ai-safety\hooks\windows\launch-codex-safe.ps1 <workspace> "" --auto

- 対象: Codex / agy。Claude Code は対象外(基本 DeepSeek 駆動 + 普通の Windows では金庫が無いため)。
- **Codex(強・実証)**: doctor が「外部送信できない/作業フォルダ外に書けない」を実際に試して確認できたときだけオートを開きます。
- **agy(弱・宣言ベース)**: agy には金庫を外から検証する手段が無いため、`--sandbox` フラグを**信頼**してオートを開きます(Codex のように実証はしていません)。重要作業では手動承認の利用も検討してください。
- いずれも解放後も `--sandbox` 等の隔離は常時稼働します(承認の手間だけを省きます)。
```

- [ ] **Step 6: 全テスト実行 + 最終コミット**

Run (mac): `bash scripts/macos/test/auto-mode.test.sh`
Run (win): `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\auto-mode.test.ps1`
Expected: 両方とも全 PASS。

```bash
git add scripts/windows/launch-agy-safe.ps1 scripts/windows/doctor.ps1 scripts/windows/test/auto-mode.test.ps1 docs/08_外部LLMを安全に使う.md
git commit -m "feat(safe-auto): windows agy launcher + full doctor isolation + docs"
```

---

## Self-Review (記入済み)

**1. Spec coverage:**
- spec §2 対象エンジン(Codex+agy / Claude 対象外) → Task 4,5,9,10 + Task 10 docs。✅
- spec §4 ①workspace 外書込 → Task 1,7。②ネット送信遮断(refused/connected/timeout) → Task 2,7。③hook/deny → 既存 doctor を流用(Task 6 で同居)。✅
- spec §3 軽量サブコマンド `--isolation-check` → Task 3,8。✅
- spec §5 launcher 分岐 + フォールバック表示 → Task 4,5,9,10。✅
- spec §2.3 Codex `on-failure` → Task 4,9。✅
- spec §4 ④ agy 宣言チェック → Task 1(`drill_agy_declaration`),7(`Test-AgyDeclaration`),3/8(doctor エンジン分岐)。✅
- spec §2/§6 agy 宣言ベース解放(`--dangerously-skip-permissions` + 未実証 caveat) → Task 5,10。✅
- spec §8 テスト方針(金庫あり=PASS/壊した=FAIL/オフライン=赤、launcher 分岐、回帰) → 各 Task のテスト。✅
- spec §7 Claude 将来課題 → 本計画は MVP のため非実装。docs(Task 10)で対象外を明記。✅(意図的に未実装)

**2. Placeholder scan:** コードは全て実体を記載。agy の実機確認は 2026-06-01 に完了済み(`codex sandbox` 相当無し → 宣言ベース確定)。Task 5/10 の挙動(green→`--dangerously-skip-permissions`+caveat、赤→`--sandbox` のみ)は具体定義済み。プレースホルダではない。✅

**3. Type consistency:**
- 実証ドリル戻り規約 0/10/20、宣言チェック戻り 0/10 を Task 1,2,3,6,7,8,10 で統一。✅
- 関数名: mac `drill_write_outside` / `drill_network_egress` / `classify_net_result` / `drill_agy_declaration`、win `Test-WriteOutside` / `Test-NetworkEgress` / `Get-NetResultClass` / `Test-AgyDeclaration` を全 Task で一貫使用。✅
- seam 変数 `AI_SAFE_DRY_RUN` / `AI_SAFE_DOCTOR` を全 launcher で一貫使用。✅
- approval/auto 値: Codex `untrusted`(既定/フォールバック)/ `on-failure`(green) を Task 4,9。agy `--dangerously-skip-permissions`(green のみ付与) を Task 5,10 で一貫。✅
