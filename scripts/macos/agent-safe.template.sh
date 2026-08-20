#!/usr/bin/env bash
# __NAME__ — 安全ガード付きの AI を起動する（どこからでも打てるコマンド）。
#
# 置き場: ~/.ai-safety/bin/__NAME__（install が生成。ワークスペースのパスを焼き込む）
# 使い方:
#   __NAME__                作業フォルダで起動
#   __NAME__ <オプション>     オプションはそのまま安全ランチャーへ渡す
#
# なぜこれが要るのか（重要・安全設計上の理由）:
#   安全ランチャーの実体は <作業フォルダ>/.ai-safety/hooks/macos/launch-__AGENT__-safe.sh にある。
#   ところが `.ai-safety` は決定的 deny 床の保護パス（protectedPathRegex）なので、AI が
#   `bash ~/.ai-safety/hooks/macos/launch-__AGENT__-safe.sh` と書いた瞬間に mac / Windows /
#   OpenCode の 3 エンジンとも deny する。結果として「安全な形は禁止され、安全フックを
#   通らない裸の __AGENT__ だけが通る」という反転が起きていた（2026-08-20 実測。壁 A）。
#   このシムは PATH 上の短い名前で同じランチャーへ橋渡しするので、コマンド文字列に
#   `.ai-safety` を書かずに安全な形を起動できる。**deny 床は 1 文字も緩めていない。**
#   Windows は setup-commands.ps1 が同名のシム（codex-safe.cmd / claude-safe.cmd /
#   agy-safe.cmd）を元から作っており、これは mac 側の欠落を埋めて対称にするもの。
set -euo pipefail

WORKSPACE_BAKED="__WORKSPACE__"

# いま居る場所から上へ .ai-safety を探し、見つかったフォルダを作業フォルダとする
# （oc-safe と同じ流儀。焼き込み値が古い／別の場所を指していても居場所から正しく判断する）。
_detect_workspace() {
  local d
  d="$(pwd -P 2>/dev/null)" || return 1
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/.ai-safety/hooks/macos/launch-integrated.sh" ]; then
      printf '%s' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}

WORKSPACE="$(_detect_workspace 2>/dev/null || printf '%s' "$WORKSPACE_BAKED")"
LAUNCHER="$WORKSPACE/.ai-safety/hooks/macos/launch-__AGENT__-safe.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<EOF
__NAME__ — __AGENT__ を安全ガード付きで起動します（作業フォルダ: ${WORKSPACE}）。

  __NAME__                 作業フォルダで起動
  __NAME__ <オプション>      オプションは安全ランチャーへそのまま渡します

安全設定（作業フォルダの外への書き込み禁止・秘密ファイルの読み取り禁止・
危険コマンドの決定的 deny・見守りモニターへの記録）はすべて有効のまま起動します。
EOF
  exit 0
fi

if [ ! -f "$LAUNCHER" ]; then
  echo "安全パッケージが見つかりません: $LAUNCHER" >&2
  echo "「1_安全パッケージを準備」を実行してから、もう一度お試しください。" >&2
  exit 1
fi

# 安全ランチャーは第 1 引数に「作業フォルダ」を取る（サブフォルダは取れない: Claude は
# <作業フォルダ>/.claude/settings.json を、Codex は <作業フォルダ>/.codex/ を見るため）。
# フラグは作業フォルダより前に置く（launch-claude-safe.sh は位置引数の解釈前にフラグを
# 取り除く実装）。
if [ "$#" -gt 0 ]; then
  exec bash "$LAUNCHER" "$@" "$WORKSPACE"
fi
exec bash "$LAUNCHER" "$WORKSPACE"
