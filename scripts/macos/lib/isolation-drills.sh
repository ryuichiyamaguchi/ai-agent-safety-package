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
