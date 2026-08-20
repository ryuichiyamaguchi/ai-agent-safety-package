#!/bin/bash
# update-ai-tools.sh — AI ツール本体 (npm パッケージ) をまとめて更新する。
#
# 対象:
#   - Codex CLI     : npm install -g @openai/codex@latest
#   - Claude Code   : npm install -g @anthropic-ai/claude-code@<動作確認済み版>
#                     (最新版にはしない。版は tested-tool-versions.json が SSOT)
#   - OpenCode      : npm install -g opencode-ai@latest
# 対象外:
#   - agy (AntiGravity): 公式の自動更新に任せる (案内のみ表示)
#   - Gemini CLI       : 移行済み・対象外
#
# 方針 (設計書 §4-3):
#   - 未インストールのツールはスキップする (新規インストールはさせない)
#   - 1 つ失敗しても残りを続行し、最後にまとめを表示する
#   - sudo はしない (npm global の権限エラーは案内だけ出す)
#
# 使い方: update-ai-tools.sh [workspace]
set -u

workspace="${1:-$(pwd)}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

echo ""
echo " == AI ツールを最新版に更新します =="
echo ""
echo " 更新するもの（入っているものだけ）:"
echo "   ・Codex CLI    → 最新版"
echo "   ・Claude Code  → 最新版"
echo "   ・OpenCode     → 最新版"
echo " 更新しないもの:"
echo "   ・agy (AntiGravity) → 公式の自動更新に任せます（作業フォルダの docs/09_各AIのインストール.md を参照）"
echo ""
read -r -p " Enter で続行します（やめるときは Ctrl+C）: " _

# --- npm の存在確認 ----------------------------------------------------------
if ! command -v npm >/dev/null 2>&1; then
  echo ""
  echo "【失敗】Node.js (npm) が入っていません。"
  echo " スタート.html の Step 0 に戻って Node.js を入れてから、もう一度このボタンを押してください。"
  exit 1
fi

results=""
add_result() { results="${results}${1}"$'\n'; }

tool_version() {
  # $1: コマンド名。--version の出力から x.y.z を 1 つ取り出す
  "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

fail_hint() {
  # $1: ツール名（日本語表示用）
  echo "【失敗】$1 を更新できませんでした。よくある原因: ①ネット接続 ②npm が見つからない（スタート.html の Step 0 をやり直す）。"
  echo " もう一度このボタンを押して直らなければ、10_困ったとき診断 を実行してください。"
  echo " （macOS で権限エラー (EACCES) が出た場合は、Node.js を公式 LTS インストーラで入れ直してください。sudo は使いません）"
}

update_tool() {
  # $1: 表示名 / $2: コマンド名 / $3: npm パッケージ指定 (name@version)
  name="$1"; cmd="$2"; pkg="$3"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo ""
    echo "── $name: 入っていないためスキップします（新規インストールはしません）"
    add_result "$name: スキップ (未インストール)"
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

update_tool "Codex CLI" "codex" "@openai/codex@latest"

# Claude Code は最新版に追従する（2026-08-20 に固定をやめた）。Codex / OpenCode と同じ
# update_tool を通す（未インストールならスキップする挙動も共通）。
update_tool "Claude Code" "claude" "@anthropic-ai/claude-code@$claude_pin"

update_tool "OpenCode" "opencode" "opencode-ai@latest"

echo ""
echo "── agy (AntiGravity) はこのボタンでは更新しません。"
echo "   公式の自動更新に任せます（手動でやり直す場合は説明書 09_各AIのインストール の公式手順で）。"
add_result "agy: 対象外 (公式の自動更新に任せる)"

echo ""
echo " == 結果まとめ =="
printf '%s' "$results" | sed 's/^/   /'
echo ""
echo " いまの版:"
echo "   node:        $(node -v 2>/dev/null || echo 不明)"
command -v codex >/dev/null 2>&1 && echo "   Codex CLI:   $(tool_version codex)"
command -v claude >/dev/null 2>&1 && echo "   Claude Code: $(tool_version claude)"
command -v opencode >/dev/null 2>&1 && echo "   OpenCode:    $(tool_version opencode)"
echo ""
