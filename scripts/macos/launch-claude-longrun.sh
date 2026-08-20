#!/usr/bin/env bash
# launch-claude-longrun.sh — 「長時間おまかせモード」で Claude Code を起動する。
#
# ねらい:
#   目を離して AI に長く作業させたいとき、承認ダイアログで止まらずに進める。
#   ただし「全部素通し」にはしない。承認を省ける理由は **OS の壁（サンドボックス）が
#   あるから** であって、「人が許したから」ではない。したがって:
#
#   - Claude Code の純正サンドボックス（`sandbox.enabled`）が **有効な環境でしか起動しない**。
#     公式にサポートされるのは macOS / Linux / WSL2 のみで、ネイティブ Windows は非対応。
#     このスクリプトは macOS 専用。壁が無い環境では理由を出して起動を拒否する。
#   - 壁はワークスペースの `.claude/settings.json` でしか効かないため、**導入済みの
#     作業フォルダ以外では起動しない**。
#   - **deny 床は 1 本も外さない**（再帰削除・秘密ファイルの読み取り・リモートコード実行など）。
#   - **`disableBypassPermissionsMode: "disable"` を維持**する。いわゆる「全部素通し」
#     （bypassPermissions）は使わない。
#   - 通信は `sandbox.network.allowedDomains` のまま（許可ドメインのみ）。
#   - 記録（hooks / 監査ログ）は 1 つも外さない。
#
# 実装方式:
#   恒久的な設定ファイル（<ワークスペース>/.claude/settings.json や ~/.claude/settings.json）は
#   **書き換えない**。ワークスペースの設定を読み、このモード用の差分だけを当てた JSON を
#   一時フォルダ（700・終了時に必ず削除）へ書き出し、`claude --settings <一時ファイル>` で
#   渡す。モードを抜ければ設定は元のまま。
#
#   このモードでの差分は 1 か所だけ:
#     permissions.ask（git push / git reset / git checkout / git restore / git rebase / sudo）を
#     **すべて deny へ移し、ask を空にする**。
#     理由: 目を離している間に ask が出ると、答える人がいないのでセッションはそこで止まり、
#     このモードの意味が無くなる。かといって自動許可にすると「取り消しにくい公開」や
#     「ローカルの作業を壊す操作」が無人で通る。したがって **止める側に倒す**。
#     必要になったら、通常のボタン（3_セーフClaudeを起動 / claude-safe）で人が見ながらやる。
#
# 使い方: bash launch-claude-longrun.sh [workspace] [prompt]
set -euo pipefail

unset AI_SAFE_POLICY AI_SAFE_ROOT

workspace="${1:-$(pwd)}"
prompt="${2:-}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "長時間おまかせモードは、いまは Mac でだけ使えます。" >&2
  echo "理由: このモードは「OS の壁（サンドボックス）があるから承認を省ける」という考え方で作ってあり、" >&2
  echo "      Claude Code の純正サンドボックスは macOS / Linux / WSL2 だけの対応です。" >&2
  echo "      Windows では壁が使えないため、承認を省くと本当に無防備になります。" >&2
  echo "Windows の方は、いつもどおり「3_セーフClaudeを起動」を使ってください。" >&2
  exit 2
fi

if [ ! -d "$workspace" ]; then
  echo "作業フォルダが見つかりません: $workspace" >&2
  exit 2
fi
workspace="$(cd "$workspace" && pwd)"
settings="$workspace/.claude/settings.json"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

# 素の Claude（ログイン認証）で動かす。DeepSeek 連携の置き土産を持ち込まない。
unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
      ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL \
      CLAUDE_CODE_EFFORT_LEVEL ANTHROPIC_CUSTOM_MODEL_OPTION DS_CLAUDE_MODE 2>/dev/null || true

if [ ! -f "$settings" ] || [ ! -f "$AI_SAFE_POLICY" ]; then
  echo "このフォルダには安全パッケージが入っていません: $workspace" >&2
  echo "長時間おまかせモードは、壁（サンドボックス）が効く作業フォルダでしか起動できません。" >&2
  echo "「（上級）14_新しい作業フォルダを安全にする」でこのフォルダを安全にしてから、もう一度実行してください。" >&2
  exit 2
fi

if [ ! -x /usr/bin/sandbox-exec ]; then
  echo "この Mac では /usr/bin/sandbox-exec（OS の壁）が見つかりません。" >&2
  echo "壁が無い状態で承認を省くのは危ないので、長時間おまかせモードは起動しません。" >&2
  exit 2
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node コマンドが見つかりません（このモードの設定づくりに必要です）。" >&2
  echo "先に Node.js（LTS 版）を入れてください。" >&2
  exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "claude コマンドが見つかりません。" >&2
  echo "先に Claude Code をインストールしてください（例: npm install -g @anthropic-ai/claude-code@latest）。" >&2
  exit 1
fi

# 壁が本当に有効か（settings.json の sandbox.enabled）を確認する。
if ! node -e '
  const fs=require("fs");
  const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  process.exit(s && s.sandbox && s.sandbox.enabled === true ? 0 : 1);
' "$settings" 2>/dev/null; then
  echo "この作業フォルダの Claude 設定でサンドボックス（壁）が有効になっていません。" >&2
  echo "長時間おまかせモードは、壁がある場合にだけ起動します。" >&2
  echo "「7_安全パッケージを最新版に更新」を実行して設定を入れ直してください。" >&2
  exit 2
fi

cat <<EOF

════════════════════════════════════════════════════════
  長時間おまかせモード（目を離す前提のモードです）
════════════════════════════════════════════════════════

  対象の作業フォルダ: $(basename "$workspace")
  （フルパス: ${workspace}）

  このモードでは、確認ダイアログをほとんど出さずに AI が作業を進めます。
  承認を省けるのは、OS の壁（サンドボックス）が
    ・作業フォルダの外への書き込み
    ・許可していないサイトへの通信
  を止めているからです。
  このモードでは「壁を立てられなかったら起動しない」設定
  （sandbox.failIfUnavailable）にしています。壁なしで走ることはありません。

  それでも止まるもの（外していません）:
    ・再帰削除（rm -rf など）
    ・秘密ファイルの読み取り（.env / SSH 鍵 / クラウドの資格情報）
    ・ダウンロードしたものをそのまま実行する形
    ・sudo / git push / git reset / git checkout / git restore / git rebase
    ・「全部素通しモード」への切り替えそのもの

  止まらないもの（気をつけてください）:
    ・作業フォルダの中のファイルの読み取り・書き換え・削除
    → この作業フォルダに大事なファイルを置かないでください。
    → 終わったら「5_見守りモニターを起動」や記録で、何をしたか必ず確認してください。

EOF

printf '上の内容でよければ Enter、やめるなら Ctrl+C を押してください: '
read -r _ || true

# --- このモード用の一時設定を作る（恒久的な設定ファイルは書き換えない） -----------
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ai-safe-longrun.XXXXXX")"
chmod 700 "$tmp_dir"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT INT TERM HUP
tmp_settings="$tmp_dir/settings.json"

node -e '
  const fs = require("fs");
  const src = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const p = src.permissions || (src.permissions = {});
  const ask = Array.isArray(p.ask) ? p.ask : [];
  const deny = Array.isArray(p.deny) ? p.deny.slice() : [];
  // ask に残っていたものは「無人では答えられない」ので deny 側へ寄せる。緩める方向へは動かさない。
  for (const rule of ask) if (!deny.includes(rule)) deny.push(rule);
  p.ask = [];
  p.deny = deny;
  // 承認は自動で通すが「全部素通し」ではない。bypassPermissions は封じたまま。
  p.defaultMode = "acceptEdits";
  p.disableBypassPermissionsMode = "disable";
  // 壁と記録は 1 つも外さない（そのまま持ち込む）。念のため壁を明示的に立て直す。
  //
  // failIfUnavailable: 壁（Seatbelt）を立ち上げられなかったとき、素通しで走らずに失敗させる。
  // このモードは「壁があるから承認を省ける」という前提で作られているので、宣言（settings の
  // sandbox.enabled）だけでなく実起動そのものを条件にしないと前提が崩れる。
  // 実測（Claude Code 2.1.236 のバイナリ内文字列）:
  //   "Sandbox required but unavailable: " / "Error: sandbox required but unavailable: "
  //   ". Set sandbox.failIfUnavailable=false to allow unsandboxed execution."
  // = true のとき「壁が使えなければ実行しない」が本体側で保証される。
  // 恒久設定（configs/claude/settings.mac.json）には入れない。通常起動で詰まないようにするため
  // であり、承認を全部外すこのモードだけの条件として一時設定にのみ立てる。
  src.sandbox = Object.assign({}, src.sandbox, {
    enabled: true,
    autoAllowBashIfSandboxed: true,
    failIfUnavailable: true,
  });
  fs.writeFileSync(process.argv[2], JSON.stringify(src, null, 2));
' "$settings" "$tmp_settings"
chmod 600 "$tmp_settings"

cd "$workspace"

claude_args=(--settings "$tmp_settings" --setting-sources user,project,local)
if claude --help 2>&1 | grep -q -- "--permission-mode"; then
  claude_args=(--permission-mode acceptEdits "${claude_args[@]}")
fi

echo "長時間おまかせモードで起動します（終了すると一時設定は自動で消えます）。"
echo ""

if [ -n "$prompt" ]; then
  claude "${claude_args[@]}" "$prompt"
else
  claude "${claude_args[@]}"
fi
