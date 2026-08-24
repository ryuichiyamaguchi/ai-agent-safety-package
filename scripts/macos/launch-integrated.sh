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
  launch-integrated.sh [workspace] [menu|codex|claude|opencode|d-claude] [standard|assisted] [--websearch] [--longrun] [--resume] [--free] [--plan] [--project=<フォルダ>]

Menu:
  menu      Show an interactive menu ordered by billing plan and launch the choice.

Profiles:
  standard  Safety hooks + approval monitor. No local LLM is required.
  assisted  Claude only. Standard profile plus two-key AI review for gray commands.

OpenCode:
  standard only. DeepSeek V4 Pro/Flash is routed through the send inspection gateway.
  Web search is off by default; --websearch makes it approval-based.
  --free / --plan request the free / contract model when the OpenCode launcher
  in this workspace supports it (otherwise the flag is dropped with a notice).

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
  menu|codex|claude|opencode|d-claude) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "agent must be menu, codex, claude, opencode, or d-claude" >&2; usage >&2; exit 2 ;;
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
    --websearch|--longrun|--resume|--free|--plan|--project=*)
      if [ "$agent" != "opencode" ]; then
        echo "--websearch / --longrun / --resume / --free / --plan / --project は OpenCode だけで指定できます。" >&2
        exit 2
      fi
      ;;
    *)
      echo "第4引数以降に指定できるのは --websearch / --longrun / --resume / --free / --plan / --project=<フォルダ> だけです。" >&2
      exit 2
      ;;
  esac
done
if [ "$extra" = "--free" ] && [ "$extra2" = "--plan" ]; then
  echo "--free と --plan は同時に指定できません。" >&2
  exit 2
fi
if [ "$extra" = "--plan" ] && [ "$extra2" = "--free" ]; then
  echo "--free と --plan は同時に指定できません。" >&2
  exit 2
fi

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

# --- 対話メニュー（agent=menu のとき）--------------------------------------------
# 並びは「どの課金プランの人か」順。スタートのボタンはここへ委譲すれば、
# mac / Windows でメニューの正本が 1 か所（このランチャー）にまとまる。
# OpenCode は「起動したフォルダ」が作業対象になり、動き出したあとで cd しても移らない
# （OpenCode 本体の仕様）。案件ごとにフォルダを分けて作業できるよう、起動前にどこで
# 始めるかを選んでもらう。パスを打たせず、作業フォルダ直下の一覧から番号で選ぶ。
PROJECT_FLAG=""
choose_project() {
  # 直下のフォルダだけを候補にする（隠しフォルダと、パッケージが使う場所は除く）。
  _dirs=""
  _n=0
  for _d in "$workspace"/*/; do
    [ -d "$_d" ] || continue
    _name="$(basename "$_d")"
    case "$_name" in
      .*|スタート|safe-workspace) continue ;;
    esac
    _n=$((_n + 1))
    _dirs="$_dirs$_name"$'\n'
  done

  if [ "$_n" -eq 0 ]; then
    return 0
  fi

  echo
  echo "どのフォルダで作業しますか？"
  echo "────────────────────────────────"
  echo "0) $(basename "$workspace")（そのまま）"
  _i=0
  printf '%s' "$_dirs" | while IFS= read -r _name; do
    [ -n "$_name" ] || continue
    _i=$((_i + 1))
    echo "$_i) $_name"
  done
  echo
  read -r -p "番号を入力してください [0]: " _pick || _pick="0"
  _pick="${_pick:-0}"

  case "$_pick" in
    0) return 0 ;;
    ''|*[!0-9]*)
      echo "番号で選んでください。作業フォルダ直下で起動します。"
      return 0
      ;;
  esac
  if [ "$_pick" -gt "$_n" ]; then
    echo "その番号はありません。作業フォルダ直下で起動します。"
    return 0
  fi

  _sel="$(printf '%s' "$_dirs" | sed -n "${_pick}p")"
  [ -n "$_sel" ] || return 0
  PROJECT_FLAG="--project=$workspace/$_sel"
  # 変数の直後に日本語が続くと、bash 3.2 は変数名の切れ目を取り違える。必ず ${} で囲む。
  echo "「${_sel}」で起動します。"
}

if [ "$agent" = "menu" ]; then
  echo
  echo "AIをまとめて起動（安全装置つき）"
  echo "いまの契約（課金プラン）に合わせて番号を選んでください。"
  echo "────────────────────────────────"
  echo " 1) OpenCode（無料モデルを自分で選ぶ）… 完全無課金で使いたい人向け（送信検査なし）"
  echo " 2) セーフ AntiGravity（agy）       … こちらも無料（Google の無料 CLI）"
  echo " 3) OpenCode + DeepSeek             … DeepSeek のキーに少額チャージして使う人向け（送信検査つき）"
  echo " 4) DeepSeek-Claude（d-claude）     … DeepSeek の API キーを登録してある人向け"
  echo "    ※4 は在校中のみ。卒業後は使えなくなります（OpenCode へ移行 → 説明書 docs/20_卒業後ガイド）"
  echo " 5) Claude Code                     … Claude を課金契約している人向け"
  echo " 6) セーフ Codex                    … Codex（ChatGPT）を使う人向け。デスクトップアプリは無料プランでも使えます"
  echo "────────────────────────────────"
  echo "そのほかの起動方法:"
  echo " 7) Claude AI補助モード             … Claude 課金の人向け。グレーな操作を AI が二重チェックします"
  echo " 8) OpenCode（Web検索を確認制でON） … OpenCode で Web 検索も使いたい人向け"
  echo " 9) OpenCode（前回の続きから開く）  … 前回の OpenCode 作業のつづきをする人向け"
  echo "10) 長時間おまかせモード（上級）    … 目を離して長時間 AI に任せたい人向け"
  echo
  read -r -p "番号を入力してください [1]: " choice || {
    echo
    echo "入力が読み取れなかったため中止しました。" >&2
    exit 2
  }
  choice="${choice:-1}"

  case "$choice" in
    # 1 は無料モデルの自由選択（--free）。DeepSeek キー不要・送信検査 Gateway なし。
    # 安全設定（permission の表）は DeepSeek 版と同一（2026-08-24 依頼者裁定）。
    1) agent="opencode"; profile="standard"; choose_project; extra="--free"; extra2="$PROJECT_FLAG" ;;
    2)
      # 旧ボタン「4_セーフAntiGravityを起動」と同じ挙動（専用ランチャーへ委譲）。
      agy_launcher="$hooks/launch-agy-safe.sh"
      [ -f "$agy_launcher" ] || { echo "AntiGravity 用の起動スクリプトが見つかりません: $agy_launcher" >&2; exit 2; }
      if [ "${AI_SAFE_DRY_RUN:-0}" = "1" ]; then
        echo "安全装置（Bouncer）dry-run"
        echo "  workspace: $workspace"
        echo "  agent:     agy (launch-agy-safe.sh へ委譲)"
        exit 0
      fi
      exec bash "$agy_launcher" "$workspace"
      ;;
    3) agent="opencode"; profile="standard"; choose_project; extra="$PROJECT_FLAG"; extra2="" ;;
    4) agent="d-claude"; profile="standard" ;;
    5) agent="claude"; profile="standard" ;;
    6) agent="codex"; profile="standard" ;;
    7) agent="claude"; profile="assisted" ;;
    8) agent="opencode"; profile="standard"; choose_project; extra="--websearch"; extra2="$PROJECT_FLAG" ;;
    9) agent="opencode"; profile="standard"; choose_project; extra="--resume"; extra2="$PROJECT_FLAG" ;;
    10)
      # 既存ボタン「6_長時間おまかせモードで起動」と同じ挙動（専用ランチャーへ委譲。
      # どの AI で走らせるかは launch-longrun.sh 側の選択画面で選ぶ）。
      longrun_launcher="$hooks/launch-longrun.sh"
      [ -f "$longrun_launcher" ] || { echo "長時間おまかせモードの起動スクリプトが見つかりません: $longrun_launcher" >&2; exit 2; }
      if [ "${AI_SAFE_DRY_RUN:-0}" = "1" ]; then
        echo "安全装置（Bouncer）dry-run"
        echo "  workspace: $workspace"
        echo "  agent:     longrun (launch-longrun.sh へ委譲)"
        exit 0
      fi
      exec bash "$longrun_launcher" "$workspace"
      ;;
    *)
      echo "1〜10 の番号を選んでください。" >&2
      exit 2
      ;;
  esac
fi

if [ "${AI_SAFE_DRY_RUN:-0}" = "1" ]; then
  echo "安全装置（Bouncer）dry-run"
  echo "  workspace: $workspace"
  echo "  agent:     $agent"
  echo "  profile:   $profile"
  echo "  monitor:   enabled"
  if [ "$agent" = "opencode" ]; then
    _session="new"
    _project=""
    _model_req=""
    for _f in "$extra" "$extra2"; do
      case "$_f" in
        --resume) _session="continue last" ;;
        --project=*) _project="${_f#--project=}" ;;
        --free) _model_req="free (無料モデル指定)" ;;
        --plan) _model_req="plan (契約モデル指定)" ;;
      esac
    done
    echo "  session:   $_session"
    [ -n "$_project" ] && echo "  project:   $_project"
    [ -n "$_model_req" ] && echo "  model:     $_model_req"
  fi
  if [ "$agent" = "opencode" ] && { [ "$extra" = "--free" ] || [ "$extra2" = "--free" ]; }; then
    echo "  gateway:   none (--free / 送信検査 Gateway を使いません)"
  elif [ "$agent" = "opencode" ] || [ "$agent" = "d-claude" ]; then
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
    oc_launcher="$hooks/opencode/launch-opencode-deepseek.sh"
    # --free / --plan（モデル切り替え）は、この作業フォルダの OpenCode ランチャーが
    # そのフラグに対応している場合だけ渡す。未対応の版に渡すと使い方エラーで
    # 起動そのものが止まるため、フラグを外して標準設定で起動する（案内は出す）。
    if [ "$extra" = "--free" ] || [ "$extra" = "--plan" ]; then
      if ! grep -q -e "$extra" "$oc_launcher" 2>/dev/null; then
        echo "※ この作業フォルダの OpenCode 起動スクリプトは ${extra} に未対応のため、標準設定で起動します。"
        extra=""
      fi
    fi
    if [ "$extra2" = "--free" ] || [ "$extra2" = "--plan" ]; then
      if ! grep -q -e "$extra2" "$oc_launcher" 2>/dev/null; then
        echo "※ この作業フォルダの OpenCode 起動スクリプトは ${extra2} に未対応のため、標準設定で起動します。"
        extra2=""
      fi
    fi
    bash "$oc_launcher" "$workspace" "$extra" "$extra2"
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
        echo "スタート/キーと金庫/1_DeepSeekキーを登録 を先に実行してください。" >&2
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
