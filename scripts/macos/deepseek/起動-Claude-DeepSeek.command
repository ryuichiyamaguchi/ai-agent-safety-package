#!/usr/bin/env bash
# ============================================================
# 起動-Claude-DeepSeek.command
# 「DeepSeek を裏で使う Claude Code」を、本パッケージの保護フック
# （ガード）が効いたまま起動します（Mac 版）。
# ------------------------------------------------------------
# 重要（正直にお伝えする事実）:
#   ・会話内容は DeepSeek（中国管轄のサーバー）に送信されます。
#     本パッケージのガードは「AI のツール操作（ファイル削除・危険な
#     コマンド実行など）の暴走」を止めます。さらに送信検査 Gateway が
#     DeepSeek へ送る前に既知パターンの機微情報（API キー・パスワード等）を
#     自動マスキングします。ただし検出できるパターンに限られ、完全な保証では
#     ないため、本当に流出して困る情報は入力しないこと。
#   ・このファイルは素の claude を呼びません。必ず
#     launch-claude-safe.sh を経由します（ガードバイパス防止）。
# ============================================================
set -u

# 作業フォルダは「呼び出し元が渡した値 → このスクリプト自身の位置から逆算 → 既定」の順で決める。
# 「（上級）14_新しい作業フォルダを安全にする」で別のフォルダへ導入した場合、このファイルは
# そのフォルダの .ai-safety/hooks/macos/deepseek/ に置かれる。固定パスにしていると
# 別のワークスペースのフックを使ってしまうため、自分の位置から 4 階層上を作業フォルダとする。
# （<workspace>/.ai-safety/hooks/macos/deepseek/このファイル）
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SELF_WS="$(cd "$_HERE/../../../.." 2>/dev/null && pwd || true)"
if [ -n "${1:-}" ]; then
  WORKSPACE="$1"
elif [ -n "$_SELF_WS" ] && [ -d "$_SELF_WS/.ai-safety/hooks/macos" ]; then
  WORKSPACE="$_SELF_WS"
else
  WORKSPACE="$HOME/Documents/my-ai-workspace"
fi
HOOKS="$WORKSPACE/.ai-safety/hooks/macos"
LAUNCH_CLAUDE="$HOOKS/launch-claude-safe.sh"
DEEPSEEK_GATE="$HOOKS/launch-deepseek-safe.sh"
SECRET_STORE="$WORKSPACE/.ai-safety/hooks/common/secret-store.js"

if [ ! -f "$LAUNCH_CLAUDE" ]; then
  echo ""
  echo "【エラー】安全ランチャーが見つかりません:"
  echo "  $LAUNCH_CLAUDE"
  echo ""
  echo "  先に install-one-click.command で安全パッケージを"
  echo "  インストールしてください（workspace が未作成です）。"
  echo ""
  read -r -p "Enter で閉じます..." _
  exit 1
fi

# -- DeepSeek 念押しゲート（赤枠警告 + yes/no） ----------------------
# workspace 内の launch-deepseek-safe.sh を呼び、「中国管轄サーバーに
# 送信される」事実への同意を取る。yes 以外なら exit 1 が返るので中断。
if [ -f "$DEEPSEEK_GATE" ]; then
  if ! bash "$DEEPSEEK_GATE" --consent-only; then
    echo ""
    echo "起動をキャンセルしました。"
    read -r -p "Enter で閉じます..." _
    exit 1
  fi
else
  echo ""
  echo "【注意】DeepSeek 同意ゲート（launch-deepseek-safe.sh）が"
  echo "  見つかりませんでした。会話内容は DeepSeek（中国管轄）に"
  echo "  送信されます。流出して困る情報は書かないでください。"
  echo ""
  printf "この点を理解した上で続行しますか？ (yes/no): "
  read -r AGREE
  if [ "$AGREE" != "yes" ]; then
    echo "起動をキャンセルしました。"
    read -r -p "Enter で閉じます..." _
    exit 1
  fi
fi

# -- API キーの有無を確かめる（値はここでは読まない） ----------------
# 判定は「環境変数 → OS の金庫（キーチェーン）→ 旧平文 ~/.deepseek-claude/auth」の
# 解決結果で行う。金庫化（secret-migrate.js）で旧平文は削除されるので、平文ファイルの
# 実在で判定すると「登録したのに未登録と言われる」誤表示になる。
# 実キーを読むのは Gateway 子プロセスだけ（Claude Code のプロセスには渡さない）。
# node / secret-store.js が無い環境では判定を保留し、Gateway 側の同じ 3 段解決に任せる。
if command -v node >/dev/null 2>&1 && [ -f "$SECRET_STORE" ]; then
  if [ "$(node "$SECRET_STORE" --has deepseek 2>/dev/null || true)" != "yes" ]; then
    echo ""
    echo "【注意】API キーが未登録です。先に「登録-初回だけ.command」を"
    echo "  実行してから、もう一度この .command を開いてください。"
    echo ""
  fi
fi
unset ANTHROPIC_AUTH_TOKEN

# -- DeepSeek backend 環境変数（BASE_URL は Gateway 側で設定） ------
# モデル名に [1m]（1M コンテキスト指定）を付けると、Claude Code 2.1.226 以降は
# それを名前の一部として扱い「そんなモデルは無い」で起動できなくなる（実機で再現）。
# DeepSeek が公開しているのは deepseek-v4-flash / deepseek-v4-pro の 2 つだけ。
# 1M コンテキストは CLAUDE_CODE_MAX_CONTEXT_TOKENS で伝える。
export ANTHROPIC_MODEL="deepseek-v4-flash"
export ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-v4-flash"
export ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-flash"
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="1048576"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"
export CLAUDE_CODE_SUBAGENT_MODEL="deepseek-v4-flash"
export CLAUDE_CODE_EFFORT_LEVEL="max"

# ↑ もし起動時に「モデル名が無効」エラーが出る環境では（GitHub Issue #56990）、
#   上の ANTHROPIC_MODEL を次のどちらかに差し替えてください:
#   A案（表示も deepseek にしたい・検証スキップ）:
#     export ANTHROPIC_CUSTOM_MODEL_OPTION="deepseek-v4-flash"
#   B案（動けばよい・表示は Opus）: ANTHROPIC_MODEL 行を消し、
#     起動後に /model で opus を選ぶ（サーバ側で v4 に振り分け）。

# -- 送信検査 Gateway 経由でガード付き Claude Code を起動 ----------
# launch-deepseek-gateway.sh が ds-gateway を起動し、health 確認後に
# ANTHROPIC_BASE_URL をプロキシへ向けてから launch-claude-safe.sh を呼ぶ。
# 送信プロンプトは DeepSeek 到達前に「主要な API キー・一部 PII」をマスキングし、
# ガード（PreToolUse hook）も継続して効く。氏名・住所など拾えないものは自分で消すこと。
GATEWAY_LAUNCH="$HOOKS/deepseek/launch-deepseek-gateway.sh"
echo ""
echo "送信検査 Gateway 経由で DeepSeek バックエンドの Claude Code を起動します..."
echo "（主要な API キー・一部 PII を送信前にマスク。氏名・住所など拾えないものは送る前に自分で消してください）"
echo ""
if [ -f "$GATEWAY_LAUNCH" ]; then
  bash "$GATEWAY_LAUNCH" "$WORKSPACE"
  EXITCODE=$?
else
  echo "【エラー】送信検査 Gateway ($GATEWAY_LAUNCH) が見つかりません。"
  echo "  最新の安全パッケージを再インストールしてください。"
  EXITCODE=1
fi

echo ""
echo "Claude Code（DeepSeek）を終了しました。"
echo "確認: https://platform.deepseek.com/ の Usage / Billing で"
echo "      残高が減っていれば、確実に DeepSeek が動いていました。"
echo ""
read -r -p "Enter で閉じます..." _
exit $EXITCODE
