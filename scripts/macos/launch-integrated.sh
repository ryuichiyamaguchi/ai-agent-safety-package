#!/usr/bin/env bash
set -euo pipefail

# 受講者のシェルに残っていた AI_SAFE_POLICY / AI_SAFE_ROOT で deny 床ごと差し替えられる
# のを防ぐため、起動時に必ず捨てる（このあと同梱ポリシーを自分で設定する）。
# 万一これが漏れても、ガード側(lib/safety_policy.sh / lib/SafetyPolicy.ps1)が同梱パス以外を
# 拒否するので床は残る。ここは二重の保険。
unset AI_SAFE_POLICY AI_SAFE_ROOT

usage() {
  cat <<'EOF'
Usage:
  launch-integrated.sh [workspace] [codex|claude|opencode|d-claude] [standard|assisted] [--websearch] [--longrun] [--resume] [--project=<フォルダ>]

Profiles:
  standard  Safety hooks + approval monitor. No local LLM is required.
  assisted  Claude only. Standard profile plus two-key AI review for gray commands.

OpenCode:
  standard only. DeepSeek V4 Pro/Flash is routed through the send inspection gateway.
  Web search is off by default; --websearch makes it approval-based.

d-claude:
  standard only. Claude Code UX with DeepSeek, safety hooks, Bouncer monitor,
  and the same fail-closed send inspection gateway.
EOF
}

workspace="${1:-$(pwd)}"
agent="${2:-codex}"
profile="${3:-standard}"
# 第 4・第 5 引数は OpenCode 用のフラグ。--resume は前回のセッションを開き直す。
# 配列にしないのは macOS 標準の bash 3.2 では set -u と空配列展開の相性が悪いため。
extra="${4:-}"
extra2="${5:-}"

case "$agent" in
  codex|claude|opencode|d-claude) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "agent must be codex, claude, opencode, or d-claude" >&2; usage >&2; exit 2 ;;
esac

case "$profile" in
  standard|assisted) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "profile must be standard or assisted" >&2; usage >&2; exit 2 ;;
esac

if [ "$agent" = "codex" ] && [ "$profile" != "standard" ]; then
  echo "Codex は standard モードで起動してください。" >&2
  echo "Codex 自身の on-request + auto_review が承認要求を確認します。" >&2
  exit 2
fi
if [ "$agent" = "opencode" ] && [ "$profile" != "standard" ]; then
  echo "OpenCode は standard モードで起動してください。" >&2
  exit 2
fi
if [ "$agent" = "d-claude" ] && [ "$profile" != "standard" ]; then
  echo "d-claude は standard モードで起動してください。" >&2
  exit 2
fi
for _flag in "$extra" "$extra2"; do
  case "$_flag" in
    "") ;;
    --websearch|--longrun|--resume|--project=*)
      if [ "$agent" != "opencode" ]; then
        echo "--websearch / --longrun / --resume / --project は OpenCode だけで指定できます。" >&2
        exit 2
      fi
      ;;
    *)
      echo "第4引数以降に指定できるのは --websearch / --longrun / --resume / --project=<フォルダ> だけです。" >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$workspace" ]; then
  echo "作業フォルダが見つかりません: $workspace" >&2
  exit 2
fi

workspace="$(cd "$workspace" && pwd)"
# どのボタン(スタート等)から呼ばれても、AI は必ず作業フォルダを起点に起動する。
# Claude Code は起動時の cwd を CLAUDE_PROJECT_DIR とし、配布 settings のフックを
# $CLAUDE_PROJECT_DIR/.ai-safety/... から解決するため、cwd が workspace の外だと
# ガード欠落(fail-closed)で全プロンプトがブロックされる。
cd "$workspace"
root="$workspace/.ai-safety"
hooks="$root/hooks/macos"
log_dir="${AI_SAFE_LOG_DIR:-$HOME/.ai-safety/logs}"
mkdir -p "$log_dir"

[ -x "$hooks/open-monitor.sh" ] || {
  echo "安全装置（Bouncer）がこの作業フォルダに導入されていません。" >&2
  echo "先に統合版のインストーラーを実行してください。" >&2
  exit 2
}

if [ "${AI_SAFE_DRY_RUN:-0}" = "1" ]; then
  echo "安全装置（Bouncer）dry-run"
  echo "  workspace: $workspace"
  echo "  agent:     $agent"
  echo "  profile:   $profile"
  echo "  monitor:   enabled"
  if [ "$agent" = "opencode" ]; then
    _session="new"
    _project=""
    for _f in "$extra" "$extra2"; do
      case "$_f" in
        --resume) _session="continue last" ;;
        --project=*) _project="${_f#--project=}" ;;
      esac
    done
    echo "  session:   $_session"
    [ -n "$_project" ] && echo "  project:   $_project"
  fi
  if [ "$agent" = "opencode" ] || [ "$agent" = "d-claude" ]; then
    echo "  gateway:   http://127.0.0.1:8788 (send inspection, no local LLM)"
  else
    echo "  gateway:   bypassed (AIの応答速度を優先)"
  fi
  exit 0
fi

monitor_pid=""

cleanup() {
  if [ -n "$monitor_pid" ]; then kill "$monitor_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM HUP

AI_SAFE_PROFILE="$profile" AI_SAFE_AGENT="$agent" \
  bash "$hooks/open-monitor.sh" >"$log_dir/integrated-monitor.log" 2>&1 &
monitor_pid=$!

case "$agent:$profile" in
  codex:standard)
    bash "$hooks/launch-codex-safe.sh" "$workspace"
    ;;
  claude:standard)
    bash "$hooks/launch-claude-safe.sh" "$workspace"
    ;;
  claude:assisted)
    bash "$hooks/launch-claude-safe.sh" --assisted "$workspace"
    ;;
  opencode:standard)
    bash "$hooks/opencode/launch-opencode-deepseek.sh" "$workspace" "$extra" "$extra2"
    ;;
  d-claude:standard)
    consent="$hooks/launch-deepseek-safe.sh"
    gateway="$hooks/deepseek/launch-deepseek-gateway.sh"
    secret_store="$root/hooks/common/secret-store.js"
    [ -f "$consent" ] || { echo "DeepSeek同意ゲートが見つかりません: $consent" >&2; exit 2; }
    [ -f "$gateway" ] || { echo "DeepSeek送信検査Gatewayが見つかりません: $gateway" >&2; exit 2; }
    # 鍵の有無は「環境変数 → OS の金庫 → 旧平文」の解決結果で判定する。
    # 金庫化(secret-migrate.js)で旧平文 ~/.deepseek-claude/auth は削除されるので、
    # 平文ファイルの実在を条件にすると金庫に鍵があっても起動できなくなる（実測で再現済み）。
    # 順序の SSOT は scripts/common/secret-store.js の resolve()。ここはそれを呼ぶだけ。
    # node や secret-store.js が無い環境では判定を保留し、gateway 側の同じ 3 段解決に任せる
    # （ここで「未登録」と断定すると、鍵があるのに起動できない側へ倒れるため）。
    if command -v node >/dev/null 2>&1 && [ -f "$secret_store" ]; then
      if [ "$(node "$secret_store" --has deepseek 2>/dev/null || true)" != "yes" ]; then
        echo "DeepSeek APIキーが未登録です。" >&2
        echo "スタート/（上級）1_DeepSeekキーを登録 を先に実行してください。" >&2
        exit 2
      fi
    fi
    bash "$consent" --consent-only
    # 実キーはここでは読まない。Gateway 子プロセスだけが読む（Claude Code には渡さない）。
    # gateway は同じ 3 段解決で鍵を取り、ANTHROPIC_AUTH_TOKEN は起動限りの合言葉で上書きする。
    unset ANTHROPIC_AUTH_TOKEN
    # モデル名に [1m]（1M コンテキスト指定）を付けると、Claude Code 2.1.226 以降は
    # それを名前の一部として扱い「そんなモデルは無い」で起動できなくなる（実機で再現）。
    # DeepSeek が公開しているのは deepseek-v4-flash / deepseek-v4-pro の 2 つだけ。
    # 1M コンテキストは CLAUDE_CODE_MAX_CONTEXT_TOKENS で伝える（これが無いと 200k 扱いの警告が出る）。
    export ANTHROPIC_MODEL="deepseek-v4-flash"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-v4-flash"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-flash"
    export CLAUDE_CODE_MAX_CONTEXT_TOKENS="1048576"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"
    export CLAUDE_CODE_SUBAGENT_MODEL="deepseek-v4-flash"
    export CLAUDE_CODE_EFFORT_LEVEL="max"
    # 既定は Flash のまま。かしこい deepseek-v4-pro を /model の一覧にも出しておき、
    # 受講者が `/model deepseek-v4-pro` でその場かぎり切り替えられるようにする
    # （実測: `/model <名前>` は "for this session only"。設定ファイルは書き換わらない）。
    export ANTHROPIC_CUSTOM_MODEL_OPTION="deepseek-v4-pro"
    export ANTHROPIC_CUSTOM_MODEL_OPTION_NAME="DeepSeek V4 Pro"
    export ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION="むずかしい作業向け。V4 Flash より料金が高くなります"
    bash "$gateway" "$workspace"
    ;;
esac
