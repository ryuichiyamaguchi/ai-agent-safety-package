#!/usr/bin/env bash
# isolation_drills.sh — OS 金庫(サンドボックス)が実際に効いているかを
# 実証検証するドリル群。doctor.sh と test から source される。
# 返り値の約束:
#   0   = PASS (金庫が効いている = 該当の遮断が実証できた)
#   10  = FAIL (金庫に穴 = 遮断できなかった)
#   20  = 保留 (効力を実証できない。安全側で「赤」扱いにすること)
# 標準出力に "PASS/FAIL/HOLD <理由>" を 1 行出す(launcher のフォールバック表示に使う)。
set -u

# ── codex 0.135 系の sandbox 検証用ヘルパ ──────────────────────────────
# 0.135 で `codex sandbox` の構文が変わった(旧 `codex sandbox macos` は動かない):
#   codex sandbox --permissions-profile <NAME> -C <DIR> <COMMAND...>
# `--permissions-profile` は必須で、[permissions.<NAME>] テーブルを持つ config が要る。
# 正しいスキーマは sandbox_mode/network_access ではなく extends/network.enabled:
#   [permissions.safeprobe]
#   extends = ":workspace"            # cwd の workspace root を書込可能にする
#   [permissions.safeprobe.network]
#   enabled = false                   # ネットワーク遮断
# ユーザーの config に依存しないよう、ドリル専用の一時 CODEX_HOME を都度生成する。
#
# 重要な実測事実(macOS seatbelt, codex-cli 0.135.0):
#   - workspace-write 相当では cwd の workspace root に加えて /tmp と $TMPDIR が
#     常に書込可能になる(profile では除外しきれない)。よって outside-write の
#     プローブ先は /tmp・$TMPDIR・workspace のいずれでもない実パスにする必要がある
#     (= $HOME 配下の専用ディレクトリ)。
#   - inside-write は rc=0 でファイルが作られる。
#   - outside-write は "Operation not permitted" で rc!=0、ファイルは作られない。
#   - network 遮断時は perl の TCP connect が "Invalid argument" 等で失敗(rc!=0)。
#     許可時は CONNECTED で rc=0(= プローブが本物である裏取り)。

# _codex_probe_home — ドリル専用の一時 CODEX_HOME を作り、safeprobe プロファイルを
# 書き込んでそのパスを echo する。失敗時は空文字を返す。
_codex_probe_home() {
  local home
  home="$(mktemp -d 2>/dev/null)" || return 1
  cat > "$home/config.toml" <<'EOF'
[permissions.safeprobe]
description = "Safe Auto Mode isolation drill: workspace write, network blocked"
extends = ":workspace"

[permissions.safeprobe.network]
enabled = false
EOF
  printf '%s' "$home"
}

# drill_write_outside <engine>
# 金庫の中から (a) workspace 内書込が成功し、(b) workspace 外書込が遮断される
# ことを両方実証する。両立して初めて PASS。
drill_write_outside() {
  local engine="$1"
  case "$engine" in
    codex)
      command -v codex >/dev/null 2>&1 || { echo "HOLD codex not installed"; return 20; }
      local probe_home; probe_home="$(_codex_probe_home)" || { echo "HOLD could not create probe CODEX_HOME"; return 20; }

      # inside = git リポジトリにして :workspace が cwd を正確に workspace root と解決するようにする。
      local inside; inside="$(mktemp -d 2>/dev/null)" || { rm -rf "$probe_home"; echo "HOLD could not create inside dir"; return 20; }
      ( cd "$inside" && git init -q >/dev/null 2>&1 )

      # outside = /tmp・$TMPDIR・workspace のいずれでもない実パス($HOME 配下の専用ディレクトリ)。
      # workspace-write では /tmp と $TMPDIR が常に書込可能なため、それらは outside に使えない。
      local out_base="$HOME/.ai-safety/.sbprobe-out.$$"
      rm -rf "$out_base"
      mkdir -p "$out_base" 2>/dev/null || { rm -rf "$probe_home" "$inside"; echo "HOLD could not create outside dir under \$HOME"; return 20; }
      local inside_file="$inside/in.txt"
      local outside_file="$out_base/pwn.txt"

      # (a) inside-write
      local in_rc out_rc
      CODEX_HOME="$probe_home" codex sandbox --permissions-profile safeprobe -C "$inside" /usr/bin/touch "$inside_file" >/dev/null 2>&1
      in_rc=$?
      # (b) outside-write
      CODEX_HOME="$probe_home" codex sandbox --permissions-profile safeprobe -C "$inside" /usr/bin/touch "$outside_file" >/dev/null 2>&1
      out_rc=$?

      local inside_created=0 outside_created=0
      [ -e "$inside_file" ] && inside_created=1
      [ -e "$outside_file" ] && outside_created=1

      # outside が作られた = 金庫に穴 = FAIL(最優先で検出)。
      if [ "$outside_created" -eq 1 ]; then
        rm -rf "$probe_home" "$inside" "$out_base"
        echo "FAIL workspace-outside write succeeded (sandbox leak)"; return 10
      fi
      # inside が作られていない = サンドボックス自体が正常作業できていない(起動失敗/abort 等)。
      # 「正常作業ができる金庫」を実証できていないので保守的に HOLD。
      if [ "$inside_created" -ne 1 ]; then
        rm -rf "$probe_home" "$inside" "$out_base"
        echo "HOLD inside-write did not succeed (rc=$in_rc); cannot prove a working sandbox"; return 20
      fi
      # outside-write は遮断されるべき(rc!=0 が期待)。万一 rc=0 で抜けたのにファイルが無い等の
      # 不可解ケースは保守的に HOLD。
      if [ "$out_rc" -eq 0 ]; then
        rm -rf "$probe_home" "$inside" "$out_base"
        echo "HOLD outside-write exited 0 but no file (indeterminate)"; return 20
      fi
      rm -rf "$probe_home" "$inside" "$out_base"
      echo "PASS inside-write ok AND outside-write blocked"; return 0
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
# データは送らない(接続確立の可否のみ)。perl は macOS 標準で sandbox PATH 上にある。
_probe_egress() {
  local engine="$1" host="$2" port="$3"
  case "$engine" in
    codex)
      local probe_home; probe_home="$(_codex_probe_home)" || { echo timeout; return; }
      local inside; inside="$(mktemp -d 2>/dev/null)" || { rm -rf "$probe_home"; echo timeout; return; }
      ( cd "$inside" && git init -q >/dev/null 2>&1 )
      # perl で TCP connect(6 秒 alarm)。CONNECTED=接続成功 / REFUSED=拒否 / TIMEOUT=判定不能。
      local perl_probe out
      perl_probe='use IO::Socket::INET;$SIG{ALRM}=sub{print "TIMEOUT\n";exit 2};alarm(6);'
      perl_probe="${perl_probe}my \$s=IO::Socket::INET->new(PeerAddr=>\"$host\",PeerPort=>$port,Proto=>\"tcp\");"
      perl_probe="${perl_probe}if(\$s){print \"CONNECTED\\n\";exit 0}else{print \"REFUSED \$!\\n\";exit 1}"
      out="$( CODEX_HOME="$probe_home" codex sandbox --permissions-profile safeprobe -C "$inside" /usr/bin/perl -e "$perl_probe" 2>&1 )"
      rm -rf "$probe_home" "$inside"
      if printf '%s' "$out" | grep -q "CONNECTED"; then echo connected; return; fi
      if printf '%s' "$out" | grep -q "REFUSED"; then echo refused; return; fi
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
