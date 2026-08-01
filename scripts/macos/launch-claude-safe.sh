#!/usr/bin/env bash
set -euo pipefail

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
# --assisted opt-in: 2 鍵グレーゾーン自動承認を有効化（既定 OFF）。フラグを引数列から
# 取り除いてから従来の位置引数（workspace / prompt）を解釈する。事前に環境変数
# AI_SAFE_ASSISTED_APPROVAL=1 が立っている場合もそのまま尊重して引き継ぐ。
_args=()
for _a in "$@"; do
  if [ "$_a" = "--assisted" ]; then
    export AI_SAFE_ASSISTED_APPROVAL=1
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
if [ "${DS_CLAUDE_MODE:-}" != "1" ] && [ "${BOUNCER_INTEGRATED_MODE:-}" != "1" ]; then
  unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL ANTHROPIC_CUSTOM_MODEL_OPTION
elif [ "${BOUNCER_INTEGRATED_MODE:-}" = "1" ]; then
  # Bouncer最大保護は通常のClaude認証を使い、接続先だけloopbackへ向ける。
  unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL ANTHROPIC_CUSTOM_MODEL_OPTION
fi

[ -f "$settings" ] || { echo "Claude の安全設定ファイルが見つかりませんでした。" >&2; echo "先に「導入(インストール)」を実行してから、もう一度この起動ボタンを押してください。" >&2; echo "（確認した場所: ${settings}）" >&2; exit 2; }
[ -f "$AI_SAFE_POLICY" ] || { echo "AI安全パッケージがこのフォルダにまだ導入されていません。" >&2; echo "対象フォルダ: $workspace" >&2; echo "先に「導入(インストール)」を実行してから、もう一度この起動ボタンを押してください。" >&2; exit 2; }

# claude バイナリ検出（PATH 不在時は日本語で案内し、bash の "command not found" を防ぐ）。
if ! command -v claude >/dev/null 2>&1; then
  echo "claude コマンドが見つかりません。" >&2
  echo "先に Claude Code をインストールしてください（例: npm install -g @anthropic-ai/claude-code@2.1.201）。" >&2
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

# --permission-mode の対応有無を help で判定（非対応の Claude Code でも壊れないように）
claude_args=(--settings "$settings" --setting-sources user,project,local)
if claude --help 2>&1 | grep -q -- "--permission-mode"; then
  claude_args=(--permission-mode default "${claude_args[@]}")
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
  # 画像は 2 系統: generate_image=Pollinations（無認証・文字なし向け・速い）/
  # generate_image_agy=agy（Google アカウント無料・日本語文字入り/高品質・1枚20秒前後）。
  # 切替: AI_SAFE_DCLAUDE_IMAGE=0（Pollinations 無効）/ AI_SAFE_DCLAUDE_AGY_IMAGE=0（agy 無効）。
  # d-claude に「目」も与える（Gemini 画像読取の MCP ツール `describe_image`）。DeepSeek は
  # 画像入力を黙殺する（実測）ため、スクショ/画像を Gemini に見せてテキストで返してもらう
  # （画像生成 MCP の逆・画像→テキスト）。画像“入力”は無料 Gemini キーで通る（実測）。
  # 切替: AI_SAFE_DCLAUDE_VISION=0（無効化）。
  _search_mcp="$(cd "$(dirname "$0")" && pwd)/../common/gemini-search-mcp.js"
  _image_mcp="$(cd "$(dirname "$0")" && pwd)/../common/pollinations-image-mcp.js"
  _agy_mcp="$(cd "$(dirname "$0")" && pwd)/../common/agy-image-mcp.js"
  _vision_mcp="$(cd "$(dirname "$0")" && pwd)/../common/gemini-vision-mcp.js"
  _use_search=0; _use_image=0; _use_agy=0; _use_vision=0
  [ "${AI_SAFE_DCLAUDE_SEARCH:-1}" = "1" ] && [ -f "$_search_mcp" ] && _use_search=1
  [ "${AI_SAFE_DCLAUDE_IMAGE:-1}" = "1" ] && [ -f "$_image_mcp" ] && _use_image=1
  [ "${AI_SAFE_DCLAUDE_AGY_IMAGE:-1}" = "1" ] && [ -f "$_agy_mcp" ] && _use_agy=1
  [ "${AI_SAFE_DCLAUDE_VISION:-1}" = "1" ] && [ -f "$_vision_mcp" ] && _use_vision=1
  if [ $((_use_search + _use_image + _use_agy + _use_vision)) -gt 0 ] \
     && command -v node >/dev/null 2>&1 && claude --help 2>&1 | grep -q -- "--mcp-config"; then
    _mcp_cfg="$AI_SAFE_LOG_DIR/d-claude-mcp.json"
    mkdir -p "$AI_SAFE_LOG_DIR" 2>/dev/null || true
    # JSON はパスのエスケープ事故を避けるため node で書き出す（d-claude 経路では node 必須）。
    # 引数: 出力先, search(js or ""), image(js or ""), agy(js or ""), vision(js or "")
    # ※ `node -e 'CODE' a b c` では最初のユーザ引数が argv[1]（-e はスクリプトを argv に
    #   含めない）。出力先=argv[1] / 各 MCP=argv[2..5]。以前 argv[2]/argv[3..] としていたのは
    #   off-by-one で、search-mcp.js を JSON で上書きし・登録パスがずれ・vision が未登録だった。
    if node -e '
      const fs=require("fs");
      const servers={};
      if(process.argv[2]) servers["gemini-search"]={command:"node",args:[process.argv[2]]};
      if(process.argv[3]) servers["pollinations-image"]={command:"node",args:[process.argv[3]]};
      if(process.argv[4]) servers["agy-image"]={command:"node",args:[process.argv[4]]};
      if(process.argv[5]) servers["gemini-vision"]={command:"node",args:[process.argv[5]]};
      fs.writeFileSync(process.argv[1],JSON.stringify({mcpServers:servers}));
    ' "$_mcp_cfg" "$([ $_use_search -eq 1 ] && printf '%s' "$_search_mcp")" "$([ $_use_image -eq 1 ] && printf '%s' "$_image_mcp")" "$([ $_use_agy -eq 1 ] && printf '%s' "$_agy_mcp")" "$([ $_use_vision -eq 1 ] && printf '%s' "$_vision_mcp")" 2>/dev/null; then
      claude_args+=(--mcp-config "$_mcp_cfg")
    fi
  fi
fi

if [ -n "$prompt" ]; then
  claude "${claude_args[@]}" "$prompt"
else
  claude "${claude_args[@]}"
fi
