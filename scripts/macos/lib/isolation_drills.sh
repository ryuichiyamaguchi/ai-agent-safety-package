#!/usr/bin/env bash
# isolation_drills.sh — OS 金庫(サンドボックス)が実際に効いているかを
# 実証検証するドリル群。doctor.sh と test から source される。
# 返り値の約束:
#   0   = PASS (金庫が効いている = 該当の遮断が実証できた)
#   10  = FAIL (金庫に穴 = 遮断できなかった)
#   20  = 保留 (効力を実証できない。安全側で「赤」扱いにすること)
# 標準出力に "PASS/FAIL/HOLD <理由>" を 1 行出す(launcher のフォールバック表示に使う)。
set -u

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
      # codex サブシェルの終了コードを捕捉する(起動失敗と書込ブロックを区別するため)。
      local codex_rc
      ( codex sandbox macos -C "$inside" /bin/sh -lc "echo pwn > '$target'" ) >/dev/null 2>&1
      codex_rc=$?
      # target が実際に作られたら金庫に穴 = FAIL。
      if [ -e "$target" ]; then rm -rf "$root"; echo "FAIL workspace-outside write succeeded"; return 10; fi
      # target 未作成 かつ codex が非0終了 = サンドボックス自体が起動できなかった可能性
      # (誤フラグ/ライセンス/バイナリ異常等)。書込ブロックを実証できていないので保守的に HOLD。
      if [ "$codex_rc" -ne 0 ]; then rm -rf "$root"; echo "HOLD codex sandbox did not run cleanly (rc=$codex_rc); write block not proven"; return 20; fi
      # target 未作成 かつ codex 正常終了 = 内側 sh が走った上で書込が遮断された = PASS。
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
  [ "${1:-}" = "agy" ] || { echo "HOLD drill_agy_declaration called for wrong engine: ${1:-}"; return 20; }
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
      local out tmp
      tmp="$(mktemp -d)"
      out="$( codex sandbox macos -C "$tmp" /bin/sh -lc \
        "timeout 5 bash -c '$probe' 2>&1; echo EXIT=\$?" 2>&1 )"
      rm -rf "$tmp"
      if printf '%s' "$out" | grep -qE "EXIT=0$"; then echo connected; return; fi
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
