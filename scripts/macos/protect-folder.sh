#!/bin/bash
# protect-folder.sh — 好きなフォルダを「安全な作業フォルダ」にする（卒業後の実務用）。
#
# 卒業後は my-ai-workspace 以外のフォルダでも AI を使いたくなる。このスクリプトは
# 選んだフォルダに対して install.sh を通し、ワークスペース側の保護一式
# （安全ルール・ガード・安全ランチャー・スタートフォルダ・説明書・信頼ダイアログの登録）を
# まるごと入れる。install.sh 本体を呼ぶので、既存の安全策（パッケージ自身は対象にできない /
# 既存ファイルはバックアップ / docs 同期 / 権限 600・700 / ~/.claude.json の
# hasTrustDialogAccepted 登録）はすべてそのまま通る。
#
# 使い方:
#   protect-folder.sh                 … フォルダ選択ダイアログを出す
#   protect-folder.sh <フォルダパス>   … ダイアログを出さずにそのフォルダを対象にする
#
# 危険な選択（/ や ホーム直下、システムフォルダ、書類・デスクトップ等の大箱）は
# 警告して中止する。「ホームで素の AI を起動して全権限で使ってしまう」事故を
# ここで再生産しないため。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 配置は 2 通りある:
#   パッケージ内     <package>/scripts/macos/protect-folder.sh
#   ワークスペース内 <workspace>/.ai-safety/hooks/macos/protect-folder.sh
# どちらでも install.sh が見つかるように両方を探す。
# ワークスペース側には install.sh の実体はあるが、コピー元のパッケージ（configs / policy /
# workspace-template）が無い。そこで install が残す package-source.txt を辿ってパッケージ本体を探す。
is_package_root() {
  [ -n "${1:-}" ] && [ -f "$1/policy/safety-policy.json" ] && [ -d "$1/workspace-template" ] \
    && [ -f "$1/scripts/macos/install.sh" ]
}

PACKAGE_ROOT=""
# 1) 環境変数で明示された場合
if [ -n "${AI_SAFE_PACKAGE_ROOT:-}" ] && is_package_root "$AI_SAFE_PACKAGE_ROOT"; then
  PACKAGE_ROOT="$(cd "$AI_SAFE_PACKAGE_ROOT" && pwd)"
fi
# 2) パッケージ内から直接実行された場合 (<package>/scripts/macos/protect-folder.sh)
if [ -z "$PACKAGE_ROOT" ]; then
  _cand="$(cd "$HERE/../.." 2>/dev/null && pwd || true)"
  is_package_root "$_cand" && PACKAGE_ROOT="$_cand"
fi
# 3) ワークスペース内から実行された場合 (<ws>/.ai-safety/hooks/macos/protect-folder.sh)
if [ -z "$PACKAGE_ROOT" ]; then
  _src_file="$HERE/../../package-source.txt"
  if [ -f "$_src_file" ]; then
    _cand="$(head -n1 "$_src_file" | tr -d '\r')"
    is_package_root "$_cand" && PACKAGE_ROOT="$(cd "$_cand" && pwd)"
  fi
fi

if [ -z "$PACKAGE_ROOT" ]; then
  cat >&2 <<'EOF'
エラー: 安全パッケージ本体のフォルダが見つかりませんでした。

  このボタンは、安全パッケージ（ZIP を展開したフォルダ）の中身を新しいフォルダへ入れます。
  パッケージを移動・削除した場合は場所が分からなくなります。

  → 安全パッケージのフォルダを開き、その中の
       scripts/macos/protect-folder.sh
     を直接実行してください（フォルダ選択ダイアログが出ます）。
EOF
  exit 2
fi
INSTALL_SH="$PACKAGE_ROOT/scripts/macos/install.sh"

# ---- 対象フォルダを決める -------------------------------------------------
target="${1:-}"
if [ -z "$target" ]; then
  if ! command -v osascript >/dev/null 2>&1; then
    echo "エラー: フォルダ選択ダイアログを出せません。フォルダのパスを引数で渡してください。" >&2
    exit 2
  fi
  echo "安全にしたいフォルダを選んでください（選択ダイアログを開きます）..."
  # ダイアログ待ちで固まらないよう時間制限を付ける。時間切れ・キャンセルは「中止」。
  target="$(osascript -e 'with timeout of 300 seconds
    try
      set f to choose folder with prompt "AI が安全に使えるようにするフォルダを選んでください"
      return POSIX path of f
    on error
      return ""
    end try
  end timeout' 2>/dev/null)"
  target="${target%/}"
  if [ -z "$target" ]; then
    echo "中止しました（フォルダが選ばれませんでした）。"
    exit 0
  fi
fi

if [ ! -d "$target" ]; then
  echo "エラー: フォルダが見つかりません: $target" >&2
  exit 2
fi
# 実体のパスで判定する。/tmp は /private/tmp への symlink なので、論理パス（cd + pwd）の
# ままだと「/private/* はシステム」の判定をすり抜ける。-P で symlink を解決した実体を使う。
target="$(cd -P "$target" && pwd -P)"
# 実体がルート（`/Volumes/<起動ボリューム>` は firmlink で `/` に解決される）のときは
# 末尾の `/` を削ると空文字になってしまうので、`/` のまま残す。
[ "$target" = "/" ] || target="${target%/}"
[ -n "$target" ] || target="/"

# ---- 危険な選択を止める ---------------------------------------------------
# ホームも実体で持つ（target を -P で解決したので、比較の左右で表記を揃える）。
home="$(cd -P "$HOME" 2>/dev/null && pwd -P || printf '%s' "${HOME%/}")"
home="${home%/}"
deny_reason=""

if [ "$target" = "/" ]; then
  deny_reason="ディスク全体（/）です"
elif [ "$target" = "$home" ]; then
  deny_reason="ホームフォルダそのものです"
elif [ "$target" = "/Users" ] || [ "$target" = "/Volumes" ]; then
  deny_reason="すべてのユーザー／ディスクを含むフォルダです"
elif [ "$target" = "$PACKAGE_ROOT" ]; then
  deny_reason="安全パッケージのフォルダ自身です"
else
  case "$target" in
    /System|/System/*|/Library|/Library/*|/Applications|/Applications/*|\
    /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/etc|/etc/*|/var|/var/*|\
    /private|/private/*|/opt|/opt/*|/cores|/dev|/dev/*)
      deny_reason="システムが使うフォルダです"
      ;;
    # 一時領域。再起動で中身が消えるうえ、Codex のサンドボックスは一時領域への書き込みを
    # 常に許すので、ここを「守られた作業フォルダ」にしても保護の意味が無くなる。
    /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/tmp|/var/tmp/*)
      deny_reason="一時フォルダ（再起動で消える場所）です"
      ;;
    # マウントされたディスクの丸ごと（起動ディスク /Volumes/Macintosh HD を含む）。
    # ディスク全体を対象にすると「守るべきもの」と「作業対象」の区別が消える。
    # ディスクの中に作った普通のフォルダ（/Volumes/<ディスク>/<フォルダ>）は許可する。
    /Volumes/*)
      case "${target#/Volumes/}" in
        */*) ;;
        *) deny_reason="ディスク全体（マウントされたボリュームそのもの）です" ;;
      esac
      ;;
    "$PACKAGE_ROOT"/*)
      deny_reason="安全パッケージのフォルダの中です"
      ;;
  esac
  # ホーム直下の「大箱」（この中に何でも入っている＝丸ごと AI に触らせるべきでない）
  if [ -z "$deny_reason" ]; then
    for _big in Desktop Documents Downloads Library Movies Music Pictures Public Applications \
                デスクトップ 書類 ダウンロード ミュージック ピクチャ ムービー パブリック; do
      if [ "$target" = "$home/$_big" ]; then
        deny_reason="ホーム直下の「${_big}」フォルダ全体です"
        break
      fi
    done
  fi
  # 対象がホームの祖先（= ホームを丸ごと含む）
  if [ -z "$deny_reason" ]; then
    case "$home" in
      "$target"/*) deny_reason="ホームフォルダ全体を含むフォルダです" ;;
    esac
  fi
fi

if [ -n "$deny_reason" ]; then
  cat >&2 <<EOF

⚠️  このフォルダは対象にできません。
    選ばれた場所: $target
    理由        : $deny_reason

    ここを作業フォルダにすると、AI が「守るべきもの」と「作業対象」を区別できなくなり、
    保護そのものが意味を失います（大事なファイルを丸ごと触れる状態になります）。

    → 案件ごとに新しいフォルダを 1 つ作って、そこを選んでください。
       例: ~/Documents/仕事/A社サイト改修
EOF
  exit 1
fi

# ---- 確認 -----------------------------------------------------------------
cat <<EOF
このフォルダを「AI が安全に使えるフォルダ」にします。

  対象: $target

入れるもの:
  ・安全ルール（危険コマンドの禁止・秘密ファイルの読み取り禁止）
  ・安全ガード（実行前に止める仕組み）
  ・安全ランチャー（Claude / Codex / agy / OpenCode を安全な設定で起動する）
  ・スタートフォルダ（番号付きのボタン）と説明書
  ・このフォルダを Claude が「信頼済み」として扱う登録

既にあるファイルは消しません（同名のものは控えを取ってから置き換えます）。
EOF

_skip_confirm=0
[ "${AI_SAFE_ASSUME_YES:-0}" = "1" ] && _skip_confirm=1
# 標準入力が端末でないとき（パイプ・リダイレクト・スクリプトからの実行）は、確認を
# 飛ばして install を走らせるのではなく中止する。確認なしで進めたい場合だけ
# AI_SAFE_ASSUME_YES=1 を明示してもらう（安全側に倒す）。
if [ "$_skip_confirm" -eq 0 ] && [ ! -t 0 ]; then
  echo "中止しました（確認を取れない実行方法です）。" >&2
  echo "  端末から実行するか、確認を省く場合は AI_SAFE_ASSUME_YES=1 を付けて実行してください。" >&2
  exit 1
fi
if [ "$_skip_confirm" -eq 0 ]; then
  echo ""
  printf 'このフォルダを安全にしますか？ [y/N]: '
  read -r _ans || _ans=""
  case "$_ans" in
    y|Y|yes|YES) ;;
    *) echo "中止しました。何も変更していません。"; exit 0 ;;
  esac
fi

# ---- install 本体を通す ---------------------------------------------------
echo ""
bash "$INSTALL_SH" --platform mac "$target"
ec=$?
if [ $ec -ne 0 ]; then
  echo ""
  echo "うまくいきませんでした（上のメッセージを確認してください）。" >&2
  exit $ec
fi

cat <<EOF

────────────────────────────────────────────
完了しました。このフォルダでできるようになったこと:

  $target

  ・「スタート」フォルダのボタンから、安全な設定のまま AI を起動できます
      1_AIをまとめて起動 / 2_セーフCodexを起動 / 3_セーフClaudeを起動 …
  ・このフォルダの外へは書き込めません（作業対象の外を壊さない）
  ・rm -r・.env の読み取り・curl|sh・勝手な外部送信は止まります
  ・秘密（API キー等）が画面や送信内容に出るときは伏せ字になります
  ・Claude の「このフォルダを信頼しますか？」は登録済みなので聞かれません

  まずは「スタート」フォルダを開いて、1 番のボタンから始めてください。
────────────────────────────────────────────
EOF
