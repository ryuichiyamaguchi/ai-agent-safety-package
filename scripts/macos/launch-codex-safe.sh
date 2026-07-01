#!/usr/bin/env bash
set -euo pipefail
workspace="${1:-$(pwd)}"
prompt="${2:-}"
auto=0
[ "${3:-}" = "--auto" ] && auto=1
workspace="$(cd "$workspace" && pwd)"
export AI_SAFE_ROOT="$workspace/.ai-safety"
export AI_SAFE_POLICY="$AI_SAFE_ROOT/policy/safety-policy.json"
export AI_SAFE_LOG_DIR="$HOME/.ai-safety/logs"

# A-1: CODEX_HOME は workspace 外 ($HOME/.codex-safe) を向かせる。
# auth.json を workspace ツリーに物理コピーしないことで
# git add / クラウド同期 / workspace zip 化による平文流出を防ぐ。
SAFE_CODEX_HOME="$HOME/.codex-safe"
mkdir -p "$SAFE_CODEX_HOME"
export CODEX_HOME="$SAFE_CODEX_HOME"

# workspace 内 .codex/config.toml が存在すれば .codex-safe/ へコピーして使う。
# auth.json は絶対にコピーしない。
# codex 0.135 fix: 旧版が置いた legacy config.toml (`[profiles.safe]` 入り) が .codex-safe/ に
# 残っていると --profile safe と衝突して fatal error になる。SSOT は workspace の
# .codex/config.toml (install が管理する新版) なので、safe.config.toml と同じく毎回上書きして
# 常に最新を反映させる ("既存ならスキップ" は legacy が永久に残る罠だったため撤廃)。
WORKSPACE_CONFIG="$workspace/.codex/config.toml"
SAFE_CONFIG="$SAFE_CODEX_HOME/config.toml"
if [ -f "$WORKSPACE_CONFIG" ]; then
  cp "$WORKSPACE_CONFIG" "$SAFE_CONFIG"
fi

# codex 0.135: `--profile safe` が参照する $CODEX_HOME/safe.config.toml も配置する。
# (config.toml に `[profiles.safe]` を残すと 0.135 では起動が fatal error になるため分離済み。)
# config.toml が更新されたら safe.config.toml も追従させたいので、両者が揃うよう毎回上書きコピーする。
WORKSPACE_SAFE_PROFILE="$workspace/.codex/safe.config.toml"
SAFE_PROFILE="$SAFE_CODEX_HOME/safe.config.toml"
if [ -f "$WORKSPACE_SAFE_PROFILE" ]; then
  cp "$WORKSPACE_SAFE_PROFILE" "$SAFE_PROFILE"
fi

# Hook trust 自動付与 (codex 0.135+ 対応・最重要):
# codex 0.135 以降は「信頼していないフックを黙ってスキップする」。受講者が /hooks を手動で
# 操作して信頼するまで guard-bash / guard-write / guard-prompt 等が一切発火せず、見守り
# モニターにも何も出ない。受講者に手動信頼をさせないため、launcher が起動のたびに同梱フックの
# 信頼ハッシュを safe.config.toml の [hooks.state] に注入し、最初から Active にする。
# - trusted_hash はフックのコマンド内容由来で workspace の絶対パスに依存しない
#   (mac 実機 + 別パス workspace で同一ハッシュを確認済み)。
# - キーの先頭はその workspace の hooks.json 絶対パス。codex の --cd と同じ正規化なので一致する。
# - IMPORTANT: hooks.mac.json を変更したらこのハッシュ表も再採取して更新すること
#   (採取手順: launcher で TUI 起動 → /hooks → t → $CODEX_HOME/safe.config.toml の [hooks.state])。
HOOKS_JSON="$workspace/.codex/hooks.json"
if [ -f "$HOOKS_JSON" ] && [ -f "$SAFE_PROFILE" ]; then
  {
    echo ""
    echo "[hooks.state]"
    for entry in \
      "pre_tool_use:0:0=8e3477c0afc198cec87895c92defafa4d27efa05d0913c330a82caeaa8899028" \
      "pre_tool_use:1:0=19d86086583458f50be0b06abaad9ee41e541045bde6d3d3421286562d133524" \
      "pre_tool_use:2:0=d51912f2f5ae63364cc4717cb83d02b140b8e5d2344d7d5281be7dbbb96e73ff" \
      "post_tool_use:0:0=ee17e0c0d17e29e611c0ece3f5ee68b2a15d734b4a16ac08d0486a3e10c3b735" \
      "user_prompt_submit:0:0=b5eaf03ab2de6207c7bbef7d2f96b5174caf8878eede9d009508850cb8381c7c" \
    ; do
      key="${entry%%=*}"; hash="${entry#*=}"
      printf '[hooks.state."%s:%s"]\n' "$HOOKS_JSON" "$key"
      printf 'trusted_hash = "sha256:%s"\n' "$hash"
    done
  } >> "$SAFE_PROFILE"
fi

[ -f "$AI_SAFE_POLICY" ] || { echo "AI Safety package is not installed in workspace: $workspace" >&2; exit 2; }
if [ "${AI_SAFE_DRY_RUN:-}" != "1" ]; then
  [ -f "$SAFE_CONFIG" ] || { echo "Codex safety config was not found: $SAFE_CONFIG" >&2; exit 2; }
fi

# A-1: workspace 内 .codex/auth.json に物理ファイルが残っていれば削除する (旧バージョン残骸)。
LEGACY_AUTH="$workspace/.codex/auth.json"
if [ -f "$LEGACY_AUTH" ] && [ ! -L "$LEGACY_AUTH" ]; then
  echo "A-1: Removing legacy physical auth.json from workspace tree: $LEGACY_AUTH" >&2
  rm -f "$LEGACY_AUTH"
fi

# auth.json は $HOME/.codex/auth.json へのシンボリックリンクを .codex-safe/ に張る。
# symlink が既に正しく張られていれば何もしない。
SRC_AUTH="$HOME/.codex/auth.json"
SAFE_AUTH="$SAFE_CODEX_HOME/auth.json"
if [ "${AI_SAFE_DRY_RUN:-}" != "1" ]; then
  if [ ! -f "$SRC_AUTH" ]; then
    echo "Codex auth not found at $SRC_AUTH. Please run 'codex login' first." >&2
    exit 2
  fi
  if [ ! -e "$SAFE_AUTH" ]; then
    ln -sf "$SRC_AUTH" "$SAFE_AUTH"
  fi
fi

# Safe Auto Mode: --auto なら承認を on-failure に下げて自走させる。
# 危険コマンドは PreToolUse hook(guard-bash) が approval 非依存で exit2 deny するため、
# OS 隔離(egress)の実証可否に関わらず自走してよい(診断 2026-06-26 §4 で実証)。
# 隔離チェックは実行して結果を「開示」するのみ(従来の fail-close=untrusted 据え置きは廃止)。
# v1.12.0 教室プロファイル: 既定を untrusted → on-request に変更（モデルが承認要と自己判断
# した時だけ確認）。config/safe.config.toml 側の approvals_reviewer=auto_review が承認要求を
# 二次レビューする。決定的 deny は guard-bash が approval 非依存で担う。
approval="on-request"
if [ "$auto" -eq 1 ]; then
  doctor="${AI_SAFE_DOCTOR:-}"
  if [ -z "$doctor" ]; then
    doctor="$(cd "$(dirname "$0")" && pwd)/doctor.sh"
  fi
  # codex sandbox 初期化がハングしても launcher が無限ブロックしないよう上限 60 秒。
  # macOS に timeout コマンドは無いので perl の alarm でラップ(perl は macOS 標準)。
  # alarm で殺された場合 perl は非0で返る → else(フォールバック)に落ちる = フェイルクローズ。
  # `or exit 127`: exec 失敗(doctor 不在/実行ビット無し/パスがディレクトリ等)時に
  # perl が exit 0 で抜けて green に倒れる(フェイルオープン)のを防ぐ。失敗時は 127 → else。
  if command -v perl >/dev/null 2>&1; then
    # SIG{ALRM} でクリーンに exit(非0)する。shell が "Alarm clock: 14" を表示する
    # のは perl が alarm シグナルを自分で処理せず shell に伝播させる場合のみ。
    # `$SIG{ALRM}=sub{exit 1}` で perl 内部処理にすることで表示を抑制する。
    # exec 失敗(doctor 不在等)は `or exit 127` で非0保証(フェイルクローズ)。
    isolation_ok() { perl -e '$SIG{ALRM}=sub{exit 1};alarm shift;exec @ARGV or exit 127' 60 "$doctor" --isolation-check codex >/dev/null 2>&1; }
  else
    isolation_ok() { "$doctor" --isolation-check codex >/dev/null 2>&1; }
  fi
  # --auto は隔離結果に関わらず on-failure(自走)。危険は hook(guard-bash) が止める。
  approval="on-failure"
  if isolation_ok; then
    echo "🔒 OS隔離(金庫)を確認: ワークスペース外への書込とネット送信の遮断が有効です。" >&2
  else
    echo "⚠ ネット遮断はOSで未実証です(自走は継続)。危険なコマンドは安全フックがブロックします。" >&2
  fi
fi

# A-2: -c features.hooks=true を明示渡し。config.mac.toml の hooks=true と合わせて二重保証。
cmd=(codex --cd "$workspace" --profile safe --sandbox workspace-write --ask-for-approval "$approval" -c features.hooks=true)
if command -v caffeinate >/dev/null 2>&1; then
  cmd=(caffeinate -dimsu "${cmd[@]}")
fi

if [ "${AI_SAFE_DRY_RUN:-}" = "1" ]; then
  printf '%s ' "${cmd[@]}"; [ -n "$prompt" ] && printf '%q' "$prompt"; printf '\n'
  exit 0
fi

if [ -n "$prompt" ]; then
  "${cmd[@]}" "$prompt"
else
  "${cmd[@]}"
fi
