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
# 既存設定は壊さない(union / 管理キーのみ変更)。反映前に自動バックアップ。取り消しは
# uninstall-global-guard.sh で確実に元へ戻せる。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 配置: <workspace>/.ai-safety/hooks/macos/apply-global-guard.sh
WORKSPACE="$(cd "$HERE/../../.." && pwd)"
GUARD_DIR="$HERE"                                  # guard-*.sh はこのフォルダにある(絶対パス)
COMMON="$HERE/../common"
CLAUDE_JS="$COMMON/apply-global-guard.js"
CODEX_JS="$COMMON/apply-global-codex.js"
AGY_JS="$COMMON/apply-global-agy.js"
OPENCODE_JS="$COMMON/apply-global-opencode.js"

SRC="${AI_SAFE_DENY_SRC:-$WORKSPACE/.claude/settings.json}"
CLAUDE_TARGET="${AI_SAFE_GLOBAL_CLAUDE:-$HOME/.claude/settings.json}"
CODEX_CONFIG="${AI_SAFE_GLOBAL_CODEX:-$HOME/.codex/config.toml}"
CODEX_HOOKS="${AI_SAFE_GLOBAL_CODEX_HOOKS:-$HOME/.codex/hooks.json}"
AGY_TARGET="${AI_SAFE_GLOBAL_AGY:-$HOME/.gemini/settings.json}"
OPENCODE_DIR="${AI_SAFE_GLOBAL_OPENCODE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
STATE_ARGS=()
[ -n "${AI_SAFE_GLOBAL_STATE:-}" ] && STATE_ARGS=(--state "$AI_SAFE_GLOBAL_STATE")

if ! command -v node >/dev/null 2>&1; then
  echo "エラー: node が見つかりません。Node.js を入れてから実行してください。" >&2
  exit 2
fi
if [ ! -f "$SRC" ]; then
  echo "エラー: deny の元設定が見つかりません: $SRC" >&2
  echo "  → 先に「1_安全パッケージを準備」を実行してください。" >&2
  exit 2
fi
for _js in "$CLAUDE_JS" "$CODEX_JS" "$AGY_JS" "$OPENCODE_JS"; do
  if [ ! -f "$_js" ]; then
    echo "エラー: 反映スクリプトが見つかりません: $_js" >&2
    echo "  → 先に「1_安全パッケージを準備」を実行してください。" >&2
    exit 2
  fi
done

# ---- 実行前の「何を・どこに入れるか」一覧 --------------------------------
_oc_target="$OPENCODE_DIR/opencode.json"
[ -f "$OPENCODE_DIR/opencode.jsonc" ] && _oc_target="$OPENCODE_DIR/opencode.jsonc"

cat <<EOF
この Mac の「全体設定」に、次の内容を入れます。
（どのフォルダから AI を起動しても最低限の安全が効くようにする設定です。）

 1) Claude Code   → $CLAUDE_TARGET
      危険コマンドの禁止リスト（rm -r / cat .env / curl|sh / 外部送信など）と、
      安全ガードの呼び出し（絶対パス）を追加します。

 2) Codex         → $CODEX_CONFIG
                    $CODEX_HOOKS
      承認の求め方（on-request）・二次レビュー（auto_review）・
      作業フォルダ外への書き込み禁止（sandbox_mode = workspace-write）・
      API キーを子プロセスに渡さない設定を入れます。通信は開けたままにします。
      ※ Codex のデスクトップアプリも同じ config.toml を読むので、アプリにも同時に効きます。

 3) agy / Gemini  → $AGY_TARGET
      安全ガードの呼び出し（絶対パス）を追加します。

 4) OpenCode      → $_oc_target
      危険コマンドの禁止（rm / sudo / git reset --hard）と、
      確認を挟むコマンド（git push / npm publish / 他エージェントの起動 など）を追加します。

・既存の設定は壊しません（安全に関係のない項目は 1 つも変えません）。
・書き込む前に ~/.ai-safety/backups/ へ自動でバックアップを取ります。
・元に戻したいときは「キーと金庫/13_PC全体の安全設定を解除」を実行してください。
EOF

_skip_confirm=0
case " $* " in *" --dry-run "*) _skip_confirm=1 ;; esac
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

# ---- 反映 ---------------------------------------------------------------
rc=0
# exit 3 = 「壊れた設定なので触らずスキップ」。失敗ではないので rc は上げない。
run_engine() {
  "$@"
  local ec=$?
  if [ $ec -eq 3 ]; then
    echo "  → スキップしました（既存の設定ファイルを安全に読めないため）。"
  elif [ $ec -ne 0 ]; then
    rc=1
  fi
}

echo ""
echo "── 1) Claude Code の全体設定に反映 ───────────────────"
run_engine node "$CLAUDE_JS" apply --source "$SRC" --target "$CLAUDE_TARGET" --os macos --guard-dir "$GUARD_DIR" ${STATE_ARGS[@]+"${STATE_ARGS[@]}"} "$@"

echo ""
echo "── 2) Codex の全体設定に反映 ─────────────────────────"
run_engine node "$CODEX_JS" apply --config-target "$CODEX_CONFIG" --hooks-target "$CODEX_HOOKS" --os macos --guard-dir "$GUARD_DIR" ${STATE_ARGS[@]+"${STATE_ARGS[@]}"} "$@"
echo "  ※ Codex の guard hook を発火させるには、一度だけ codex を起動して /hooks で信頼してください。"
echo "     常時有効な保護(サンドボックス・承認・APIキー除外)は上の config.toml で決定的に効きます。"
echo "     この config.toml は Codex デスクトップアプリも読むので、アプリ側にも同時に効きます。"

echo ""
echo "── 3) agy / Gemini の全体設定に反映 ──────────────────"
run_engine node "$AGY_JS" apply --target "$AGY_TARGET" --os macos --guard-dir "$GUARD_DIR" ${STATE_ARGS[@]+"${STATE_ARGS[@]}"} "$@"

echo ""
echo "── 4) OpenCode の全体設定に反映 ──────────────────────"
run_engine node "$OPENCODE_JS" apply --config-dir "$OPENCODE_DIR" ${STATE_ARGS[@]+"${STATE_ARGS[@]}"} "$@"

exit $rc
