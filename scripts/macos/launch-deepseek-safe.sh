#!/usr/bin/env bash
# launch-deepseek-safe.sh
#
# 外部 LLM（DeepSeek 等の中国系・第三者 LLM）を使う前の「念押しゲート」と
# 機微情報スキャナのワンストップ ラッパー（v1.4.0 で新規追加）。
#
# このスクリプトは DeepSeek 本体を起動しません（公式 CLI が無いため）。
# 役割は次のとおり:
#   1. データが中国管轄サーバーに送信される事実を明示し、yes/no で同意確認
#   2. secret-scan の使い方を案内
#   3. クリップボードを scan + mask する safe-paste をその場で実行する選択肢
#
# 使い方:
#   launch-deepseek-safe.sh           # 警告 + 同意確認 + 案内
#   launch-deepseek-safe.sh --skip-warning   # 同意確認だけスキップ（推奨しない）
#   launch-deepseek-safe.sh --consent-only   # 赤枠警告 + 同意確認までで終了
#                                            # （Web UI 用ワークフロー案内は出さない）

set -u
LANG=${LANG:-en_US.UTF-8}

SKIP_WARNING=0
CONSENT_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skip-warning) SKIP_WARNING=1 ;;
    --consent-only) CONSENT_ONLY=1 ;;
  esac
done

if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[1;32m'; C_RST=$'\033[0m'
  C_BOX_TOP=$'\033[1;31m╔══════════════════════════════════════════════════════════════════╗\033[0m'
  C_BOX_MID=$'\033[1;31m║\033[0m'
  C_BOX_BOT=$'\033[1;31m╚══════════════════════════════════════════════════════════════════╝\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_RST=""
  C_BOX_TOP=""; C_BOX_MID=""; C_BOX_BOT=""
fi

PKG_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SECRET_SCAN="$PKG_ROOT/scripts/macos/secret-scan.sh"
SAFE_PASTE="$PKG_ROOT/scripts/macos/clipboard-safe-paste.sh"

if [ "$SKIP_WARNING" -ne 1 ]; then
  echo ""
  echo "$C_BOX_TOP"
  printf "%s  %s⚠  DEEPSEEK / 外部 LLM SAFETY GATE  ⚠%s%s\n" "$C_BOX_MID" "$C_RED" "$C_RST" "$C_BOX_MID"
  echo "$C_BOX_TOP"
  echo ""
  echo "${C_RED}これから DeepSeek（または他の外部 / 中国系 LLM）にデータを${C_RST}"
  echo "${C_RED}送信しようとしています。送信内容は${C_RST}"
  echo ""
  echo "  ${C_YEL}- 中国管轄のサーバーに保存される可能性があります${C_RST}"
  echo "  ${C_YEL}- 中国のサイバーセキュリティ法 / PIPL 下で政府要請に従い${C_RST}"
  echo "  ${C_YEL}  開示される可能性があります${C_RST}"
  echo "  ${C_YEL}- Anthropic / OpenAI のプライバシーポリシー対象外です${C_RST}"
  echo ""
  echo "${C_RED}ルール:${C_RST}"
  echo "  ${C_GRN}✓ 絶対に流出しても問題ない情報だけ扱う${C_RST}"
  echo "  ${C_GRN}✓ 本物の API キー・パスワードを書かない${C_RST}"
  echo "  ${C_GRN}✓ 顧客名・社外秘・個人情報を書かない${C_RST}"
  echo "  ${C_GRN}✓ 機微情報は secret-scan でマスキングしてから貼り付ける${C_RST}"
  echo ""
  printf "上記を理解した上で続行しますか？ (yes/no): "
  read -r ANSWER
  if [ "$ANSWER" != "yes" ]; then
    echo ""
    echo "${C_GRN}キャンセルしました。${C_RST}"
    exit 1
  fi
fi

# --consent-only: 同意確認だけ取って終了（Claude Code on DeepSeek 文脈では
# クリップボード貼り付けが発生しないため、以降の Web UI 用案内は出さない）。
if [ "$CONSENT_ONLY" -eq 1 ]; then
  exit 0
fi

echo ""
echo "${C_GRN}===== 推奨ワークフロー =====${C_RST}"
echo ""
echo "  1. DeepSeek の Web UI（chat.deepseek.com）または公式 CLI を別画面で開く"
echo "  2. プロンプトを書き終わったらコピー（⌘C）"
echo "  3. 以下のコマンドでクリップボードをスキャン＋マスキング:"
echo "     ${C_YEL}safe-paste${C_RST}"
echo "  4. DeepSeek に貼り付け（⌘V）"
echo ""
echo "${C_GRN}===== コマンドリファレンス =====${C_RST}"
echo ""
echo "  secret-scan < prompt.txt           # ファイルをスキャン＋マスキング"
echo "  echo \"text\" | secret-scan          # 標準入力をスキャン"
echo "  pbpaste | secret-scan --check      # 検出件数だけ確認（マスキングなし）"
echo "  safe-paste                          # クリップボードを scan + mask（推奨）"
echo ""
echo "${C_GRN}===== 監査ログ =====${C_RST}"
echo ""
echo "  ${HOME}/.ai-safety/logs/secret-scan-events.jsonl"
echo "  （マスキング件数のみ記録、本物の値は記録されません）"
echo ""

# その場で safe-paste を実行するか
if [ -t 0 ] && [ -x "$SAFE_PASTE" ]; then
  printf "今すぐクリップボードをスキャンしますか？ (y/N): "
  read -r RUN_NOW
  if [ "$RUN_NOW" = "y" ] || [ "$RUN_NOW" = "Y" ]; then
    echo ""
    "$SAFE_PASTE"
  fi
fi

echo ""
echo "${C_GRN}DeepSeek セッションが終わったら、機微情報を貼り付けていないか${C_RST}"
echo "${C_GRN}監査ログをセルフチェックしてください。${C_RST}"
echo ""
exit 0
