#!/usr/bin/env bash
# fetch-update.command — GitHub の最新 Release を取得して安全パッケージを更新する。
#
# 受講者はこのファイルをダブルクリックするだけ:
#   1. GitHub の「最新 Release」から配布 ZIP と .sha256 を取得
#   2. **SHA-256 を照合**してから展開（改ざん/破損を弾く）
#   3. 展開したパッケージの install.sh を workspace に対して実行（既存は backup 経由で保護）
#
# 取得先は GitHub の固定リダイレクト
#   https://github.com/<repo>/releases/latest/download/<固定名>
# を使う（GitHub API を叩かない＝未認証レート制限や JSON 解析に依存しない）。
# そのため Release には固定名 `ai-agent-safety-package.zip`(+.sha256) を必ず添付する。
#
# 依存: curl / shasum / unzip（macOS 標準）。失敗時は日本語で理由を出して終了（部分適用しない）。
set -euo pipefail

REPO="ryuichiyamaguchi/ai-agent-safety-package"
ASSET="ai-agent-safety-package.zip"
BASE="https://github.com/${REPO}/releases/latest/download"
WORKSPACE="${1:-$HOME/Documents/my-ai-workspace}"

say() { printf '%s\n' "$*"; }
die() { printf '\n【中止】%s\n' "$*" >&2; printf 'このウィンドウを閉じて、もう一度お試しください。\n' >&2; exit 1; }

command -v curl   >/dev/null 2>&1 || die "curl が見つかりません。"
command -v shasum >/dev/null 2>&1 || die "shasum が見つかりません。"
command -v ditto  >/dev/null 2>&1 || die "ditto が見つかりません。"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "最新版をダウンロードしています…"
# HTTPS のみ（リダイレクトも HTTPS に固定＝http へのダウングレード不可）。整合性は下の
# SHA-256 照合が最終防波堤（万一 host が変わっても内容がハッシュ不一致なら弾く）。
curl -fsSL --proto '=https' --proto-redir '=https' "${BASE}/${ASSET}"        -o "$tmp/pkg.zip"        || die "配布 ZIP を取得できませんでした（ネットワーク/最新 Release を確認）。"
curl -fsSL --proto '=https' --proto-redir '=https' "${BASE}/${ASSET}.sha256" -o "$tmp/pkg.zip.sha256" || die "チェックサムを取得できませんでした。"

# 2. SHA-256 照合（.sha256 の先頭トークン == 実ファイルのハッシュ）。大小を正規化し 64桁hex を検証。
expected="$(awk '{print tolower($1); exit}' "$tmp/pkg.zip.sha256")"
actual="$(shasum -a 256 "$tmp/pkg.zip" | awk '{print tolower($1)}')"
printf '%s' "$expected" | grep -Eq '^[0-9a-f]{64}$' || die "チェックサムの形式が不正です。"
[ "$expected" = "$actual" ] || die "チェックサムが一致しません（ダウンロード破損 or 改ざんの疑い）。中止します。"
say "チェックサム照合 OK。展開します…"

# 3. 展開して**厳格に**パッケージルートを特定する。
# ditto を使う（macOS 標準。Info-ZIP の unzip は日本語(CP932)ファイル名で壊れることがある）。
# 配布 ZIP は単一のトップ階層フォルダを持つ前提。トップが 1 個でなければ中止（複数 root や
# 想定外構造を弾く）。installer は固定サブパスの**通常ファイル**のみ許可（symlink 経由で
# 展開外の未検証ファイルを実行させない）。
mkdir -p "$tmp/unz"
ditto -x -k "$tmp/pkg.zip" "$tmp/unz" || die "展開に失敗しました。"
topcount="$(find "$tmp/unz" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[ "$topcount" = "1" ] || die "配布物の構造が想定と異なります（トップ階層フォルダが ${topcount} 個）。中止します。"
pkg_root="$(find "$tmp/unz" -mindepth 1 -maxdepth 1 -type d)"
installer="$pkg_root/scripts/macos/install.sh"
{ [ -f "$installer" ] && [ ! -L "$installer" ]; } || die "install.sh が見つからない/通常ファイルでないため中止します。"

# 4. install 実行（内部で backup → コピー → doctor。既存設定は上書き前に backup される）。
say "パッケージを更新しています…（既存の設定はバックアップされます）"
bash "$installer" "$WORKSPACE" || die "インストールでエラーが発生しました。"

say ""
say "✅ 更新が完了しました。ターミナルを開き直してからお使いください。"
