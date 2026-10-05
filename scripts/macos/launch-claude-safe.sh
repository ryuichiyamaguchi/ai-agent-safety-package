#!/usr/bin/env bash
set -euo pipefail
# このスクリプト自身の置き場所（途中で cd しても変わらないよう、最初に一度だけ求める）。
_self_dir="$(cd "$(dirname "$0")" && pwd)"

# 受講者のシェルに残っていた AI_SAFE_POLICY / AI_SAFE_ROOT で deny 床ごと差し替えられる
# のを防ぐため、起動時に必ず捨てる（このあと同梱ポリシーを自分で設定する）。
# 万一これが漏れても、ガード側(lib/safety_policy.sh / lib/SafetyPolicy.ps1)が同梱パス以外を
# 拒否するので床は残る。ここは二重の保険。
unset AI_SAFE_POLICY AI_SAFE_ROOT
# M13: Claude Code の approval 制御は CLI フラグでは渡せない（Codex の
# --ask-for-approval untrusted に相当する仕組みは settings.json 側にある）。
# 本パッケージは configs/claude/settings.mac.json の permissions / hooks 経由で
# 同等の効果（PreToolUse hook による fail-closed 判定 + 危険コマンド deny）を出している。
# 追加の保険として --permission-mode default を渡し、Claude Code 側のデフォルト
# 承認モードを明示する。古い CLI でフラグ非対応の場合はフォールバックする。
# --assisted opt-in: AI グレーゾーン自動承認を有効化（既定 OFF）。フラグを引数列から
# 取り除いてから従来の位置引数（workspace / prompt）を解釈する。事前に環境変数
# AI_SAFE_ASSISTED_APPROVAL=1 が立っている場合もそのまま尊重して引き継ぐ。
# --longrun: 長時間おまかせモード（v1.19.9）。d-claude を launch-longrun.sh から起動するとき、
# launch-integrated.sh → launch-deepseek-gateway.sh を通って渡ってくる。下の「長時間おまかせモード」を参照。
_args=()
_longrun=0
for _a in "$@"; do
  if [ "$_a" = "--assisted" ]; then
    export AI_SAFE_ASSISTED_APPROVAL=1
  elif [ "$_a" = "--longrun" ]; then
    _longrun=1
  else
    _args+=("$_a")
  fi
done
# bash 3.2 + set -u では空配列展開が unbound になるため要素数で分岐する。
if [ "${#_args[@]}" -gt 0 ]; then set -- "${_args[@]}"; else set --; fi

workspace="${1:-$(pwd)}"
prompt="${2:-}"
workspace="$(cd "$workspace" && pwd)"
settings="$workspace/.claude/settings.json"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

# claude-safe は「普通の Claude（ログイン認証）」を起動する。DeepSeek 連携が残した
# ルーティング系 env を引き継ぐと無効トークンで 401 になりうるため、このシェル内で外す。
# ただし d-claude（DeepSeek 駆動）は gateway 経由でこのスクリプトを呼び、DeepSeek キー
# (ANTHROPIC_AUTH_TOKEN) と Gateway の BASE_URL/MODEL を「使う」ために渡してくる。
# その経路では gateway が DS_CLAUDE_MODE=1 を立てるので unset をスキップする
# （ここで消すと DeepSeek に繋がらず claude が "not logged in" になる）。
if [ "${DS_CLAUDE_MODE:-}" != "1" ]; then
  unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL ANTHROPIC_CUSTOM_MODEL_OPTION ANTHROPIC_CUSTOM_MODEL_OPTION_NAME ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION
fi

[ -f "$settings" ] || { echo "Claude の安全設定ファイルが見つかりませんでした。" >&2; echo "先に「導入(インストール)」を実行してから、もう一度この起動ボタンを押してください。" >&2; echo "（確認した場所: ${settings}）" >&2; exit 2; }
[ -f "$AI_SAFE_POLICY" ] || { echo "AI安全パッケージがこのフォルダにまだ導入されていません。" >&2; echo "対象フォルダ: $workspace" >&2; echo "先に「導入(インストール)」を実行してから、もう一度この起動ボタンを押してください。" >&2; exit 2; }

# claude バイナリ検出（PATH 不在時は日本語で案内し、bash の "command not found" を防ぐ）。
if ! command -v claude >/dev/null 2>&1; then
  echo "claude コマンドが見つかりません。" >&2
  echo "先に Claude Code をインストールしてください（例: npm install -g @anthropic-ai/claude-code@latest）。" >&2
  echo "インストール済みなのに出る場合は、ターミナルを開き直すか PATH を確認してください。" >&2
  exit 1
fi

# C: Claude Code の版チェック（素の claude-safe / d-claude 共通）。動作確認済みの版
# (policy の testedClaudeCodeVersion) と実版を比較し、差異があれば黙らず日本語で警告する
# （起動は止めない）。版差は「フラグ欠落で機能が黙って落ちる」「人により違うエラー」の親玉。
# 旧ポリシー（キー無し）や plutil 不在では静かにスキップ（この照合は任意の助言であり防御ではない）。
_expected_cc_ver=""
if [ -x /usr/bin/plutil ] && [ -f "$AI_SAFE_POLICY" ]; then
  _expected_cc_ver="$(/usr/bin/plutil -extract testedClaudeCodeVersion raw -o - "$AI_SAFE_POLICY" 2>/dev/null || true)"
fi
if [ -n "$_expected_cc_ver" ]; then
  _actual_cc_ver="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  if [ -z "$_actual_cc_ver" ]; then
    echo "注意: Claude Code の版を確認できませんでした（claude --version が取得できない）。動作確認済みの版は ${_expected_cc_ver} です。" >&2
  elif [ "$_actual_cc_ver" != "$_expected_cc_ver" ]; then
    echo "注意: Claude Code の版が動作確認済みと異なります（実際: ${_actual_cc_ver} / 動作確認済み: ${_expected_cc_ver}）。" >&2
    echo "      版差で一部の安全/補助機能が黙って無効化されることがあります。揃えるには次を実行してください:" >&2
    echo "      npm install -g @anthropic-ai/claude-code@${_expected_cc_ver}" >&2
  fi
fi

# 長時間おまかせモード（d-claude。v1.19.9 で追加・v1.20.0 で確認なしに）: 恒久的な設定ファイルは書き換えず、
# このモードの差分だけを当てた一時設定を作って渡し、終了時に消す。変換は scripts/common/longrun-claude-settings.js。
#   ・dontAsk モードで起動する（確認が要る操作は自動で断り、入力を待って止まらない。Claude Code 公式）。
#     実行されるのは「許可の規則に合うもの」と「ガード（フック）が許可したもの」だけ
#   ・d-claude（DeepSeek）は Claude Code 公式の判定役（auto モード）を使えないので、コマンドは安全パッケージの
#     AI 判定（Gemini）が見て、「通してよい」ならガードが許可する。「確認」と言ったもの・判定できなかったものは
#     ガードが止める（AI_SAFE_LONGRUN=1）
#   ・Web 取得と d-claude の補助ツールは、一時設定で許可の規則を足す（--dclaude）
#   ・全承認（bypassPermissions）は使わない。ask は deny へ寄せる。禁止の規則とガードはそのまま
#   ・壁（sandbox-exec ＋ 作業フォルダの sandbox.enabled）があるときは、壁を必須にし、壁の外での実行し直しも
#     禁止する（--wall --dclaude → allowUnsandboxedCommands: false）
#   ・作業フォルダの .claude/settings.json は直接読まず（--setting-sources から project を外す）、その中身を写した
#     一時設定（フック・禁止の規則を含む）だけを渡す（作業フォルダの ask を確認ではなく deny として効かせるため）
#   ・dontAsk が無い古い Claude Code では acceptEdits で起動する（そのときは確認が出ることがある）
_permission_mode="default"
_setting_sources="user,project,local"
if [ "$_longrun" = "1" ]; then
  _lr_builder="$(cd "$_self_dir/.." && pwd)/common/longrun-claude-settings.js"
  [ -f "$_lr_builder" ] || { echo "長時間おまかせモードの設定づくりが見つかりません: $_lr_builder" >&2; echo "「1_安全パッケージを最新版にする」を実行してください。" >&2; exit 2; }
  command -v node >/dev/null 2>&1 || { echo "node コマンドが見つかりません（このモードの設定づくりに必要です）。" >&2; exit 1; }
  _lr_wall=""
  if [ -x /usr/bin/sandbox-exec ] && node -e '
      const fs=require("fs");
      const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      process.exit(s && s.sandbox && s.sandbox.enabled === true ? 0 : 1);
    ' "$settings" >/dev/null 2>&1; then
    _lr_wall="--wall"
  fi
  _lr_dir="$(mktemp -d "${TMPDIR:-/tmp}/ai-safe-longrun.XXXXXX")"
  chmod 700 "$_lr_dir"
  trap 'rm -rf "$_lr_dir"' EXIT INT TERM HUP
  if [ -n "$_lr_wall" ]; then
    node "$_lr_builder" "$settings" "$_lr_dir/settings.json" --wall --dclaude || { echo "このモード用の設定を作れませんでした。" >&2; exit 1; }
  else
    node "$_lr_builder" "$settings" "$_lr_dir/settings.json" --dclaude || { echo "このモード用の設定を作れませんでした。" >&2; exit 1; }
  fi
  settings="$_lr_dir/settings.json"
  _permission_mode="acceptEdits"
  if claude --help 2>&1 | grep -q '"dontAsk"'; then _permission_mode="dontAsk"; fi
  _setting_sources="user,local"
  export AI_SAFE_LONGRUN=1
  # コマンドを通すかどうかは AI 判定（Gemini）が決めるので、このモードでは必ずオンにする。ふだんの d-claude では
  # AI_SAFE_ASSISTED_APPROVAL_OPTOUT=1 で外せるが、このモードでは外させない（外れていると、許可リストにない
  # コマンドがすべて断られて作業が進まない）。
  export AI_SAFE_ASSISTED_APPROVAL=1
  echo "（長時間おまかせモード: 確認は出しません。危険な操作はガードが止め、グレーなコマンドは AI が判定します。終了すると一時設定は自動で消えます）"
fi

# --permission-mode の対応有無を help で判定（非対応の Claude Code でも壊れないように）
claude_args=(--settings "$settings" --setting-sources "$_setting_sources")
if claude --help 2>&1 | grep -q -- "--permission-mode"; then
  claude_args=(--permission-mode "$_permission_mode" "${claude_args[@]}")
fi

# d-claude（DeepSeek 駆動）のときだけ、正直さ・身元の上書き指示を system prompt に追記する。
# DeepSeek は Claude Code の「あなたは Claude」プロンプトを受け取って Anthropic を装い、
# できないことを「できる」・やっていないことを「やった」と過剰申告する傾向がある。
# --append-system-prompt で「実際は DeepSeek」「嘘・捏造をしない」を注入して是正する。
# フラグ非対応の古い CLI では skip（起動を壊さない）。素の claude-safe には影響しない。
if [ "${DS_CLAUDE_MODE:-}" = "1" ]; then
  _honesty="$(cd "$(dirname "$0")" && pwd)/../common/deepseek-honesty-prompt.txt"
  if [ -f "$_honesty" ] && claude --help 2>&1 | grep -q -- "--append-system-prompt"; then
    claude_args+=(--append-system-prompt "$(cat "$_honesty")")
  fi

  # d-claude に web 検索を与える（Gemini grounding の MCP ツール `web_search`）。標準 WebSearch は
  # Anthropic サーバー側実装で DeepSeek バックエンドでは動かないため、検索のみの自前 MCP を追加する。
  # 既存の Gemini キー(~/.ai-safety/gemini-api-key.txt)を使い回すので受講者は新規アカウント不要。
  # d-claude 限定（DS_CLAUDE_MODE 下）で --mcp-config 追加。無効化は AI_SAFE_DCLAUDE_SEARCH=0。
  # JSON はパスのエスケープ事故を避けるため node で書き出す（d-claude 経路では node 必須）。
  # d-claude に「簡単な画像生成」も与える（Pollinations の MCP ツール `generate_image`）。
  # 無料で画像を作れるのは受講者環境では実質 Pollinations のみ（codex 無料枠=usage limit /
  # Gemini 無料 API=画像モデル limit:0）。API キー不要・無登録。無効化は AI_SAFE_DCLAUDE_IMAGE=0。
  # 検索 MCP と画像 MCP を 1 つの --mcp-config JSON に束ねて渡す（有効なものだけ載せる）。
  # 画像生成は 3 系統（2026-10 の授業方針: agy が標準）:
  #   generate_image_agy=agy（標準。Google アカウント無料・日本語文字入り・参考画像を渡せる・最大 10 分待つ）/
  #   generate_image=Pollinations（無認証・文字なし向け・速い）/ generate_image_gpt=下記（ChatGPT 有料プラン向け）。
  # 切替: AI_SAFE_DCLAUDE_IMAGE=0（Pollinations 無効）/ AI_SAFE_DCLAUDE_AGY_IMAGE=0（agy 無効）。
  # d-claude に Gemini の画像読取（MCP ツール `describe_image`）も与える。2026-10 からは通常モデルの
  # deepseek-flash が画像を直接見られる（Gateway も flash 宛ては画像を通す）ので、これは
  # deepseek-v4-pro（画像を見られない）に切り替えたときや、文字を正確に書き出したいときの補助。
  # 切替: AI_SAFE_DCLAUDE_VISION=0（無効化）。
  _search_mcp="$(cd "$(dirname "$0")" && pwd)/../common/gemini-search-mcp.js"
  _image_mcp="$(cd "$(dirname "$0")" && pwd)/../common/pollinations-image-mcp.js"
  _agy_mcp="$(cd "$(dirname "$0")" && pwd)/../common/agy-image-mcp.js"
  # generate_image_gpt=GPT Image（Codex 経由・ChatGPT 有料プラン向け・参考画像を渡せる・最大 10 分待つ）。
  # 切替: AI_SAFE_DCLAUDE_CODEX_IMAGE=0。プロンプトと参考画像はそのまま OpenAI へ送られる（Gateway は通らない）。
  _codex_img_mcp="$(cd "$(dirname "$0")" && pwd)/../common/codex-image-mcp.js"
  _vision_mcp="$(cd "$(dirname "$0")" && pwd)/../common/gemini-vision-mcp.js"
  _playwright_mcp="$(cd "$(dirname "$0")" && pwd)/../common/playwright-mcp.js"
  _use_search=0; _use_image=0; _use_agy=0; _use_codex_img=0; _use_vision=0; _use_playwright=0
  [ "${AI_SAFE_DCLAUDE_SEARCH:-1}" = "1" ] && [ -f "$_search_mcp" ] && _use_search=1
  [ "${AI_SAFE_DCLAUDE_IMAGE:-1}" = "1" ] && [ -f "$_image_mcp" ] && _use_image=1
  [ "${AI_SAFE_DCLAUDE_AGY_IMAGE:-1}" = "1" ] && [ -f "$_agy_mcp" ] && _use_agy=1
  [ "${AI_SAFE_DCLAUDE_CODEX_IMAGE:-1}" = "1" ] && [ -f "$_codex_img_mcp" ] && _use_codex_img=1
  [ "${AI_SAFE_DCLAUDE_VISION:-1}" = "1" ] && [ -f "$_vision_mcp" ] && _use_vision=1
  [ "${AI_SAFE_DCLAUDE_PLAYWRIGHT:-1}" = "1" ] && [ -f "$_playwright_mcp" ] && _use_playwright=1
  if [ $((_use_search + _use_image + _use_agy + _use_codex_img + _use_vision + _use_playwright)) -gt 0 ] \
     && command -v node >/dev/null 2>&1 && claude --help 2>&1 | grep -q -- "--mcp-config"; then
    _mcp_cfg="$AI_SAFE_LOG_DIR/d-claude-mcp.json"
    mkdir -p "$AI_SAFE_LOG_DIR" 2>/dev/null || true
    # JSON はパスのエスケープ事故を避けるため node で書き出す（d-claude 経路では node 必須）。
    # 引数: 出力先, search(js or ""), image, agy, vision, playwright, codex-image（各 js or ""）
    if node -e '
      const fs=require("fs");
      const servers={};
      if(process.argv[2]) servers["gemini-search"]={command:"node",args:[process.argv[2]]};
      if(process.argv[3]) servers["pollinations-image"]={command:"node",args:[process.argv[3]]};
      if(process.argv[4]) servers["agy-image"]={command:"node",args:[process.argv[4]]};
      if(process.argv[5]) servers["gemini-vision"]={command:"node",args:[process.argv[5]]};
      if(process.argv[6]) servers["playwright"]={command:"node",args:[process.argv[6]]};
      if(process.argv[7]) servers["codex-image"]={command:"node",args:[process.argv[7]]};
      fs.writeFileSync(process.argv[1],JSON.stringify({mcpServers:servers}));
    ' "$_mcp_cfg" "$([ $_use_search -eq 1 ] && printf '%s' "$_search_mcp")" "$([ $_use_image -eq 1 ] && printf '%s' "$_image_mcp")" "$([ $_use_agy -eq 1 ] && printf '%s' "$_agy_mcp")" "$([ $_use_vision -eq 1 ] && printf '%s' "$_vision_mcp")" "$([ $_use_playwright -eq 1 ] && printf '%s' "$_playwright_mcp")" "$([ $_use_codex_img -eq 1 ] && printf '%s' "$_codex_img_mcp")" 2>/dev/null; then
      claude_args+=(--mcp-config "$_mcp_cfg")
      # 補助ツール（MCP）の起動待ちを長めにする。Playwright を事前に入れていない PC の
      # 最初の起動はダウンロードを待つので、既定の待ち時間だと時間切れになる（教室一斉起動・2026-10）。
      # 利用者が MCP_TIMEOUT を指定していればそれを優先する。単位はミリ秒（Claude Code 公式）。
      export MCP_TIMEOUT="${MCP_TIMEOUT:-90000}"
    fi
  fi
fi

if [ -n "$prompt" ]; then
  claude "${claude_args[@]}" "$prompt"
else
  claude "${claude_args[@]}"
fi
