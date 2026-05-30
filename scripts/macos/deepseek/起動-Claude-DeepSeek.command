#!/usr/bin/env bash
# ============================================================
# 起動-Claude-DeepSeek.command
# 「DeepSeek を裏で使う Claude Code」を、本パッケージの保護フック
# （ガード）が効いたまま起動します（Mac 版）。
# ------------------------------------------------------------
# 重要（正直にお伝えする事実）:
#   ・会話内容は DeepSeek（中国管轄のサーバー）に送信されます。
#     本パッケージのガードは「AI のツール操作（ファイル削除・危険な
#     コマンド実行など）の暴走」を止めますが、DeepSeek への
#     「送信そのもの」は止めません。流出して困る情報は書かないこと。
#   ・このファイルは素の claude を呼びません。必ず
#     launch-claude-safe.sh を経由します（ガードバイパス防止）。
# ============================================================
set -u

WORKSPACE="$HOME/Documents/my-ai-workspace"
HOOKS="$WORKSPACE/.ai-safety/hooks/macos"
LAUNCH_CLAUDE="$HOOKS/launch-claude-safe.sh"
DEEPSEEK_GATE="$HOOKS/launch-deepseek-safe.sh"
AUTH_FILE="$HOME/.deepseek-claude/auth"

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

# -- API キーを読み込む（起動ファイルには平文で書かない） ------------
if [ -f "$AUTH_FILE" ]; then
  ANTHROPIC_AUTH_TOKEN="$(cat "$AUTH_FILE")"
  export ANTHROPIC_AUTH_TOKEN
else
  echo ""
  echo "【注意】API キーが未登録です。先に「登録-初回だけ.command」を"
  echo "  実行してから、もう一度この .command を開いてください。"
  echo ""
fi

# -- DeepSeek バックエンドへ向ける環境変数を前差し ------------------
export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
export ANTHROPIC_MODEL="deepseek-v4-pro"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"

# ↑ もし起動時に「モデル名が無効」エラーが出る環境では（GitHub Issue #56990）、
#   上の ANTHROPIC_MODEL を次のどちらかに差し替えてください:
#   A案（表示も deepseek にしたい・検証スキップ）:
#     export ANTHROPIC_CUSTOM_MODEL_OPTION="deepseek-v4-pro"
#   B案（動けばよい・表示は Opus）: ANTHROPIC_MODEL 行を消し、
#     起動後に /model で opus を選ぶ（サーバ側で v4 に振り分け）。

# -- ガード付き Claude Code を起動（素の claude は呼ばない） ----------
# launch-claude-safe.sh に workspace を渡す。スクリプト内で workspace に
# cd し、.claude/settings.json の PreToolUse hook（ガード）を効かせたまま
# claude を起動する。バックエンドだけ DeepSeek に向く。
echo ""
echo "DeepSeek バックエンドで Claude Code を起動します..."
echo "（画面のモデル表示が deepseek-v4-pro になっていればOK）"
echo ""
bash "$LAUNCH_CLAUDE" "$WORKSPACE"
EXITCODE=$?

echo ""
echo "Claude Code（DeepSeek）を終了しました。"
echo "確認: https://platform.deepseek.com/ の Usage / Billing で"
echo "      残高が減っていれば、確実に DeepSeek が動いていました。"
echo ""
read -r -p "Enter で閉じます..." _
exit $EXITCODE
