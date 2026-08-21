#!/usr/bin/env bash
# launch-longrun.sh — 「長時間おまかせモード」で AI を起動する（mac 側の実体）。
#
# ねらい:
#   目を離して AI に長く作業させたいとき、承認ダイアログで止まらずに進める。
#   ただし「全部素通し」にはしない。**その環境で使える最大限の守りを効かせたうえで**、
#   確認だけを省く。
#
# 対応:
#   Claude / Codex / OpenCode / AntiGravity(agy) の 4 つ。mac / Windows の両方で使える
#   （Windows 側の実体は scripts/windows/launch-longrun.ps1）。
#
# 「壁」の有無（この判定がこのモードの中心）:
#   壁 = OS が作業フォルダの外への書き込みを強制的に止める仕組み（サンドボックス）。
#     ・mac の Claude … Claude Code 純正サンドボックス（Seatbelt）→ 壁あり
#     ・mac の Codex  … Codex 純正サンドボックス（--sandbox workspace-write）→ 壁あり
#     ・OpenCode / agy … 壁なし（agy の --sandbox は独立検証されていないので壁として数えない）
#   壁がある環境: 従来どおり内容を表示して Enter で起動。
#   壁が無い環境: **一度だけ確認を取る**。「壁が無いこと」「止まるのは危険コマンドの
#     禁止リストだけであること」を示し、明示的に「はい」と入力してもらってから進む。
#     ※ v1.17.0 までは壁が無い環境では起動を拒否していた。これは実装側が勝手に安全側へ
#       倒した設計で、依頼者の意図と違ったため v1.17.1 で撤廃した。
#
# どの環境でも外さないもの:
#   - **deny 床は 1 本も外さない**（再帰削除・秘密ファイルの読み取り・リモートコード実行など）。
#   - **`disableBypassPermissionsMode: "disable"` を維持**する。「全部素通し」
#     （bypassPermissions）は使わない。
#   - 記録（hooks / 監査ログ）は 1 つも外さない。
#   - **恒久的な設定ファイルを書き換えない**。一時設定を作り、終了時に trap で必ず消す。
#
# ask の扱い（全エンジン共通）:
#   ask（確認して通す枠）は空にする。無人では答える人がいないので、ask が出た時点で
#   セッションが止まり、このモードの意味が無くなるため。ただし自動許可へは倒さず、
#   **deny 側へ寄せる**（git push / sudo / 対話前提のランチャー起動など）。
#   必要になったら通常のボタン（2〜5）で人が見ながらやる。
#
# 使い方: bash launch-longrun.sh [workspace] [claude|codex|opencode|agy] [prompt]
set -euo pipefail

unset AI_SAFE_POLICY AI_SAFE_ROOT

workspace="${1:-$(pwd)}"
engine="${2:-}"
prompt="${3:-}"

if [ ! -d "$workspace" ]; then
  echo "作業フォルダが見つかりません: $workspace" >&2
  exit 2
fi
workspace="$(cd "$workspace" && pwd)"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"
hooks="$AI_SAFE_ROOT/hooks/macos"

if [ ! -f "$AI_SAFE_POLICY" ]; then
  echo "このフォルダには安全パッケージが入っていません: $workspace" >&2
  echo "「（上級）14_新しい作業フォルダを安全にする」でこのフォルダを安全にしてから、もう一度実行してください。" >&2
  exit 2
fi

# 素の Claude（ログイン認証）で動かす。DeepSeek 連携の置き土産を持ち込まない。
unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
      ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL \
      CLAUDE_CODE_EFFORT_LEVEL ANTHROPIC_CUSTOM_MODEL_OPTION \
      ANTHROPIC_CUSTOM_MODEL_OPTION_NAME ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION DS_CLAUDE_MODE 2>/dev/null || true

# --- 外部コマンドの呼び出しには必ず上限をかける -------------------------------------
# `claude -p` と `security`（キーチェーン）で「返ってこない」事故が過去に複数回起きている。
# macOS に timeout コマンドは無いので perl の alarm でラップする（perl は macOS 標準）。
# `or exit 127`: exec 自体に失敗したときに perl が 0 で抜けるのを防ぐ（フェイルクローズ）。
run_limited() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e '$SIG{ALRM}=sub{exit 124};alarm shift;exec @ARGV or exit 127' "$secs" "$@"
  else
    "$@"
  fi
}

# --- エンジンを選ぶ ------------------------------------------------------------------
engine_label() {
  case "$1" in
    claude) printf 'Claude' ;;
    codex) printf 'Codex' ;;
    opencode) printf 'OpenCode' ;;
    agy) printf 'AntiGravity' ;;
  esac
}

# 壁（OS のサンドボックス）が効くかどうか。効くなら 0、効かないなら 1 を返す。
claude_settings="$workspace/.claude/settings.json"
has_wall() {
  case "$1" in
    claude)
      # 実体（sandbox-exec）と、この作業フォルダの設定（sandbox.enabled）の両方を見る。
      [ -x /usr/bin/sandbox-exec ] || return 1
      [ -f "$claude_settings" ] || return 1
      command -v node >/dev/null 2>&1 || return 1
      run_limited 20 node -e '
        const fs=require("fs");
        const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
        process.exit(s && s.sandbox && s.sandbox.enabled === true ? 0 : 1);
      ' "$claude_settings" >/dev/null 2>&1 || return 1
      return 0
      ;;
    codex)
      # Codex 純正サンドボックス（--sandbox workspace-write）。mac では Seatbelt で効く。
      [ -x /usr/bin/sandbox-exec ] || return 1
      return 0
      ;;
    # OpenCode には OS の壁が無い。agy の --sandbox は独立検証されていないので壁に数えない。
    opencode|agy) return 1 ;;
    *) return 1 ;;
  esac
}

wall_text() { if has_wall "$1"; then printf '壁あり'; else printf '壁なし'; fi; }

if [ -z "$engine" ]; then
  cat <<EOF

════════════════════════════════════════════════════════
  長時間おまかせモード（目を離す前提のモードです）
════════════════════════════════════════════════════════

  対象の作業フォルダ: $(basename "$workspace")
  （フルパス: ${workspace}）

  どの AI におまかせしますか。番号を入れて Enter を押してください。

    1) Claude       （$(wall_text claude)）
    2) Codex        （$(wall_text codex)）
    3) OpenCode     （$(wall_text opencode)）
    4) AntiGravity  （$(wall_text agy)）

    0) やめる

  ※「壁」= OS が作業フォルダの外への書き込みを止める仕組みです。
    壁が無いものを選んだ場合は、このあと確認が 1 回出ます。

EOF
  printf '番号: '
  read -r _choice || true
  case "${_choice:-}" in
    1) engine="claude" ;;
    2) engine="codex" ;;
    3) engine="opencode" ;;
    4) engine="agy" ;;
    0|"") echo "やめました。"; exit 0 ;;
    *) echo "1〜4 の番号を入れてください。" >&2; exit 2 ;;
  esac
fi

case "$engine" in
  claude|codex|opencode|agy) ;;
  *) echo "使い方: bash launch-longrun.sh [workspace] [claude|codex|opencode|agy] [prompt]" >&2; exit 2 ;;
esac

# --- 起動前の説明（対象フォルダ・壁の有無・止まるもの/止まらないもの） ---------------
if has_wall "$engine"; then wall=1; else wall=0; fi

cat <<EOF

════════════════════════════════════════════════════════
  長時間おまかせモード / $(engine_label "$engine")
════════════════════════════════════════════════════════

  対象の作業フォルダ: $(basename "$workspace")
  （フルパス: ${workspace}）

EOF

if [ "$wall" -eq 1 ]; then
  cat <<EOF
  この環境には「壁」があります。
  承認を省けるのは、OS の壁（サンドボックス）が
    ・作業フォルダの外への書き込み
    ・許可していないサイトへの通信
  を止めているからです。
  壁を立てられなかったときは起動しない設定にしています（壁なしで走ることはありません）。

EOF
else
  cat <<EOF
  ⚠ この環境には「壁」がありません。
  壁（OS による書き込み制限）が使えないため、AI が作業フォルダの外の
  ファイルを書き換えることを OS の力で止めることはできません。
  止まるのは危険コマンドの禁止リストだけです。

EOF
fi

cat <<EOF
  それでも止まるもの（外していません）:
    ・再帰削除（rm -rf など）
    ・秘密ファイルの読み取り（.env / SSH 鍵 / クラウドの資格情報）
    ・ダウンロードしたものをそのまま実行する形
    ・sudo / git push / git reset / git checkout / git restore / git rebase
    ・「全部素通しモード」への切り替えそのもの
  記録（見張りと監査ログ）は、どの環境でも残ります。

  止まらないもの（気をつけてください）:
    ・作業フォルダの中のファイルの読み取り・書き換え・削除
EOF

if [ "$wall" -eq 0 ]; then
  cat <<EOF
    ・作業フォルダの外への書き込み（OS では止められません）
EOF
fi

cat <<EOF
    → この作業フォルダに大事なファイルを置かないでください。
    → 終わったら「6_見守りモニターを起動」や記録で、何をしたか必ず確認してください。

EOF

if [ "$wall" -eq 1 ]; then
  printf '上の内容でよければ Enter、やめるなら Ctrl+C を押してください: '
  read -r _ || true
else
  # 壁が無い環境では、一度だけ明示的な同意を取る（依頼者の裁定）。
  echo "  この環境には壁（OS による書き込み制限）がありません。"
  echo "  止まるのは危険コマンドの禁止リストだけです。"
  echo "  目を離す前提で続けますか。"
  echo ""
  printf '  続けるなら「はい」と入力して Enter（やめるなら Enter だけ）: '
  read -r _consent || true
  case "${_consent:-}" in
    はい|ハイ|はい。|yes|Yes|YES|y|Y) ;;
    *) echo ""; echo "やめました。"; exit 0 ;;
  esac
  echo ""
fi

echo "長時間おまかせモードで起動します。"
echo ""

cd "$workspace"

case "$engine" in
  codex)
    exec bash "$hooks/launch-codex-safe.sh" "$workspace" "$prompt" --longrun
    ;;
  agy)
    exec bash "$hooks/launch-agy-safe.sh" "$workspace" "$prompt" --longrun
    ;;
  opencode)
    # OpenCode は統合ランチャー経由で起動する（見守りモニターと送信検査ゲートウェイが
    # そこで一緒に立ち上がるため。本体を直接叩くと画面に何も出ないまま AI が動く）。
    exec bash "$hooks/launch-integrated.sh" "$workspace" opencode standard --longrun
    ;;
esac

# --- ここから Claude 専用の経路 -------------------------------------------------------
# 恒久的な設定ファイル（<ワークスペース>/.claude/settings.json や ~/.claude/settings.json）は
# **書き換えない**。ワークスペースの設定を読み、このモード用の差分だけを当てた JSON を
# 一時フォルダ（700・終了時に必ず削除）へ書き出し、`claude --settings <一時ファイル>` で渡す。
if [ ! -f "$claude_settings" ]; then
  echo "この作業フォルダに Claude の安全設定がありません: $claude_settings" >&2
  echo "「8_安全パッケージを最新版に更新」を実行して設定を入れ直してください。" >&2
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

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ai-safe-longrun.XXXXXX")"
chmod 700 "$tmp_dir"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT INT TERM HUP
tmp_settings="$tmp_dir/settings.json"

AI_SAFE_LONGRUN_WALL="$wall" run_limited 30 node -e '
  const fs = require("fs");
  const src = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const wall = process.env.AI_SAFE_LONGRUN_WALL === "1";
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
  if (wall) {
    // 壁と記録は 1 つも外さない（そのまま持ち込む）。念のため壁を明示的に立て直す。
    //
    // failIfUnavailable: 壁（Seatbelt）を立ち上げられなかったとき、素通しで走らずに失敗させる。
    // 壁がある前提で承認を省く経路なので、宣言（settings の sandbox.enabled）だけでなく
    // 実起動そのものを条件にしないと前提が崩れる。
    // 実測（Claude Code 2.1.236 のバイナリ内文字列）:
    //   "Sandbox required but unavailable: " / "Error: sandbox required but unavailable: "
    //   ". Set sandbox.failIfUnavailable=false to allow unsandboxed execution."
    // 恒久設定（configs/claude/settings.mac.json）には入れない。通常起動で詰まないように
    // するためであり、承認を全部外すこのモードだけの条件として一時設定にのみ立てる。
    src.sandbox = Object.assign({}, src.sandbox, {
      enabled: true,
      autoAllowBashIfSandboxed: true,
      failIfUnavailable: true,
    });
  }
  fs.writeFileSync(process.argv[2], JSON.stringify(src, null, 2));
' "$claude_settings" "$tmp_settings"
chmod 600 "$tmp_settings"

claude_args=(--settings "$tmp_settings" --setting-sources user,project,local)
# `claude --help` が返ってこない事故が過去にあったので、上限 30 秒で打ち切る。
# 打ち切られた場合は --permission-mode を付けない（設定側の defaultMode で足りる）。
if run_limited 30 claude --help 2>&1 | grep -q -- "--permission-mode"; then
  claude_args=(--permission-mode acceptEdits "${claude_args[@]}")
fi

echo "（終了すると一時設定は自動で消えます）"
echo ""

if [ -n "$prompt" ]; then
  claude "${claude_args[@]}" "$prompt"
else
  claude "${claude_args[@]}"
fi
