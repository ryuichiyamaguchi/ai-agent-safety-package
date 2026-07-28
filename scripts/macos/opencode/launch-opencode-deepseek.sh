#!/usr/bin/env bash
# OpenCode + DeepSeek V4 Pro/Flash を送信検査 Gateway 経由で起動する。
set -euo pipefail

WORKSPACE="${1:-$HOME/Documents/my-ai-workspace}"
WEBSEARCH="${2:-}"
HOOKS_DIR="$WORKSPACE/.ai-safety/hooks"
GATEWAY_JS="$HOOKS_DIR/common/ds-gateway.js"
CONFIG_JS="$HOOKS_DIR/common/opencode-config.js"
MONITOR_PLUGIN="$HOOKS_DIR/common/opencode-bouncer-monitor.mjs"
PORT="${DS_GATEWAY_PORT:-8788}"
KEY_DIR="$HOME/.deepseek-claude"
KEY_FILE="$KEY_DIR/auth"
LOG_DIR="${AI_SAFE_LOG_DIR:-$HOME/.ai-safety/logs}"
COACH_MARKER="$LOG_DIR/coach-engine"

case "$WEBSEARCH" in
  ""|--websearch) ;;
  *) echo "使い方: $0 [workspace] [--websearch]" >&2; exit 2 ;;
esac

[ -d "$WORKSPACE" ] || { echo "作業フォルダが見つかりません: $WORKSPACE" >&2; exit 2; }
[ -f "$GATEWAY_JS" ] || { echo "送信検査 Gateway が見つかりません: $GATEWAY_JS" >&2; exit 2; }
[ -f "$CONFIG_JS" ] || { echo "OpenCode 安全設定が見つかりません: $CONFIG_JS" >&2; exit 2; }
[ -f "$MONITOR_PLUGIN" ] || { echo "OpenCode承認モニターが見つかりません: $MONITOR_PLUGIN" >&2; exit 2; }

if [ "${AI_SAFE_DRY_RUN:-0}" = "1" ]; then
  echo "OpenCode + DeepSeek dry-run"
  echo "  workspace: $WORKSPACE"
  echo "  gateway:   http://127.0.0.1:$PORT/v1 (mandatory)"
  echo "  config:    OPENCODE_CONFIG_CONTENT"
  echo "  model:     DeepSeek V4 Pro / small: V4 Flash"
  if [ "$WEBSEARCH" = "--websearch" ]; then
    echo "  websearch: opt-in (approval required)"
  else
    echo "  websearch: off"
  fi
  exit 0
fi

command -v node >/dev/null 2>&1 || { echo "Node.js が見つかりません。" >&2; exit 1; }
# 安全プラグインが壊れていると「黙って無防備」になるので、起動前に構文まで確かめる。
if ! node --check "$MONITOR_PLUGIN" >/dev/null 2>&1; then
  echo "OpenCode承認モニターが壊れているため、OpenCode は起動しません（fail-closed）。" >&2
  echo "「導入(インストール)」をやり直してください: $MONITOR_PLUGIN" >&2
  exit 1
fi
OPENCODE_BIN="${OPENCODE_BIN:-$(command -v opencode 2>/dev/null || true)}"
[ -n "$OPENCODE_BIN" ] || { echo "OpenCode が見つかりません。先に OpenCode をインストールしてください。" >&2; exit 1; }
[ -s "$KEY_FILE" ] || { echo "DeepSeek APIキーが未登録です。先に「DeepSeekキーを登録」を実行してください。" >&2; exit 1; }

VERSION="$("$OPENCODE_BIN" --version 2>/dev/null | head -n1 | tr -d '\r')"
if ! node -e 'const m=require(process.argv[1]);process.exit(m.isSupportedVersion(process.argv[2])?0:1)' "$CONFIG_JS" "$VERSION"; then
  echo "OpenCode 1.14.24 以上が必要です（検出: ${VERSION:-不明}）。" >&2
  exit 1
fi

stop_stale_gateway() {
  command -v lsof >/dev/null 2>&1 || return 0
  for pid in $(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true); do
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$cmd" in
      *"$GATEWAY_JS"*) kill "$pid" 2>/dev/null || true ;;
    esac
  done
}

# 呼び出し元認証トークンを起動ごとに採番する。127.0.0.1 で待つだけでは同一 PC の
# 任意プロセスや DNS リバインディングを踏んだブラウザが、実キーへ差し替えて転送する
# gateway をそのまま叩けてしまうため、「この起動で立てた OpenCode だけが通れる」
# 合言葉を毎回作り直す。コマンドライン引数には載せない（ps に出るため）。
if command -v openssl >/dev/null 2>&1; then
  GATEWAY_TOKEN="$(openssl rand -hex 32)"
else
  GATEWAY_TOKEN="$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')"
fi
[ -n "$GATEWAY_TOKEN" ] || { echo "送信検査 Gateway の合言葉を生成できませんでした（fail-closed）。" >&2; exit 1; }

mkdir -p "$LOG_DIR"
stop_stale_gateway
DS_GATEWAY_PORT="$PORT" \
DS_GATEWAY_UPSTREAM="https://api.deepseek.com" \
DS_GATEWAY_AUTH_FILE="$KEY_FILE" \
DS_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
  node "$GATEWAY_JS" >"$LOG_DIR/opencode-deepseek-gateway.log" 2>&1 &
GW_PID=$!

WATCHDOG_PID=""
# coach マーカーは d-claude と OpenCode が同じパスを共有する。並行起動時に片方の終了で
# もう片方のバナーが消えないよう、「自分が書いた値のままのときだけ」消す。
remove_own_coach_marker() {
  [ "$(cat "$COACH_MARKER" 2>/dev/null || true)" = "opencode-deepseek" ] || return 0
  rm -f "$COACH_MARKER" 2>/dev/null || true
}
cleanup() {
  kill "$GW_PID" 2>/dev/null || true
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
  remove_own_coach_marker
  return 0
}
trap cleanup EXIT INT TERM HUP

ready=0
for _i in $(seq 1 50); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/healthz" 2>/dev/null | grep -q '"status":"ok"'; then
    ready=1
    break
  fi
  kill -0 "$GW_PID" 2>/dev/null || break
  sleep 0.1
done
if [ "$ready" -ne 1 ] || ! kill -0 "$GW_PID" 2>/dev/null; then
  echo "送信検査 Gateway を確認できないため、OpenCode は起動しません（fail-closed）。" >&2
  echo "確認先: $LOG_DIR/opencode-deepseek-gateway.log" >&2
  exit 1
fi

# 実キーは Gateway 子プロセスだけが読み、OpenCode の環境には渡さない。
# 一覧は opencode-config.js が持つ（Windows 版と 1 か所で共有するため）。ここで先に消すのは、
# 消す前に設定を作ると「鍵があるので MCP を登録したのに、その鍵が MCP へ届かない」状態に
# なるため。検索・画像読取は ~/.ai-safety/gemini-api-key.txt（「6_AIコーチのキーを登録」が
# 書く場所）だけを見るので、環境変数しか持っていない人にはここで案内を出す。
SECRET_ENV_VARS="$(node "$CONFIG_JS" --print-secret-env)"
[ -n "$SECRET_ENV_VARS" ] || { echo "OpenCode 安全設定を生成できませんでした。" >&2; exit 1; }
if [ -n "${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}" ] && [ ! -s "$HOME/.ai-safety/gemini-api-key.txt" ]; then
  echo "注意: 環境変数の Gemini キーは OpenCode へ渡しません（AI から見えてしまうため）。" >&2
  echo "      検索と画像読み取りを使うときは「6_AIコーチのキーを登録」で登録してください。" >&2
fi
# shellcheck disable=SC2086
unset $SECRET_ENV_VARS 2>/dev/null || true
# deny 床そのものを決めるポリシーの置き場を、環境変数で差し替えられないようにする。
# 無害な正規表現だけのポリシーを指されると、決定的 deny 床が丸ごと消える。
unset AI_SAFE_POLICY AI_SAFE_ROOT 2>/dev/null || true

# プロジェクト固有の設定は無効化し、隔離した設定ディレクトリからBouncerプラグインだけを読む。
export OPENCODE_DISABLE_PROJECT_CONFIG=1
unset OPENCODE_PURE 2>/dev/null || true
# 強制設定を後から丸ごと無効化できる環境変数を先に消す。
# OPENCODE_PERMISSION と OPENCODE_TEST_MANAGED_CONFIG_DIR は OPENCODE_CONFIG_CONTENT より
# 後にマージされるため、外から仕込まれていると deny 床がそのまま外れる（1.18.4 実測）。
unset OPENCODE_PERMISSION OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_TEST_MANAGED_CONFIG_DIR 2>/dev/null || true
export XDG_CONFIG_HOME="$WORKSPACE/.ai-safety/opencode-runtime/xdg-config"
export AI_SAFE_LOG_DIR="$LOG_DIR"
mkdir -p "$XDG_CONFIG_HOME"

# --- 日本語ハーネスの配置 ---------------------------------------------------
# OPENCODE_DISABLE_PROJECT_CONFIG=1 では作業フォルダの .opencode/ は一切読まれず、
# 作業フォルダ側 AGENTS.md の探索も止まる。一方、設定ディレクトリ直下の AGENTS.md は
# instructions の指定と関係なく無条件で読み込まれる（1.18.4 実測）。そこで
# 「隔離設定ディレクトリ側」にパッケージ同梱のハーネス一式を毎回置き直す。
#   - AGENTS.md            … 日本語の指示書本体（設定ディレクトリ直下＝無条件で読まれる）
#   - command(s)/*.md      … 日本語スラッシュコマンド（1.18.4 は単数・複数どちらも読む）
#   - agents/*.md          … 追加エージェント（読み取り専用「せんせい」等）
#   - skills/<名前>/       … 配布スキル（hearing-ladder 等）
# 同梱物の名前を決め打ちせず、配布元にある物をそのまま写す（将来 1 本増えても配線不要）。
# 毎回置き直すので、ここを書き換えられてもパッケージ側の内容が必ず勝つ。
# 中身が無いときは警告だけ出して続行する（保護には影響しないため止めない）。
OC_CONFIG_DIR="$XDG_CONFIG_HOME/opencode"
HARNESS_SRC="$WORKSPACE/.ai-safety/opencode-harness"
SKILLS_SRC="$WORKSPACE/.ai-safety/dist-skills"
# 消す前に「本当に自分が作った隔離設定ディレクトリか」を完全一致で確かめる。
# ここを前方一致だけで済ませると、環境変数の細工で受講者の作業フォルダを消しかねない。
if [ "$OC_CONFIG_DIR" != "$WORKSPACE/.ai-safety/opencode-runtime/xdg-config/opencode" ]; then
  echo "設定ディレクトリの場所が想定外のため、OpenCode は起動しません（fail-closed）。" >&2
  exit 1
fi
mkdir -p "$OC_CONFIG_DIR"

# --- OpenCode が読む場所を毎回まっさらにする -------------------------------------
# 「配布物にある名前だけ置き直す」方式だと、配布物に無い綴り（単数形の agent/ command/、
# mode/、skill/、themes/）へ仕込まれた定義が次の起動でも生き残る（1.18.4 のバイナリ実測:
# {agent,agents}/**/*.md ・ {command,commands}/**/*.md ・ {mode,modes}/*.md ・
# {plugin,plugins}/*.{ts,js} ・ skill/ と skills/ ・ themes/*.json を読む）。読む場所を
# 先に消してから配布物を置き直せば、綴りの取りこぼしが構造的に起きない。
# 消すのは上で場所を完全一致で確かめた隔離設定ディレクトリの中だけ。node_modules /
# package.json / bun.lock は OpenCode がプラグインの依存を入れる場所なので残す
# （毎回消すと起動のたびにダウンロードが走り、教室の PC では実用にならない）。
for _known in agent agents command commands mode modes plugin plugins skill skills themes; do
  rm -rf "$OC_CONFIG_DIR/$_known"
done
rm -f "$OC_CONFIG_DIR/AGENTS.md" "$OC_CONFIG_DIR/opencode.json" "$OC_CONFIG_DIR/opencode.jsonc"

if [ -d "$HARNESS_SRC" ]; then
  for _entry in "$HARNESS_SRC"/*; do
    [ -e "$_entry" ] || continue
    _name="$(basename "$_entry")"
    # plugin/ だけは写さない。設定ディレクトリの plugin は無条件で実行されるので、
    # 動くコードは「ランチャーが明示的に渡す Bouncer 監視プラグイン 1 本」に限る。
    case "$_name" in
      plugin|plugins) echo "注意: 配布物の $_name は安全のため配置しません。" >&2; continue ;;
    esac
    if [ -d "$_entry" ]; then
      rm -rf "$OC_CONFIG_DIR/$_name"
      mkdir -p "$OC_CONFIG_DIR/$_name"
      cp -R "$_entry/." "$OC_CONFIG_DIR/$_name/"
    else
      cp "$_entry" "$OC_CONFIG_DIR/$_name"
    fi
  done
  [ -f "$OC_CONFIG_DIR/AGENTS.md" ] \
    || echo "注意: 日本語の指示書が見つからないため配置をとばしました: $HARNESS_SRC/AGENTS.md" >&2
else
  echo "注意: 日本語の指示書が見つからないため配置をとばしました: $HARNESS_SRC" >&2
fi

if [ -d "$SKILLS_SRC" ]; then
  mkdir -p "$OC_CONFIG_DIR/skills"
  for _skill in "$SKILLS_SRC"/*/; do
    [ -f "$_skill/SKILL.md" ] || continue
    _name="$(basename "$_skill")"
    rm -rf "$OC_CONFIG_DIR/skills/$_name"
    cp -R "$_skill" "$OC_CONFIG_DIR/skills/$_name"
  done
else
  echo "注意: 配布スキルが見つからないため配置をとばしました: $SKILLS_SRC" >&2
fi

# --- 設定ディレクトリのシンボリックリンクを禁じる（fail-closed）-------------------
# opencode 1.18.4 は command / agent / mode を `symlink:true` で走査する＝リンクの
# 先にある .md も読む。リンクを 1 本置かれるだけで「配置し直した安全なファイルを見て
# いるつもりが、まったく別の場所のファイルを読ませられる」形になる。配布物に
# シンボリックリンクは 1 本も無いので、あれば作為とみなして起動しない。
_link_hits="$(find "$OC_CONFIG_DIR" -type l 2>/dev/null || true)"
if [ -n "$_link_hits" ]; then
  echo "設定フォルダにショートカット（シンボリックリンク）が置かれていたため、OpenCode は起動しません（fail-closed）。" >&2
  printf '%s\n' "$_link_hits" | while IFS= read -r _f; do [ -n "$_f" ] && echo "  対象: $_f" >&2; done
  echo "「導入(インストール)」をやり直してください。それでも出る場合は講師に連絡してください。" >&2
  exit 1
fi

# --- スラッシュコマンドの中の「シェル実行」を禁じる（fail-closed）-----------------
# コマンド .md の本文に書かれた !`コマンド` は、テンプレート展開時に受講者のシェルへ
# そのまま渡されて実行される（1.18.4 のバイナリ内 /!`([^`]+)`/g → shell 実行を確認）。
# これはツール呼び出しを経ないので permission の確認も、承認モニターの決定的 deny 床も
# 通らない＝安全機構を丸ごと迂回する任意コード実行になる。配布物にこの書き方は無いので、
# 「配置後の実ファイル」を見て 1 つでもあれば起動しない（配置後に書き換えられた場合も拾う）。
#
# 走査は設定ディレクトリ全体にかける。opencode が読むのは command(s) / agent(s) /
# mode(s) だが、フォルダ名を並べて数え上げる書き方は取りこぼす（mode を書き忘れる、
# 大文字の Commands を見落とす、といった形）。配布物のどのファイルにもこの書き方は
# 無いので、全部見て 1 件でもあれば止めるほうが確実。-R はリンクも辿る指定（BSD grep の
# -r は辿らない）だが、上でリンク自体を禁じているのでここでは保険。
if grep -RlF '!`' "$OC_CONFIG_DIR" >/dev/null 2>&1; then
  echo "コマンド定義に「確認なしでコマンドを実行する書き方」が含まれていたため、OpenCode は起動しません（fail-closed）。" >&2
  grep -RlF '!`' "$OC_CONFIG_DIR" 2>/dev/null | while IFS= read -r _f; do echo "  対象: $_f" >&2; done
  echo "「導入(インストール)」をやり直してください。それでも出る場合は講師に連絡してください。" >&2
  exit 1
fi

# 合言葉は provider の apiKey として設定に埋め込む（gateway 側で照合される）。
# opencode-config.js へは環境変数で渡す（引数にすると ps に出る）。この行限定の
# 環境変数なのでランチャー自身の環境には残らない。
CONFIG_ARGS=(--port "$PORT" --monitor-plugin "$MONITOR_PLUGIN")
if [ "$WEBSEARCH" = "--websearch" ]; then
  export OPENCODE_ENABLE_EXA=1
  export OPENCODE_CONFIG_CONTENT
  OPENCODE_CONFIG_CONTENT="$(DS_GATEWAY_TOKEN="$GATEWAY_TOKEN" node "$CONFIG_JS" "${CONFIG_ARGS[@]}" --websearch)"
  echo "Web検索を有効にしました。検索語は外部サービスへ送信され、実行前に確認が出ます。"
else
  unset OPENCODE_ENABLE_EXA 2>/dev/null || true
  export OPENCODE_CONFIG_CONTENT
  OPENCODE_CONFIG_CONTENT="$(DS_GATEWAY_TOKEN="$GATEWAY_TOKEN" node "$CONFIG_JS" "${CONFIG_ARGS[@]}")"
fi
[ -n "$OPENCODE_CONFIG_CONTENT" ] || { echo "OpenCode 安全設定を生成できませんでした。" >&2; exit 1; }

# 消すだけでなく「安全な値で上書き」して二重化する。環境変数側が最後にマージされるので、
# 将来マージ順が変わっても最小限の deny 床（削除・昇格・公開・外部通信・外部フォルダ）は残る。
OPENCODE_PERMISSION="$(node "$CONFIG_JS" --print-permission-env)"
[ -n "$OPENCODE_PERMISSION" ] || { echo "OpenCode 安全設定を生成できませんでした。" >&2; exit 1; }
export OPENCODE_PERMISSION

# 合言葉の受け渡し用変数も消す（OpenCode へは設定内の apiKey として渡るので不要）。
unset DS_GATEWAY_AUTH_FILE DS_GATEWAY_TOKEN 2>/dev/null || true

cd "$WORKSPACE"

# --- 本体を出す前に「安全プラグインが本当に載るか」を実物で確かめる ----------------
# `opencode debug config` はプラグインを実際に読み込む（1.18.4 実測: プラグインの中で
# ファイルを書かせて確認）。そこでこれを本体より先に 1 回だけ同期実行し、
#   (1) 解決済み設定で deny 床が生きているか
#   (2) プラグインが ready マーカーを書いたか（＝決定的 deny 床が載ったか）
# の両方を確かめてから本体を起動する。以前はどちらも「起動してから 30 秒後に気づく」
# 形だったため、無防備な OpenCode がそのまま動き続けていた。
READY_MARKER="$LOG_DIR/opencode-monitor-ready.json"
rm -f "$READY_MARKER" 2>/dev/null || true
PLUGIN_PROBE_SINCE="$(node -e 'process.stdout.write(String(Date.now()))')"

resolved="$("$OPENCODE_BIN" debug config 2>/dev/null || true)"
if [ -z "$resolved" ]; then
  echo "安全設定を確認できないため、OpenCode は起動しません（fail-closed）。" >&2
  echo "OpenCode が古い可能性があります。最新版に更新してから、もう一度お試しください。" >&2
  exit 1
fi
if ! printf '%s' "$resolved" | node "$CONFIG_JS" --verify-resolved; then
  echo "安全設定が有効になっていないため、OpenCode は起動しません（fail-closed）。" >&2
  echo "「導入(インストール)」をやり直してから、もう一度お試しください。" >&2
  exit 1
fi
# 終了コードだけでなく合図の 1 行も要求する。何かの理由で検査そのものが走らなかったとき、
# 「黙って 0 で終わった」を「確認できた」と取り違えないため。
ready_signal="$(node "$MONITOR_PLUGIN" --verify-ready --not-before "$PLUGIN_PROBE_SINCE" || true)"
case "$ready_signal" in
  *BOUNCER_READY_OK*) ;;
  *)
    echo "危険なコマンドを止める安全プラグインが読み込まれないため、OpenCode は起動しません（fail-closed）。" >&2
    echo "「導入(インストール)」をやり直してから、もう一度お試しください。" >&2
    exit 1 ;;
esac

# 見張り: 本体のセッションでもプラグインが読み込まれたかを ready マーカーで確かめ、
# 読み込まれていなければ監視画面の履歴に警告を残す（TUI は全画面なので画面出力では気づけない）。
# 上の確認で書かれたマーカーを消してから始めるので、今回のセッション分だけを見る。
rm -f "$READY_MARKER" 2>/dev/null || true
node "$MONITOR_PLUGIN" --watchdog --timeout-ms 30000 >/dev/null 2>&1 &
WATCHDOG_PID=$!

printf 'opencode-deepseek' > "$COACH_MARKER" 2>/dev/null || true
echo "Bouncer送信検査: 有効 / モデル: DeepSeek V4 Pro / 補助: V4 Flash"
echo "変更操作は確認、外部フォルダは禁止、Web検索は${WEBSEARCH:+許可時のみ}$( [ -n "$WEBSEARCH" ] || printf '無効' )です。"
echo "危険なコマンド（まとめて削除・鍵の読み出し・ネットから拾った実行）は確認なしで止まります。"

"$OPENCODE_BIN"
