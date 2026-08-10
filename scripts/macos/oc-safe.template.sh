#!/usr/bin/env bash
# oc-safe — OpenCode を Bouncer 監視下で起動する（どこからでも打てるコマンド）。
#
# 置き場: ~/.ai-safety/bin/oc-safe（install が生成。ワークスペースのパスを焼き込む）
# 使い方:
#   oc-safe                いま開いているフォルダで起動
#   oc-safe みつもり案件     ワークスペース内のそのフォルダで起動
#   oc-safe ./sub/dir      パス指定でも可
#   oc-safe --resume       前回の続きから開く
#   oc-safe --websearch    Web 検索を確認制で有効にする（組み合わせ可）
#
# なぜフォルダを指定して起動するのか:
#   OpenCode は「起動したフォルダ」が作業対象になり、動き出したあとで cd しても移らない
#   （OpenCode 本体の仕様）。プロジェクトごとに分けて作業するには、そのフォルダで
#   起動する必要がある。このコマンドはそれを 1 行で済ませるためのもの。
set -euo pipefail

# 導入時に焼き込まれる作業フォルダ。これは「どこでもない場所から打たれたとき」の
# 手がかりに使うだけで、優先はしない。理由は下の _detect_workspace を参照。
WORKSPACE_BAKED="__WORKSPACE__"

# いま居る場所から上へ .ai-safety を探し、見つかったフォルダを作業フォルダとする。
# 焼き込み値を優先しないのは、
#   - 複数の作業フォルダを使い分けても「いま居る側」で正しく動く
#   - 焼き込み値が古い／別の場所を指していても、居場所から正しく判断できる
#   （実際、検証用フォルダへ導入し直したせいで焼き込み値がそちらに書き換わり、
#     本来の作業フォルダの中に居るのに「外です」と断られる事故が起きた）
# ため。見つからなければ焼き込み値に戻す。
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

# 統合ランチャーを経由する。ここが「見守りモニター（Bouncer の画面）＋ AI」をまとめて
# 立ち上げる入口なので、OpenCode のランチャーを直接叩いてはいけない
# （直接叩くとモニターが起動せず、画面で見えないまま AI が動くことになる）。
LAUNCHER="$WORKSPACE/.ai-safety/hooks/macos/launch-integrated.sh"

usage() {
  cat <<'EOF'
oc-safe — OpenCode を安全ガード付きで起動します。

  oc-safe                 いま開いているフォルダで起動
  oc-safe <フォルダ名>      作業フォルダの中のそのフォルダで起動
  oc-safe --resume        前回の続きから開く
  oc-safe --websearch     Web 検索を確認制で有効にする

フォルダは作業フォルダ（my-ai-workspace）の中だけ指定できます。
EOF
}

if [ ! -f "$LAUNCHER" ]; then
  echo "安全パッケージが見つかりません: $LAUNCHER" >&2
  echo "「1_安全パッケージを準備」を実行してから、もう一度お試しください。" >&2
  exit 1
fi

PROJECT=""
FLAGS=""
for _a in "$@"; do
  case "$_a" in
    -h|--help) usage; exit 0 ;;
    --resume|--continue) FLAGS="$FLAGS --resume" ;;
    --websearch) FLAGS="$FLAGS --websearch" ;;
    -*) echo "不明なオプション: $_a" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$PROJECT" ]; then
        echo "フォルダは 1 つだけ指定できます。" >&2
        exit 2
      fi
      PROJECT="$_a"
      ;;
  esac
done

# フォルダ未指定なら「いま開いているフォルダ」。ccmux / Zed / ターミナルのどこから
# 打っても、その場所でそのまま作業を始められるようにするため。
[ -n "$PROJECT" ] || PROJECT="$(pwd)"

# 「フォルダ名だけ」で指定されたときは作業フォルダの中を探す（oc-safe みつもり案件）。
if [ ! -d "$PROJECT" ] && [ -d "$WORKSPACE/$PROJECT" ]; then
  PROJECT="$WORKSPACE/$PROJECT"
fi
if [ ! -d "$PROJECT" ]; then
  echo "フォルダが見つかりません: $PROJECT" >&2
  echo "作業フォルダ: $WORKSPACE" >&2
  exit 2
fi
# 比較は物理パス（pwd -P）で行う。macOS の /var → /private/var のようなシンボリックリンクが
# 途中にあると、論理パスのままでは「中にあるのに外」と判定されてしまう。
PROJECT="$(cd "$PROJECT" && pwd -P)"
WORKSPACE_REAL="$(cd "$WORKSPACE" 2>/dev/null && pwd -P || printf '%s' "$WORKSPACE")"

# ワークスペースの外は断る（ガードとポリシーはワークスペース基準で配置されているため）。
case "$PROJECT" in
  "$WORKSPACE_REAL"|"$WORKSPACE_REAL"/*) ;;
  *)
    echo "作業フォルダ（my-ai-workspace）の中で使ってください。" >&2
    echo "  いまの場所: $PROJECT" >&2
    echo "  作業フォルダ: $WORKSPACE" >&2
    echo "例: cd \"$WORKSPACE\" && oc-safe" >&2
    exit 2
    ;;
esac

# shellcheck disable=SC2086
exec bash "$LAUNCHER" "$WORKSPACE" opencode standard "--project=$PROJECT" $FLAGS
