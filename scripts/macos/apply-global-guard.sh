#!/bin/bash
# apply-global-guard.sh — この Mac の「全体設定」に、4 エンジン分の最低限の安全設定を入れる。
#
#   Claude Code (~/.claude/settings.json):
#     - permissions.deny を union し、さらに guard スクリプトの絶対パスを指す hooks を追加。
#       どのフォルダから claude を起動しても、rm -r / cat .env / curl|sh 等をブロックする。
#   Codex (~/.codex/config.toml + ~/.codex/hooks.json):
#     - approval_policy=on-request / approvals_reviewer=auto_review / sandbox_mode=workspace-write /
#       shell_environment_policy.exclude(APIキー) 等の「決定的な」保護を反映(常時有効)。
#     - guard の絶対パス hooks も配線する(発火には codex の /hooks で一度だけ信頼する操作が要る)。
#     ※ Codex の**デスクトップアプリも同じ ~/.codex/config.toml を読む**（アプリの設定画面の
#        「config.toml を開く」がこのファイル、画面の「サンドボックス設定＝ワークスペース内での
#        書き込み」が sandbox_mode="workspace-write" と一致することを実測確認済み）。
#        つまりこの 1 回でターミナルの codex とデスクトップアプリの両方に安全設定が入る。
#   agy / Gemini CLI (~/.gemini/settings.json):
#     - guard の絶対パス hooks を配線する(BeforeAgent / BeforeTool / AfterModel / AfterAgent)。
#   OpenCode (~/.config/opencode/opencode.json):
#     - permission.bash の最小 deny / ask を反映する(OpenCode には hook 層が無いため)。
#
# hook が呼ぶ guard の置き場（v1.19.x〜）:
#   以前は作業フォルダの中 (<ws>/.ai-safety/hooks/macos/guard-*.sh) を絶対パスで指していた。
#   hook はスクリプトが見つからないと安全側に倒して exit 2 するため、作業フォルダを移動・
#   名前変更すると、この Mac のすべての Claude セッションが止まっていた。そこで反映の前に
#   guard 一式を ~/.ai-safety/global/ へ複製し（scripts/common/stage-global-runtime.js）、
#   hook はそちらを指す。作業フォルダを動かしても PC 全体の安全設定は効き続ける。
#   古い版で入れた「作業フォルダを指す hook」は、反映のたびに新しい置き場へ張り替わる。
#
# 使い方:
#   apply-global-guard.sh            … 「キーと金庫/12」から。内容を見せて確認してから入れる。
#                                       以前「13」で解除した記録（~/.ai-safety/global-guard-optout）は消す。
#   apply-global-guard.sh --auto     … install.sh（導入・更新）から。確認なしで入れ、短い案内だけ出す。
#                                       解除の記録があるとき・AI_SAFE_NO_GLOBAL_GUARD=1 のときは何もしない。
#   apply-global-guard.sh --dry-run  … 何も書かずに、入れる内容だけ表示する。
#
# 既存設定は壊さない(union / 管理キーのみ変更)。反映前に自動バックアップ。取り消しは
# uninstall-global-guard.sh で確実に元へ戻せる。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 配置: <workspace>/.ai-safety/hooks/macos/apply-global-guard.sh
WORKSPACE="$(cd "$HERE/../../.." && pwd)"
COMMON="$HERE/../common"
CLAUDE_JS="$COMMON/apply-global-guard.js"
CODEX_JS="$COMMON/apply-global-codex.js"
AGY_JS="$COMMON/apply-global-agy.js"
OPENCODE_JS="$COMMON/apply-global-opencode.js"
STAGE_JS="$COMMON/stage-global-runtime.js"

SRC="${AI_SAFE_DENY_SRC:-$WORKSPACE/.claude/settings.json}"
CLAUDE_TARGET="${AI_SAFE_GLOBAL_CLAUDE:-$HOME/.claude/settings.json}"
CODEX_CONFIG="${AI_SAFE_GLOBAL_CODEX:-$HOME/.codex/config.toml}"
CODEX_HOOKS="${AI_SAFE_GLOBAL_CODEX_HOOKS:-$HOME/.codex/hooks.json}"
AGY_TARGET="${AI_SAFE_GLOBAL_AGY:-$HOME/.gemini/settings.json}"
OPENCODE_DIR="${AI_SAFE_GLOBAL_OPENCODE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
# guard 一式の固定の置き場。hook はここを指す（作業フォルダの場所に依存しない）。
GLOBAL_RUNTIME="$HOME/.ai-safety/global"
GUARD_DIR="$GLOBAL_RUNTIME/hooks/macos"
# 「13_PC全体の安全設定を解除」を押した記録。あれば導入・更新のたびに入れ直すことはしない。
OPTOUT_MARKER="$HOME/.ai-safety/global-guard-optout"
STATE_ARGS=()
[ -n "${AI_SAFE_GLOBAL_STATE:-}" ] && STATE_ARGS=(--state "$AI_SAFE_GLOBAL_STATE")

AUTO=0
DRY_RUN=0
PASS_ARGS=()
for _a in "$@"; do
  case "$_a" in
    --auto) AUTO=1 ;;
    --dry-run) DRY_RUN=1; PASS_ARGS+=(--dry-run) ;;
    *) PASS_ARGS+=("$_a") ;;
  esac
done

if [ "$AUTO" -eq 1 ]; then
  if [ "${AI_SAFE_NO_GLOBAL_GUARD:-0}" = "1" ]; then
    echo "PC 全体の安全設定: AI_SAFE_NO_GLOBAL_GUARD=1 のため入れませんでした。"
    exit 0
  fi
  if [ -e "$OPTOUT_MARKER" ]; then
    echo "PC 全体の安全設定: 以前「13_PC全体の安全設定を解除」で解除されているため、入れ直していません。"
    exit 0
  fi
fi

if ! command -v node >/dev/null 2>&1; then
  echo "エラー: node が見つかりません。Node.js を入れてから実行してください。" >&2
  exit 2
fi
if [ ! -f "$SRC" ]; then
  echo "エラー: deny の元設定が見つかりません: $SRC" >&2
  echo "  → 先に「1_安全パッケージを準備」を実行してください。" >&2
  exit 2
fi
for _js in "$CLAUDE_JS" "$CODEX_JS" "$AGY_JS" "$OPENCODE_JS" "$STAGE_JS"; do
  if [ ! -f "$_js" ]; then
    echo "エラー: 反映スクリプトが見つかりません: $_js" >&2
    echo "  → 先に「1_安全パッケージを準備」を実行してください。" >&2
    exit 2
  fi
done

# ---- 実行前の「何を・どこに入れるか」一覧 --------------------------------
_oc_target="$OPENCODE_DIR/opencode.json"
[ -f "$OPENCODE_DIR/opencode.jsonc" ] && _oc_target="$OPENCODE_DIR/opencode.jsonc"

if [ "$AUTO" -eq 0 ]; then
cat <<EOF
この Mac の「全体設定」に、次の内容を入れます。
（どのフォルダから AI を起動しても最低限の安全が効くようにする設定です。
  安全パッケージを導入・更新すると、最初からこの設定が入ります。）

 1) Claude Code   → $CLAUDE_TARGET
      危険コマンドの禁止リスト（rm -r / cat .env / curl|sh / 外部送信など）と、
      安全ガードの呼び出しを追加します。

 2) Codex         → $CODEX_CONFIG
                    $CODEX_HOOKS
      承認の求め方（on-request）・二次レビュー（auto_review）・
      作業フォルダ外への書き込み禁止（sandbox_mode = workspace-write）・
      API キーを子プロセスに渡さない設定を入れます。通信は開けたままにします。
      ※ Codex のデスクトップアプリも同じ config.toml を読むので、アプリにも同時に効きます。

 3) agy / Gemini  → $AGY_TARGET
      安全ガードの呼び出しを追加します。

 4) OpenCode      → $_oc_target
      危険コマンドの禁止（rm / sudo / git reset --hard）と、
      確認を挟むコマンド（git push / npm publish / 他エージェントの起動 など）を追加します。

・安全ガードの本体は $GLOBAL_RUNTIME に置きます。
  作業フォルダを移動したり名前を変えたりしても、この設定は効き続けます。
・既存の設定は壊しません（安全に関係のない項目は 1 つも変えません）。
・書き込む前に ~/.ai-safety/backups/ へ自動でバックアップを取ります。
・元に戻したいときは「キーと金庫/13_PC全体の安全設定を解除」を実行してください。
EOF
fi

_skip_confirm=0
[ "$DRY_RUN" -eq 1 ] && _skip_confirm=1
[ "$AUTO" -eq 1 ] && _skip_confirm=1
[ "${AI_SAFE_ASSUME_YES:-0}" = "1" ] && _skip_confirm=1
[ -t 0 ] || _skip_confirm=1

if [ "$_skip_confirm" -eq 0 ]; then
  echo ""
  printf 'この内容で入れますか？ [y/N]: '
  read -r _ans || _ans=""
  case "$_ans" in
    y|Y|yes|YES) ;;
    *) echo "中止しました。設定は 1 つも変更していません。"; exit 0 ;;
  esac
fi

# ---- 自分で入れ直したので「解除した」記録を消す ----------------------------
# 12 を押す＝PC 全体の安全設定を使うという意思表示。今後の導入・更新でも入れ直すようにする。
if [ "$AUTO" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ -e "$OPTOUT_MARKER" ]; then
  if rm -f "$OPTOUT_MARKER" 2>/dev/null; then
    echo ""
    echo "以前の「解除した」記録を消しました。これからは安全パッケージの更新のたびに、この設定を入れ直します。"
  fi
fi

# ---- guard 一式を固定の置き場へ複製（hook はここを指す） ---------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "[dry-run] 安全ガードの本体を ${GLOBAL_RUNTIME} に置き直します（今回は書き込みません）。"
else
  if [ "$AUTO" -eq 1 ]; then
    node "$STAGE_JS" --os macos --guard-src "$HERE" --dest "$GLOBAL_RUNTIME" >/dev/null
  else
    echo ""
    echo "── 0) 安全ガードの本体を置く（${GLOBAL_RUNTIME}） ──────"
    node "$STAGE_JS" --os macos --guard-src "$HERE" --dest "$GLOBAL_RUNTIME"
  fi
  _stage_rc=$?
  if [ "$_stage_rc" -ne 0 ]; then
    echo "エラー: 安全ガードの本体を ${GLOBAL_RUNTIME} に置けませんでした（上のメッセージを確認してください）。" >&2
    echo "  全体設定は 1 つも変更していません。" >&2
    exit 2
  fi
fi

# ---- 反映 ---------------------------------------------------------------
rc=0
_status=""
# exit 3 = 「壊れた設定なので触らずスキップ」。失敗ではないので rc は上げない。
# $1 = 表示名。以降が実行するコマンド。--auto のときは各エンジンの詳細を出さず 1 行にまとめる。
run_engine() {
  local label="$1"
  shift
  local ec
  if [ "$AUTO" -eq 1 ]; then
    "$@" >/dev/null
  else
    "$@"
  fi
  ec=$?
  if [ $ec -eq 3 ]; then
    [ "$AUTO" -eq 0 ] && echo "  → スキップしました（既存の設定ファイルを安全に読めないため）。"
    _status="${_status}  ・${label}: スキップ（既存の設定ファイルを安全に読めないため触っていません）
"
  elif [ $ec -ne 0 ]; then
    rc=1
    _status="${_status}  ・${label}: 失敗（上のメッセージを確認してください）
"
  else
    _status="${_status}  ・${label}: 反映しました
"
  fi
}

[ "$AUTO" -eq 0 ] && { echo ""; echo "── 1) Claude Code の全体設定に反映 ───────────────────"; }
run_engine "Claude Code  (~/.claude/settings.json)" \
  node "$CLAUDE_JS" apply --source "$SRC" --target "$CLAUDE_TARGET" --os macos --guard-dir "$GUARD_DIR" ${STATE_ARGS[@]+"${STATE_ARGS[@]}"} ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}

[ "$AUTO" -eq 0 ] && { echo ""; echo "── 2) Codex の全体設定に反映 ─────────────────────────"; }
run_engine "Codex        (~/.codex/config.toml と hooks.json。デスクトップアプリにも効きます)" \
  node "$CODEX_JS" apply --config-target "$CODEX_CONFIG" --hooks-target "$CODEX_HOOKS" --os macos --guard-dir "$GUARD_DIR" ${STATE_ARGS[@]+"${STATE_ARGS[@]}"} ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
if [ "$AUTO" -eq 0 ]; then
  echo "  ※ Codex の guard hook を発火させるには、一度だけ codex を起動して /hooks で信頼してください。"
  echo "     常時有効な保護(サンドボックス・承認・APIキー除外)は上の config.toml で決定的に効きます。"
  echo "     この config.toml は Codex デスクトップアプリも読むので、アプリ側にも同時に効きます。"
fi

[ "$AUTO" -eq 0 ] && { echo ""; echo "── 3) agy / Gemini の全体設定に反映 ──────────────────"; }
run_engine "agy / Gemini (~/.gemini/settings.json)" \
  node "$AGY_JS" apply --target "$AGY_TARGET" --os macos --guard-dir "$GUARD_DIR" ${STATE_ARGS[@]+"${STATE_ARGS[@]}"} ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}

[ "$AUTO" -eq 0 ] && { echo ""; echo "── 4) OpenCode の全体設定に反映 ──────────────────────"; }
run_engine "OpenCode     (~/.config/opencode/opencode.json)" \
  node "$OPENCODE_JS" apply --config-dir "$OPENCODE_DIR" ${STATE_ARGS[@]+"${STATE_ARGS[@]}"} ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}

if [ "$AUTO" -eq 1 ]; then
  echo ""
  echo "── PC 全体の安全設定（最初から入っています） ─────────"
  echo "この Mac のどのフォルダから AI を起動しても、危険な操作（rm -r / cat .env / curl|sh など）が"
  echo "止まるように、次の全体設定を更新しました（変更前の状態は ~/.ai-safety/backups/ に保存済み）。"
  printf '%s' "$_status"
  echo "  安全ガードの本体は ~/.ai-safety/global/ にあるので、作業フォルダを移動しても効き続けます。"
  echo "  やめたいとき: スタート/キーと金庫/13_PC全体の安全設定を解除（次の更新からも入れ直しません）"
fi

exit $rc
