#!/usr/bin/env bash
# ============================================================
# AI エージェント安全パッケージ  ワンクリックインストーラー
# ============================================================
# このファイルをダブルクリックするだけでインストールが完了します
#
# 【Mac の「開発元未確認」警告が出た場合】
#   ファイルを右クリック（2本指クリック）→「開く」→「開く」
#   と操作してください。次回からはダブルクリックで起動できます。

set -euo pipefail

# -- 1. 自分が存在するフォルダを取得 ----------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# install-one-click.command は scripts/macos/ にある。
# パッケージルートは 2 階層上。
PKG_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo ""
echo "============================================================"
echo "  AI エージェント安全パッケージ  インストーラー v1.4.4"
echo "============================================================"
echo ""

# install.sh の存在確認
if [ ! -f "$SCRIPT_DIR/install.sh" ]; then
    echo "【エラー】install.sh が見つかりません。"
    echo "  ZIP を正しく展開してから、このファイルをダブルクリックしてください。"
    echo "  詳しくは docs/03_自宅Macで使う.md を参照してください。"
    echo ""
    read -r -p "Enterキーで閉じる..." _
    exit 1
fi

# -- 2. workspace パスの決定 ------------------------------------
WORKSPACE="$HOME/Documents/my-ai-workspace"

# -- 3. 既存 workspace の確認 -----------------------------------
if [ -d "$WORKSPACE" ]; then
    echo "【確認】すでに workspace が存在します。"
    echo "  場所: $WORKSPACE"
    echo "  バックアップしてから再セットアップします。"
    echo ""
    read -r -p "よろしければ Enter キーを押してください（Ctrl+C でキャンセル）..."
    echo ""
fi

# -- 4. install.sh を呼ぶ ---------------------------------------
echo "[1/3] インストール中... （少し時間がかかります）"
echo ""

if bash "$SCRIPT_DIR/install.sh" "$WORKSPACE"; then
    echo ""
    echo "  インストール完了。"
else
    echo ""
    echo "【エラー】インストールに失敗しました。"
    echo "  上のメッセージでエラーの内容を確認してください。"
    echo "  解決できない場合は docs/03_自宅Macで使う.md を読んでください。"
    echo "  または、講師に画面を見せてください。"
    echo ""
    read -r -p "Enterキーで閉じる..." _
    exit 1
fi

# -- 5. doctor.sh で動作確認 ------------------------------------
DOCTOR="$WORKSPACE/.ai-safety/hooks/macos/doctor.sh"
echo ""
echo "[2/3] 動作確認中..."
echo ""
if [ -f "$DOCTOR" ]; then
    bash "$DOCTOR"
else
    echo "  doctor.sh が見つかりませんでした。インストール後に手動で確認してください。"
fi

# -- 6. 完了画面 ------------------------------------------------
echo ""
echo "============================================================"
echo "  [3/3] インストール完了！"
echo "============================================================"
echo ""
echo "  workspace の場所:"
echo "    $WORKSPACE"
echo ""
echo "  ============================================================"
echo "  【毎回この手順で起動してください】"
echo "  ============================================================"
echo ""
echo "  1. ターミナルで workspace フォルダに移動:"
echo "     cd ~/Documents/my-ai-workspace"
echo ""
echo "  2. 安全起動コマンドを実行:"
echo "     bash .ai-safety/hooks/macos/launch-codex-safe.sh"
echo ""
echo "  ★ 重要: 素の 'codex' コマンドを直接打たないでください。"
echo "     launch-codex-safe を使わない場合、このパッケージの"
echo "     launcher 経由の保護は効きません。"
echo ""
echo "  3. AI の動きを確認したい場合は別ターミナルで:"
echo "     bash .ai-safety/hooks/macos/monitor.sh"
echo ""
echo "  詳しい使い方は docs/00_クイックスタート.md を参照してください。"
echo ""
read -r -p "Enterキーで閉じる..." _
