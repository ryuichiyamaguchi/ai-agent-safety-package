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
# probe 用 config にはネット遮断(safeprobe / netblock)と疎通基準(netbaseline)の
# 両プロファイルを書き込み、network ドリルのベースライン疎通確認に使う。
#
# 重要な実測事実(macOS seatbelt, codex-cli 0.135.0):
#   - workspace-write 相当では cwd の workspace root に加えて /tmp と $TMPDIR が
#     常に書込可能になる(profile では除外しきれない)。よって outside-write の
#     プローブ先は /tmp・$TMPDIR・workspace のいずれでもない実パスにする必要がある
#     (= $HOME 配下の専用ディレクトリ)。
#   - inside-write は rc=0 でファイルが作られる。
#   - outside-write は "Operation not permitted" で rc!=0、ファイルは作られない。
#   - network 遮断時は perl の TCP connect が "Operation not permitted" 等で失敗(rc!=0)。
#     許可時(enabled=true)は CONNECTED で rc=0(= プローブが本物である裏取り)。
#   - 宛先は DNS 失敗とサンドボックス遮断を切り分けるため IP 直指定(1.1.1.1:443)。

# 共通のドリル一時ファイル置き場の親(prune 用)。
_AI_SAFE_PROBE_PARENT="$HOME/.ai-safety"

# _codex_probe_home — ドリル専用の一時 CODEX_HOME を作り、検証用プロファイルを
# 書き込んでそのパスを echo する。失敗時は空文字を返す。
#   safeprobe / netblock : ネット遮断(enabled=false)
#   netbaseline          : ネット許可(enabled=true) — ベースライン疎通確認用
_codex_probe_home() {
  local home
  home="$(mktemp -d 2>/dev/null)" || return 1
  cat > "$home/config.toml" <<'EOF'
[permissions.safeprobe]
description = "Safe Auto Mode isolation drill: workspace write, network blocked"
extends = ":workspace"

[permissions.safeprobe.network]
enabled = false

[permissions.netblock]
description = "Safe Auto Mode network drill: network blocked"
extends = ":workspace"

[permissions.netblock.network]
enabled = false

[permissions.netbaseline]
description = "Safe Auto Mode network drill: baseline reachability (network allowed)"
extends = ":workspace"

[permissions.netbaseline.network]
enabled = true
EOF
  printf '%s' "$home"
}

# drill_write_outside <engine>
# 金庫の中から (a) workspace 内書込が成功し、(b) workspace 外書込が遮断される
# ことを両方実証する。両立して初めて PASS。
# 中断(SIGALRM 等)時もリークしないよう RETURN trap で一時資源を必ず掃除する。
drill_write_outside() {
  local engine="$1"
  case "$engine" in
    codex)
      command -v codex >/dev/null 2>&1 || { echo "HOLD codex not installed"; return 20; }
      # 旧 PID 衝突や過去のリーク残骸を念のため一括 prune。
      rm -rf "$_AI_SAFE_PROBE_PARENT"/.sbprobe-out.* 2>/dev/null
      mkdir -p "$_AI_SAFE_PROBE_PARENT" 2>/dev/null

      local probe_home="" inside="" out_base=""
      # 関数を抜ける/中断される、どの経路でも一時資源を確実に掃除する(bash 3.2 RETURN trap)。
      trap 'rm -rf "$probe_home" "$inside" "$out_base" 2>/dev/null' RETURN

      probe_home="$(_codex_probe_home)" || { echo "HOLD could not create probe CODEX_HOME"; return 20; }

      # inside = git リポジトリにして :workspace が cwd を正確に workspace root と解決するようにする。
      inside="$(mktemp -d 2>/dev/null)" || { echo "HOLD could not create inside dir"; return 20; }
      ( cd "$inside" && git init -q >/dev/null 2>&1 )

      # outside = /tmp・$TMPDIR・workspace のいずれでもない実パス($HOME 配下の専用ディレクトリ)。
      # workspace-write では /tmp と $TMPDIR が常に書込可能なため、それらは outside に使えない。
      # mktemp -d を $HOME 配下に作り PID 再利用衝突を避ける。
      out_base="$(TMPDIR="$_AI_SAFE_PROBE_PARENT" mktemp -d "$_AI_SAFE_PROBE_PARENT/.sbprobe-out.XXXXXX" 2>/dev/null)" \
        || { echo "HOLD could not create outside dir under \$HOME"; return 20; }
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
        echo "FAIL workspace-outside write succeeded (sandbox leak)"; return 10
      fi
      # inside が作られていない = サンドボックス自体が正常作業できていない(起動失敗/abort 等)。
      # 「正常作業ができる金庫」を実証できていないので保守的に HOLD。
      if [ "$inside_created" -ne 1 ]; then
        echo "HOLD inside-write did not succeed (rc=$in_rc); cannot prove a working sandbox"; return 20
      fi
      # outside-write は遮断されるべき(rc!=0 が期待)。万一 rc=0 で抜けたのにファイルが無い等の
      # 不可解ケースは保守的に HOLD。
      if [ "$out_rc" -eq 0 ]; then
        echo "HOLD outside-write exited 0 but no file (indeterminate)"; return 20
      fi
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

# classify_net_result <baseline> <blocked>
# 2 段プローブの結果を金庫判定に写像する(テスト容易性のため分離)。
#   <baseline> : ベースライン疎通(ネット許可)プローブの結果 connected/refused/timeout
#   <blocked>  : 遮断プロファイルでのプローブ結果
#                 sandbox-blocked  = EPERM 系(sandbox 由来の遮断を実証)
#                 general-refused  = ECONNREFUSED 等(一般的な拒否。sandbox の実証にならない)
#                 connected / timeout その他
# 判定(フェイルクローズ):
#   baseline が connected でない = この環境はオフライン/到達不能 → 遮断を実証できない → HOLD(20)
#   baseline=connected かつ blocked=sandbox-blocked → sandbox 遮断を実証 = PASS(0)
#   baseline=connected かつ blocked=connected        → 金庫に穴 = FAIL(10)
#   baseline=connected かつ blocked=general-refused  → sandbox 由来でない拒否 → HOLD(20)
#   それ以外(blocked=timeout 等の判定不能)          → HOLD(20)
# 後方互換: 引数 1 個で呼ばれた旧シグネチャ(connected/refused/timeout)も受ける。
#   この場合 refused が sandbox-blocked か general-refused か不明なので HOLD(fail-closed)。
classify_net_result() {
  if [ "$#" -eq 1 ]; then
    # 旧シグネチャ(ベースライン無し)。ベースライン未確認では PASS にしない。
    case "$1" in
      connected) echo "FAIL egress connection succeeded"; return 10 ;;
      refused)   echo "HOLD egress refused but baseline reachability not verified (offline?)"; return 20 ;;
      *)         echo "HOLD egress result indeterminate (offline?)"; return 20 ;;
    esac
  fi
  local baseline="$1" blocked="$2"
  if [ "$baseline" != "connected" ]; then
    echo "HOLD network baseline not reachable (baseline=$baseline); cannot prove egress block (offline?)"; return 20
  fi
  case "$blocked" in
    sandbox-blocked) echo "PASS egress blocked by sandbox (EPERM/operation not permitted; baseline reachable)"; return 0 ;;
    connected)       echo "FAIL egress connection succeeded despite block profile"; return 10 ;;
    general-refused) echo "HOLD egress refused (ECONNREFUSED — not sandbox-derived; cannot prove isolation)"; return 20 ;;
    *)               echo "HOLD egress block result indeterminate (blocked=$blocked)"; return 20 ;;
  esac
}

# _probe_egress <engine> <profile> <host> <port>
# 指定 permissions プロファイルの金庫の中から <host>:<port> へ TCP 接続を試み、結果を
# "connected" / "refused" / "timeout" のいずれかで echo する。
# データは送らない(接続確立の可否のみ)。perl は macOS 標準で sandbox PATH 上にある。
# perl 起動失敗・判定不能はすべて timeout(= 上位で HOLD)に倒す(fail-open 防止)。
# 中断時もリークしないよう RETURN trap で一時資源を掃除する。
_probe_egress() {
  local engine="$1" profile="$2" host="$3" port="$4"
  case "$engine" in
    codex)
      local probe_home="" inside=""
      trap 'rm -rf "$probe_home" "$inside" 2>/dev/null' RETURN
      probe_home="$(_codex_probe_home)" || { echo timeout; return; }
      inside="$(mktemp -d 2>/dev/null)" || { echo timeout; return; }
      ( cd "$inside" && git init -q >/dev/null 2>&1 )
      # perl で TCP connect(6 秒 alarm)。結果を errno 文字列付きで出力して caller が種別判定できるようにする。
      # CONNECTED=接続成功 / REFUSED <errno>=拒否 / TIMEOUT=判定不能。
      # caller は REFUSED の errno を見て sandbox-blocked / general-refused に分類する。
      local perl_probe out
      perl_probe='use IO::Socket::INET;$SIG{ALRM}=sub{print "TIMEOUT\n";exit 2};alarm(6);'
      perl_probe="${perl_probe}my \$s=IO::Socket::INET->new(PeerAddr=>\"$host\",PeerPort=>$port,Proto=>\"tcp\");"
      perl_probe="${perl_probe}if(\$s){print \"CONNECTED\\n\";exit 0}else{print \"REFUSED \$!\\n\";exit 1}"
      out="$( CODEX_HOME="$probe_home" codex sandbox --permissions-profile "$profile" -C "$inside" /usr/bin/perl -e "$perl_probe" 2>&1 )"
      if printf '%s' "$out" | grep -q "CONNECTED"; then echo connected; return; fi
      if printf '%s' "$out" | grep -q "REFUSED"; then
        # errno 文字列で sandbox 由来(EPERM 系)か一般拒否(ECONNREFUSED)かを区別する。
        # sandbox による seatbelt 遮断は "Operation not permitted" / "permission denied" で現れる。
        # 一般的な Connection refused(ECONNREFUSED)は sandbox の実証にならない → general-refused。
        if printf '%s' "$out" | grep -iqE "operation not permitted|permission denied"; then
          echo sandbox-blocked; return
        else
          echo general-refused; return
        fi
      fi
      echo timeout
      ;;
    *) echo timeout ;;
  esac
}

# drill_network_egress <engine>
# 2 段でネット遮断を実証する(フェイルクローズ):
#   1. ベースライン疎通: ネット許可プロファイル(netbaseline)で IP 直 connect。
#      CONNECTED でなければ「この環境はオフライン/到達不能 → 遮断を実証できない」= HOLD。
#   2. 遮断プロファイル(netblock)で同じ宛先へ connect → refused = PASS / connected = FAIL。
# 宛先は DNS 非依存にするため IP 直指定(1.1.1.1:443)。実ネットへデータは送らない(connect 試行のみ)。
drill_network_egress() {
  local engine="$1"
  case "$engine" in
    codex)
      command -v codex >/dev/null 2>&1 || { echo "HOLD codex not installed"; return 20; }
      local probe_ip="1.1.1.1" probe_port=443
      local baseline blocked
      baseline="$(_probe_egress codex netbaseline "$probe_ip" "$probe_port")"
      # ベースラインが繋がらない時点で実証不能。遮断プローブを撃つ必要すら無いが、
      # 判定は classify_net_result に一本化する。
      if [ "$baseline" = "connected" ]; then
        blocked="$(_probe_egress codex netblock "$probe_ip" "$probe_port")"
      else
        blocked="skipped"
      fi
      classify_net_result "$baseline" "$blocked"
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
