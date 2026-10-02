#!/bin/bash
# update-ai-tools.sh — AI ツールをまとめて入れる・更新する（スタート「2_AIツールをまとめて入れる」の実体）。
#
# 対象:
#   - Codex CLI     : npm install -g @openai/codex@latest
#   - Claude Code   : npm install -g @anthropic-ai/claude-code@<tested-tool-versions.json の値>
#   - OpenCode      : npm install -g opencode-ai@latest
#   - agy (AntiGravity CLI): 入っていなければ公式インストーラーで入れる。入っていれば
#                     公式の自動更新に任せる（このボタンでは更新しない）
#   - Playwright MCP: d-claude / OpenCode のブラウザ操作の部品を事前に入れる（v1.19.3〜）
#   - Gemini CLI       : 移行済み・対象外
#
# 方針:
#   - 2026-10（v1.19.5）から、入っていないツールも新しく入れる（旧版は「未インストールは
#     スキップ」だった。受講者が 1 つずつ別の手順で入れる手間をなくすため）。
#   - 1 つ失敗しても残りを続行し、最後にまとめを表示する
#   - sudo はしない (npm global の権限エラーは案内だけ出す)
#   - agy の公式インストーラーは「ダウンロードしてそのまま実行（curl | bash）」と案内されて
#     いるが、ここでは HTTPS で一度ファイルに保存してから実行する（途中で切れた内容を
#     実行しない・取得元を https に限る）
#
# 使い方: update-ai-tools.sh [workspace]
set -u
workspace="${1:-$(pwd)}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGY_INSTALL_URL="https://antigravity.google/cli/install.sh"

# --- 動作確認済み版の表 (SSOT) を探す ---------------------------------------
# 1) workspace 配置版 (install が .ai-safety/ にコピーする)
# 2) リポジトリ直実行時: <repo>/configs/tested-tool-versions.json
versions_json=""
for cand in \
  "$workspace/.ai-safety/tested-tool-versions.json" \
  "$script_dir/../../configs/tested-tool-versions.json"; do
  if [ -f "$cand" ]; then versions_json="$cand"; break; fi
done

json_value() {
  # フラットな JSON から "key": "value" を取り出す (node 不要の簡易版)
  key="$1"
  [ -n "$versions_json" ] || return 0
  sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$versions_json" | head -n1
}

# 2026-08-20: Claude Code の固定版インストールを廃止し、最新版追従にした（純正サンドボックスを
# 使う方針に切り替えたため）。表が無い場合も "latest" にフォールバックして更新を止めない。
claude_pin="$(json_value claudeCode)"
[ -n "$claude_pin" ] || claude_pin="latest"

# agy の場所（launch-agy-safe.sh と同じ探し方: PATH → ~/.local/bin/agy）
agy_path() {
  if command -v agy >/dev/null 2>&1; then command -v agy; return 0; fi
  if [ -x "$HOME/.local/bin/agy" ]; then echo "$HOME/.local/bin/agy"; return 0; fi
  return 1
}

state() {
  # $1: コマンド名 → 「入っている」「入っていない」
  if [ "$1" = "agy" ]; then agy_path >/dev/null 2>&1 && echo "入っている" || echo "入っていない"; return; fi
  command -v "$1" >/dev/null 2>&1 && echo "入っている" || echo "入っていない"
}

plan_line() {
  # $1: 表示名 / $2: コマンド名 / $3: 入っているときにすること
  if [ "$(state "$2")" = "入っている" ]; then
    printf '   ・%-12s → %s\n' "$1" "$3"
  else
    printf '   ・%-12s → 入っていないので新しく入れる\n' "$1"
  fi
}

echo ""
echo " == AI ツールをまとめて入れる・更新する =="
echo ""
echo " これからすること:"
plan_line "Codex CLI" codex "最新版に更新"
plan_line "Claude Code" claude "最新版に更新"
plan_line "OpenCode" opencode "最新版に更新"
plan_line "agy" agy "そのまま（公式の自動更新に任せる）"
echo "   ・Playwright   → d-claude / OpenCode のブラウザ操作の部品（決まった版を先に入れておく）"
echo ""
echo " 入れたあとは、それぞれのツールで一度ログインが必要です（使うツールだけで大丈夫です）。"
echo ""
# AI_SAFE_NO_PROMPT=1 のときは確認を飛ばす（自動テスト用）
if [ "${AI_SAFE_NO_PROMPT:-0}" != "1" ]; then
  read -r -p " Enter で続行します（やめるときは Ctrl+C）: " _
fi

results=""
add_result() { results="${results}${1}"$'\n'; }

tool_version() {
  # $1: コマンド名。--version の出力から x.y.z を 1 つ取り出す
  "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

fail_hint() {
  # $1: ツール名（日本語表示用）
  echo "【失敗】$1 を入れられませんでした。よくある原因: ①ネット接続 ②npm が見つからない（スタート.html の Step 0 をやり直す）。"
  echo " もう一度このボタンを押して直らなければ、9_困ったとき診断 を実行してください。"
  echo " （macOS で権限エラー (EACCES) が出た場合は、Node.js を公式 LTS インストーラで入れ直してください。sudo は使いません）"
}

# --- npm の存在確認（npm の 3 つだけに必要。agy は npm 不要） ------------------
npm_ok=1
if ! command -v npm >/dev/null 2>&1; then
  npm_ok=0
  echo ""
  echo "【注意】Node.js (npm) が入っていません。Codex CLI・Claude Code・OpenCode は入れられません。"
  echo " スタート.html の Step 0 に戻って Node.js を入れてから、もう一度このボタンを押してください。"
  echo " （agy は Node.js が無くても入れられるので、このまま続けます）"
fi

install_or_update_tool() {
  # $1: 表示名 / $2: コマンド名 / $3: npm パッケージ指定 (name@version)
  name="$1"; cmd="$2"; pkg="$3"
  if [ "$npm_ok" -ne 1 ]; then
    add_result "$name: できませんでした（Node.js が入っていない）"
    return 0
  fi
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo ""
    echo "── $name は入っていないので、新しく入れます"
    if npm install -g "$pkg"; then
      hash -r 2>/dev/null || true
      after="$(tool_version "$cmd")"
      add_result "$name: 新しく入れました (${after:-版不明})"
    else
      fail_hint "$name"
      add_result "$name: 失敗（上のメッセージを確認）"
    fi
    return 0
  fi
  before="$(tool_version "$cmd")"
  echo ""
  echo "── $name を更新します（現在の版: ${before:-不明}）"
  if npm install -g "$pkg"; then
    after="$(tool_version "$cmd")"
    if [ -n "$before" ] && [ "$before" = "${after:-}" ]; then
      add_result "$name: 変更なし (${before})"
    else
      add_result "$name: 更新OK (${before:-不明} → ${after:-不明})"
    fi
  else
    fail_hint "$name"
    add_result "$name: 失敗（上のメッセージを確認）"
  fi
  return 0
}

install_or_update_tool "Codex CLI" "codex" "@openai/codex@latest"
# Claude Code は最新版に追従する（2026-08-20 に固定をやめた）。Codex / OpenCode と同じ処理を通す。
install_or_update_tool "Claude Code" "claude" "@anthropic-ai/claude-code@$claude_pin"
install_or_update_tool "OpenCode" "opencode" "opencode-ai@latest"

# --- agy (AntiGravity CLI) -------------------------------------------------
echo ""
if agy_path >/dev/null 2>&1; then
  echo "── agy (AntiGravity) はこのボタンでは更新しません。"
  echo "   公式の自動更新に任せます（手動でやり直す場合は説明書 09_各AIのインストール の公式手順で）。"
  add_result "agy: 入っている（更新は公式の自動更新に任せる）"
else
  echo "── agy (AntiGravity) は入っていないので、公式のインストーラーで新しく入れます"
  agy_tmp="$(mktemp "${TMPDIR:-/tmp}/agy-install.XXXXXX")"
  if curl -fsSL --proto '=https' --proto-redir '=https' "$AGY_INSTALL_URL" -o "$agy_tmp" && [ -s "$agy_tmp" ]; then
    if bash "$agy_tmp"; then
      if p="$(agy_path)"; then
        add_result "agy: 新しく入れました ($p)"
      else
        add_result "agy: 入れましたが、見つかりません（ターミナルを開き直すか、~/.local/bin を PATH に入れてください）"
      fi
    else
      echo "【失敗】agy のインストーラーが途中で止まりました。上のメッセージを確認してください。"
      add_result "agy: 失敗（上のメッセージを確認）"
    fi
  else
    echo "【失敗】agy のインストーラーを取得できませんでした（ネット接続を確認してください）。"
    add_result "agy: 失敗（インストーラーを取得できない）"
  fi
  rm -f "$agy_tmp"
fi

# --- Playwright（d-claude / OpenCode のブラウザ操作）を先に入れておく ------------------
# 入れておかないと d-claude / OpenCode の最初の起動でダウンロードが走り、教室で一斉に
# 起動すると時間切れになる（2026-10 実機）。版は tested-tool-versions.json の playwrightMcp。
prefetch="$script_dir/../common/playwright-prefetch.js"
echo ""
echo "── Playwright（ブラウザ操作の部品）を準備します"
if [ -f "$prefetch" ] && command -v node >/dev/null 2>&1; then
  if node "$prefetch"; then
    add_result "Playwright: 準備OK（起動時にダウンロードしません）"
  else
    add_result "Playwright: 失敗（起動時に取りに行きます。もう一度押すとやり直せます）"
  fi
else
  add_result "Playwright: スキップ（Node.js か部品が見つかりません）"
fi

echo ""
echo " == 結果まとめ =="
printf '%s' "$results" | sed 's/^/   /'
echo ""
echo " いまの版:"
echo "   node:        $(node -v 2>/dev/null || echo 不明)"
command -v codex >/dev/null 2>&1 && echo "   Codex CLI:   $(tool_version codex)"
command -v claude >/dev/null 2>&1 && echo "   Claude Code: $(tool_version claude)"
command -v opencode >/dev/null 2>&1 && echo "   OpenCode:    $(tool_version opencode)"
if p="$(agy_path)"; then echo "   agy:         $(tool_version "$p")"; fi
echo ""
echo " 次にやること: 使うツールに一度ログインしてください（例: スタートの「4_AIを起動する」から起動すると案内が出ます）。"
echo ""
