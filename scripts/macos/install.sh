#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [--platform mac|win|both] [--global-claude] [workspace]
  --platform: install hooks for which OS (default: mac)
              "both" installs both mac and win hooks (win hooks become read-only)
  --global-claude: also install Claude settings to \$HOME/.claude/
  workspace: target workspace directory (default: \$HOME/Documents/my-ai-workspace)
EOF
}

PLATFORM="mac"
workspace=""
install_global_claude=""

# Argument parsing: keep backward compatibility with positional
# "workspace" and legacy "--global-claude" / "$2" form.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      PLATFORM="${2:-}"
      shift 2
      ;;
    --platform=*)
      PLATFORM="${1#*=}"
      shift
      ;;
    --global-claude)
      install_global_claude="--global-claude"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [ -z "$workspace" ]; then
        workspace="$1"
      elif [ -z "$install_global_claude" ]; then
        install_global_claude="$1"
      fi
      shift
      ;;
  esac
done

case "$PLATFORM" in
  mac|win|both) ;;
  *) echo "Error: --platform must be mac, win, or both" >&2; exit 1 ;;
esac

package_root="$(cd "$(dirname "$0")/../.." && pwd)"

# B-3: workspace 未指定時は安全なデフォルト ($HOME/Documents/my-ai-workspace) を使用。
# CWD がパッケージフォルダ自身の場合も同様に安全デフォルトへ。
if [ -z "$workspace" ]; then
  workspace="$HOME/Documents/my-ai-workspace"
  echo "INFO: workspace not specified. Using default: $workspace"
fi

# 相対パスを絶対パスに変換（mkdir -p 後に cd で正規化）
# B-2: 親ディレクトリが存在しなくても mkdir -p で自動作成。
mkdir -p "$workspace"
workspace="$(cd "$workspace" && pwd)"

# B-3: ZIP 展開フォルダ自身を workspace に指定した場合は安全停止。
if [ "$workspace" = "$package_root" ]; then
  echo "エラー: workspace にパッケージフォルダ自身を指定しないでください。" >&2
  echo "例: bash scripts/macos/install.sh \$HOME/Documents/my-ai-workspace" >&2
  exit 1
fi

stamp="$(date +%Y%m%d-%H%M%S)"
backup_root="${AI_SAFE_BACKUP_ROOT:-$HOME/.ai-safety/backups}"
backup_dir="$backup_root/$stamp"
mkdir -p "$backup_dir" "$workspace/.ai-safety/hooks" "$workspace/.ai-safety/policy" "$workspace/.ai-safety/cards"
# 利用者が自分でプラグインを置く場所（v1.15.0〜）。`.ai-safety` は AI の書き込み禁止パスなので
# AI にはこのフォルダを作れず、ここに置けるのは人だけ。隠しフォルダの下なので受講者が Finder /
# エクスプローラーで作るのは難しく、こちらで用意しておく（中身は空のまま）。
mkdir -p "$workspace/.ai-safety/plugins"
# 置き方の説明を 1 枚だけ置く。ランチャーは .js / .ts しか見ないので .txt は読み込まれない。
# 既にあるときは触らない（利用者が書き足しているかもしれないため）。
if [ ! -e "$workspace/.ai-safety/plugins/README.txt" ]; then
  cat > "$workspace/.ai-safety/plugins/README.txt" <<'PLUGIN_README'
このフォルダは、OpenCode で使うプラグインを自分で置く場所です。

・ここに .js または .ts のファイルを置くと、次に統合ランチャーから OpenCode を
  起動したときに読み込みます。
・このフォルダの直下だけを見ます。中にフォルダを作って入れても読み込みません。
・初めて置いたとき、中身を変えたときは、起動が一度止まって名前を表示し、
  Enter を押すまで先に進みません（顔ぶれが同じなら次からは聞きません）。
・置いていないときは、これまでと同じ静かな起動になります。

【重要】ここに置いたコードは、承認モニターの確認を通りません。
「このコマンドを実行していいですか」の確認画面が出ないだけでなく、
見守りの仕組みそのものを止めることもできます。
中身を自分で確かめたものだけを置いてください。

うまく起動しなくなったときは、まずこのフォルダを疑ってください。
プラグインの書き方が誤っていると、OpenCode はプラグインの読み込み全体を中止し、
見守りプラグインも載らないため、安全のため起動を止めます。
「導入をやり直す」ではこのフォルダは消えません。中身を別の場所へ移してから
起動し直してください。

詳しくは説明書の「10_OpenCode_DeepSeekを安全に使う」の
「自分で入れたプラグインを使う」を読んでください。
PLUGIN_README
fi

echo "Installing for platform: $PLATFORM"

# H6/B: verify distribution integrity against docs/tested_versions.md hash table.
# 破損/改変された配布物を「同じPCで人により違うエラー」の温床にしないため、
# ハッシュ不一致は**既定で中止**する（何もコピーする前に exit 非0）。verify_hash 群は
# 全コピー処理より前に呼ぶので、中止時はワークスペースを一切変更しない。
# 開発者/講師が意図的に policy.json 等を変更したときだけ、明示 opt-out
# AI_SAFE_ALLOW_HASH_MISMATCH=1 で続行できる（その場合も警告は出す）。
# 旧 AI_SAFETY_STRICT=1 は「既定で中止」に統合され不要になった（既定が常に strict）。
versions_file="$package_root/docs/tested_versions.md"

# macOS の Finder / Archive Utility は、ZIP 展開時に日本語ファイル名の濁点を
# 分離形 (NFD / UTF-8-MAC) にすることがある。Git と docs/tested_versions.md は
# 合成形 (NFC) のため、パスをそのまま grep すると同じ見た目でも「未登録」になる。
# 実ファイルの読み込みは元パス、一覧照合だけ NFC に正規化する。
normalize_hash_rel_path() {
  local input_path="$1"
  local normalized_path=""
  if command -v iconv >/dev/null 2>&1; then
    normalized_path="$(printf '%s' "$input_path" | iconv -f UTF-8-MAC -t UTF-8 2>/dev/null || true)"
    if [ -n "$normalized_path" ]; then
      printf '%s' "$normalized_path"
      return 0
    fi
  fi
  printf '%s' "$input_path"
}

# 検証表そのものが欠けていると、以下のハッシュ検証が 1 件残らずスキップされる
# （＝改ざんに気付けないまま全部配置してしまう）。「表が無い＝検証できない＝配布物が
# 壊れている」ので既定で中止する。開発者/講師が承知の上で進めるときだけ
# AI_SAFE_ALLOW_HASH_MISMATCH=1 で警告に落とせる。
if [ ! -f "$versions_file" ]; then
  if [ "${AI_SAFE_ALLOW_HASH_MISMATCH:-0}" = "1" ]; then
    echo "警告: 改ざん検知の一覧 docs/tested_versions.md がありません。" >&2
    echo "      AI_SAFE_ALLOW_HASH_MISMATCH=1 が設定されているため、検証せずに続行します。" >&2
  else
    echo "エラー: 配布物が壊れています。改ざん検知の一覧 docs/tested_versions.md が見つかりません。" >&2
    echo "  この表が無いと配布ファイルの改ざん検知が一切できないため、インストールを中止します。" >&2
    echo "  パッケージを配布元から取り直してください。" >&2
    echo "  （講師が承知の上で進める場合のみ AI_SAFE_ALLOW_HASH_MISMATCH=1 を設定して再実行）" >&2
    exit 1
  fi
fi

verify_hash() {
  rel_path="$1"
  lookup_rel_path="$(normalize_hash_rel_path "$rel_path")"
  abs_path="$package_root/$rel_path"
  [ -f "$abs_path" ] || return 0
  [ -f "$versions_file" ] || return 0
  # Look up "| <rel_path> | <sha> |" rows in tested_versions.md.
  # 行が無いファイルは検証対象外として素通しする。`set -o pipefail` 下では grep の
  # 「見つからない=1」がそのまま代入の失敗になり、set -e で install ごと落ちるため
  # `|| true` で受ける（ハッシュ不一致のときの中止は下の比較でそのまま行う）。
  expected="$(grep -F "| $lookup_rel_path |" "$versions_file" 2>/dev/null | head -n1 | awk -F'|' '{gsub(/ /,"",$3); print $3}' || true)"
  [ -n "$expected" ] || return 0
  actual="$(shasum -a 256 "$abs_path" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "エラー: 配布ファイルのハッシュが一致しません: $rel_path" >&2
    echo "  期待値: $expected" >&2
    echo "  実際:   $actual" >&2
    echo "  配布が壊れているか、改変された可能性があります。安全のためインストールを中止します。" >&2
    if [ "${AI_SAFE_ALLOW_HASH_MISMATCH:-0}" = "1" ]; then
      echo "  （AI_SAFE_ALLOW_HASH_MISMATCH=1 が設定されているため、警告のまま続行します。開発者/講師のカスタマイズ用）" >&2
    else
      echo "  講師が意図的に変更した場合は docs/tested_versions.md のハッシュを更新するか、" >&2
      echo "  環境変数 AI_SAFE_ALLOW_HASH_MISMATCH=1 を設定して再実行してください。" >&2
      exit 1
    fi
  fi
}

verify_hash "policy/safety-policy.json"
case "$PLATFORM" in
  mac)
    verify_hash "configs/codex/hooks.mac.json"
    verify_hash "configs/claude/settings.mac.json"
    verify_hash "configs/gemini/settings.mac.json"
    verify_hash "configs/codex/config.mac.toml"
    verify_hash "configs/codex/safe.config.toml"
    ;;
  win)
    verify_hash "configs/codex/hooks.windows.json"
    verify_hash "configs/claude/settings.windows.json"
    verify_hash "configs/gemini/settings.windows.json"
    verify_hash "configs/codex/config.windows.toml"
    ;;
  both)
    verify_hash "configs/codex/hooks.mac.json"
    verify_hash "configs/codex/hooks.windows.json"
    verify_hash "configs/claude/settings.mac.json"
    verify_hash "configs/claude/settings.windows.json"
    verify_hash "configs/gemini/settings.mac.json"
    verify_hash "configs/gemini/settings.windows.json"
    verify_hash "configs/codex/config.mac.toml"
    verify_hash "configs/codex/safe.config.toml"
    verify_hash "configs/codex/config.windows.toml"
    ;;
esac
# 「必ず検証対象であるべき」ファイル用。表に行が無い＝そのファイルだけ改ざん検知が
# 効かない状態なので、黙って素通しせず知らせる。
#
# 扱いは 2 段階にする:
#   (a) AI に読ませる指示書（opencode-harness / dist-opencode / dist-skills 配下）は
#       実質コード相当で、余分な .md が 1 枚混じるだけで無検証のままモデル指示として
#       有効になってしまう。ここは登録漏れも**中止**する（fail-closed）。
#       講師が承知の上で進めるときだけ AI_SAFE_ALLOW_UNLISTED_HARNESS=1 で続行できる。
#   (b) それ以外の一般ファイルは従来どおり**警告のみ**で続行する。受講者の導入を
#       止めないほうを優先し、登録漏れはリリース前のテストで落とす
#       （scripts/common/test/opencode-harness.test.js が「同梱物に未登録が無いこと」を検査）。
hash_listing_required() {
  case "$1" in
    workspace-template/opencode-harness/*|workspace-template/dist-opencode/*|workspace-template/dist-skills/*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

verify_hash_listed() {
  rel_path="$1"
  lookup_rel_path="$(normalize_hash_rel_path "$rel_path")"
  if [ -f "$package_root/$rel_path" ] && [ -f "$versions_file" ] \
     && ! grep -qF "| $lookup_rel_path |" "$versions_file" 2>/dev/null; then
    if hash_listing_required "$rel_path" && [ "${AI_SAFE_ALLOW_UNLISTED_HARNESS:-0}" != "1" ]; then
      echo "エラー: このファイルは改ざん検知の一覧に登録されていません: $rel_path" >&2
      echo "  AI に読ませる指示書は実質コード相当のため、未検証のまま配置せずに中止します。" >&2
      echo "  講師向け: docs/tested_versions.md にハッシュ行を追加してください。" >&2
      echo "  （承知の上で進める場合のみ AI_SAFE_ALLOW_UNLISTED_HARNESS=1 を設定して再実行）" >&2
      exit 1
    fi
    echo "警告: このファイルは改ざん検知の一覧に登録されていません: $rel_path" >&2
    echo "      講師向け: docs/tested_versions.md にハッシュ行を追加してください。" >&2
  fi
  verify_hash "$rel_path"
}

# v1.17.0: 秘密の金庫・マスキング・PC 全体設定・フォルダ保護・長時間おまかせモードの実体も
# 改ざん検知の対象に入れる。これらは「安全装置そのもの」なので、設定ファイルだけ守っても足りない。
# 表に行が無いファイルは素通しする実装なので、片 OS 分しか入っていない配布でも壊れない。
for _sec in \
  "scripts/common/secret-store.js" \
  "scripts/common/secret-migrate.js" \
  "scripts/common/secret-patterns.js" \
  "scripts/common/clipboard-mask.js" \
  "scripts/common/apply-global-guard.js" \
  "scripts/common/apply-global-codex.js" \
  "scripts/common/apply-global-agy.js" \
  "scripts/common/apply-global-opencode.js" \
  "scripts/common/apply-global-deny.js" \
  "scripts/macos/apply-global-guard.sh" \
  "scripts/macos/uninstall-global-guard.sh" \
  "scripts/macos/protect-folder.sh" \
  "scripts/macos/launch-longrun.sh" \
  "scripts/windows/apply-global-guard.ps1" \
  "scripts/windows/uninstall-global-guard.ps1" \
  "scripts/windows/protect-folder.ps1" \
  "scripts/windows/launch-longrun.ps1"; do
  verify_hash "$_sec"
done

verify_hash "configs/gemini/policies/safety.toml"
verify_hash "workspace-template/aiexclude.template"
verify_hash_listed "workspace-template/dist-skills/hearing-ladder/SKILL.md"
# OpenCode 用の日本語ハーネス（AGENTS.md / スラッシュコマンド / 追加エージェント）。
# モデルに読ませる指示書＝実質コード相当なので、同梱ファイルは丸ごとハッシュ検証対象にする。
for harness_candidate in opencode-harness dist-opencode; do
  [ -d "$package_root/workspace-template/$harness_candidate" ] || continue
  while IFS= read -r harness_file; do
    verify_hash_listed "${harness_file#"$package_root"/}"
  done < <(find "$package_root/workspace-template/$harness_candidate" -type f -name '*.md' | sort)
  break
done

copy_with_backup() {
  src="$1"
  dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ]; then
    safe_name="$(printf '%s' "$dest" | sed 's#[/:]#_#g')"
    cp -R "$dest" "$backup_dir/$safe_name"
  fi
  cp -R "$src" "$dest"
}

cp "$package_root/policy/safety-policy.json" "$workspace/.ai-safety/policy/safety-policy.json"

# コピー元パッケージの場所を残す。「新しい作業フォルダを安全にする」ボタンは、
# ワークスペース側から実行されたときにこれを辿ってパッケージ本体（configs / policy /
# workspace-template）を見つける。見つからなければボタン側が案内して止まる。
printf '%s\n' "$package_root" > "$workspace/.ai-safety/package-source.txt"
chmod 600 "$workspace/.ai-safety/package-source.txt" 2>/dev/null || true

# agent-monitor 解説カード一式を .ai-safety/cards/ に配置する。
if [ -d "$package_root/configs/safety/cards" ]; then
  rm -rf "$workspace/.ai-safety/cards"
  cp -R "$package_root/configs/safety/cards" "$workspace/.ai-safety/cards"
fi

if [[ "$PLATFORM" == "mac" || "$PLATFORM" == "both" ]]; then
  cp -R "$package_root/scripts/macos" "$workspace/.ai-safety/hooks/"
  chmod +x "$workspace/.ai-safety/hooks/macos/"*.sh \
    "$workspace/.ai-safety/hooks/macos/lib/"*.sh \
    "$workspace/.ai-safety/hooks/macos/opencode/"*.sh
fi

if [[ "$PLATFORM" == "win" || "$PLATFORM" == "both" ]]; then
  cp -R "$package_root/scripts/windows" "$workspace/.ai-safety/hooks/"
  # Foreign-OS hooks become read-only to shrink attack surface (H3).
  find "$workspace/.ai-safety/hooks/windows" -type f -exec chmod 600 {} \;
fi

# DeepSeek 送信検査 Gateway（クロスプラットフォーム・Node 実装）を配置
cp -R "$package_root/scripts/common" "$workspace/.ai-safety/hooks/"

# 旧「最大保護モード」で使っていたローカル検査 Gateway（ローカル LLM 必須）は v1.17.0 で
# 廃止した。受講生の PC ではほぼ動かせないのにメニューに出ていたため。既存の作業フォルダに
# 残っている古い配置はバックアップしてから片付ける。
legacy_bouncer="$workspace/.ai-safety/bouncer"
if [ -e "$legacy_bouncer" ]; then
  safe_name="$(printf '%s' "$legacy_bouncer" | sed 's#[/:]#_#g')"
  cp -R "$legacy_bouncer" "$backup_dir/$safe_name" 2>/dev/null || true
  rm -rf "$legacy_bouncer"
fi

# Remove stale foreign-OS hook directories when single-platform install
# is requested (defensive cleanup on re-install).
if [[ "$PLATFORM" == "mac" ]] && [ -d "$workspace/.ai-safety/hooks/windows" ]; then
  rm -rf "$workspace/.ai-safety/hooks/windows"
fi
if [[ "$PLATFORM" == "win" ]] && [ -d "$workspace/.ai-safety/hooks/macos" ]; then
  rm -rf "$workspace/.ai-safety/hooks/macos"
fi

copy_with_backup "$package_root/configs/claude/settings.mac.json" "$workspace/.claude/settings.json"
copy_with_backup "$package_root/configs/codex/config.mac.toml" "$workspace/.codex/config.toml"
copy_with_backup "$package_root/configs/codex/safe.config.toml" "$workspace/.codex/safe.config.toml"
copy_with_backup "$package_root/configs/codex/hooks.mac.json" "$workspace/.codex/hooks.json"
copy_with_backup "$package_root/configs/gemini/settings.mac.json" "$workspace/.gemini/settings.json"
copy_with_backup "$package_root/configs/gemini/policies/safety.toml" "$workspace/.gemini/policies/safety.toml"
copy_with_backup "$package_root/workspace-template/aiexclude.template" "$workspace/.aiexclude"

# 各agentのプロジェクト指示。利用者が既に編集している場合は上書きしない。
for guide in AGENTS.md CLAUDE.md GEMINI.md; do
  if [ -f "$package_root/workspace-template/$guide" ] && [ ! -e "$workspace/$guide" ]; then
    cp "$package_root/workspace-template/$guide" "$workspace/$guide"
  fi
done

# 配布スキルを workspace の .claude/skills/ に配置。d-claude / claude が起動時に
# ${workspace}/.claude/skills 配下を読み込むので、ここに置けば受講者もそのまま使える。
# リポジトリ側は dist-skills/ に置く（.gitignore が .claude/ を除外するため）。
# スキル単位で処理: 同名の既存スキル（ユーザーが手を入れた版も含む）は backup へ退避してから
# ディレクトリごと入れ替える（copy_with_backup と同じ思想＝上書き前に必ず控えを取る／古い
# support ファイルが残らない）。同梱していない他スキルには触れない。
# ※ かつて .opencode/skills/ にも同じものを置いていたが、OpenCode 統合ランチャーは
#   OPENCODE_DISABLE_PROJECT_CONFIG=1 で起動するためプロジェクトの .opencode/ は
#   スキャンされない（プローブスキルで実測）。死にコードなので廃止し、OpenCode 用は
#   下の .ai-safety/dist-skills →（起動時に）隔離設定ディレクトリ側へ一本化した。
if [ -d "$package_root/workspace-template/dist-skills" ]; then
  mkdir -p "$workspace/.claude/skills"
  for skill_src in "$package_root/workspace-template/dist-skills"/*/; do
    [ -d "$skill_src" ] || continue
    skill_name="$(basename "$skill_src")"
    skill_dest="$workspace/.claude/skills/$skill_name"
    if [ -e "$skill_dest" ]; then
      safe_name="$(printf '%s' "$skill_dest" | sed 's#[/:]#_#g')"
      cp -R "$skill_dest" "$backup_dir/$safe_name"
      rm -rf "$skill_dest"
    fi
    cp -R "$skill_src" "$skill_dest"
  done
  echo "配布スキルを配置しました: $workspace/.claude/skills"

  # OpenCode 統合ランチャー用の配布元。起動時に隔離設定ディレクトリ
  # （$XDG_CONFIG_HOME/opencode/skills/）へ毎回コピーされる。
  dist_skills_dest="$workspace/.ai-safety/dist-skills"
  if [ -e "$dist_skills_dest" ]; then
    safe_name="$(printf '%s' "$dist_skills_dest" | sed 's#[/:]#_#g')"
    cp -R "$dist_skills_dest" "$backup_dir/$safe_name"
    rm -rf "$dist_skills_dest"
  fi
  cp -R "$package_root/workspace-template/dist-skills" "$dist_skills_dest"
fi

# OpenCode 用の日本語ハーネス一式（AGENTS.md / スラッシュコマンド / 追加エージェント）を
# .ai-safety 配下に配置する。起動時にランチャーが隔離設定ディレクトリへ毎回コピーするので、
# ここが配布元になる。配布元フォルダ名は制作途中で opencode-harness / dist-opencode の
# 両方が使われたため、存在するほうを採用して配置先の名前は 1 つに正規化する。
harness_src=""
for harness_candidate in opencode-harness dist-opencode; do
  if [ -d "$package_root/workspace-template/$harness_candidate" ]; then
    harness_src="$package_root/workspace-template/$harness_candidate"
    break
  fi
done
if [ -n "$harness_src" ]; then
  harness_dest="$workspace/.ai-safety/opencode-harness"
  if [ -e "$harness_dest" ]; then
    safe_name="$(printf '%s' "$harness_dest" | sed 's#[/:]#_#g')"
    cp -R "$harness_dest" "$backup_dir/$safe_name"
    rm -rf "$harness_dest"
  fi
  cp -R "$harness_src" "$harness_dest"
  echo "OpenCode 用の日本語ハーネスを配置しました: $harness_dest"
fi

# 受講者向けスタートフォルダ（番号ラッパー + 案内 HTML）を workspace に配置。
# ファイルシステム構造とは別に「ここを見てポチポチやれば使える」入口を用意する。
if [ -d "$package_root/workspace-template/スタート" ]; then
  mkdir -p "$workspace/スタート"
  # v1.16.0 / v1.17.1 の番号再編で名前が変わった旧ボタンを掃除する（旧新併存による番号重複の防止）。
  # v1.17.1: 「5_セーフOpenCodeを起動」を基本枠に入れたぶん、旧 5〜12 が 1 つずつ繰り下がった。
  # 消すのは「パッケージが過去に配布した既知の旧名」だけに限定し、受講者の自作ファイルには触らない。
  # Finder / Archive Utility 経由の展開はファイル名が NFD (UTF-8-MAC) になることがあるため、
  # 名前を NFC に正規化してから照合する（install のハッシュ照合と同じ手法）。
  legacy_start_names='0_Bouncer統合版を起動.command
0_Bouncer統合版を起動.bat
6_最新版に更新.command
6_最新版に更新.bat
7_困ったとき診断.bat
7_野良d-claudeを退治.command
7_野良d-claudeを退治.bat
8_PowerShellを開く.bat
9_作業ウィンドウを開く.bat
（上級）5_モニターをコンソールで見る.command
（上級）5_モニターをコンソールで見る.bat
（上級）6_ステータスラインを入れる.command
（上級）6_ステータスラインを入れる.bat
（上級）7_危険コマンドをClaude全体で禁止.command
（上級）7_危険コマンドをClaude全体で禁止.bat
（上級）8_グローバル禁止を解除.command
（上級）8_グローバル禁止を解除.bat
（上級）9_DeepSeekキーを削除.command
（上級）9_DeepSeekキーを削除.bat
（上級）10_ccmuxを入れる.command
（上級）10_ccmuxを入れる.bat
（上級）11_Bufferのキーを登録.command
（上級）11_Bufferのキーを登録.bat
（上級）12_プラグインの置き場を開く.command
（上級）12_プラグインの置き場を開く.bat
（上級）5_危険コマンドをClaude全体で禁止.command
（上級）5_危険コマンドをClaude全体で禁止.bat
（上級）6_グローバル禁止を解除.command
（上級）6_グローバル禁止を解除.bat
5_見守りモニターを起動.command
5_見守りモニターを起動.bat
6_AIコーチのキーを登録.command
6_AIコーチのキーを登録.bat
7_安全パッケージを最新版に更新.command
7_安全パッケージを最新版に更新.bat
8_AIツールを最新版に更新.command
8_AIツールを最新版に更新.bat
9_困ったとき診断.command
9_困ったとき診断.bat
10_野良d-claudeを退治.command
10_野良d-claudeを退治.bat
11_PowerShellを開く.bat
12_作業フォルダを開く.bat'
  for _old in "$workspace/スタート"/*; do
    [ -f "$_old" ] || continue
    _old_name="$(normalize_hash_rel_path "$(basename "$_old")")"
    if printf '%s\n' "$legacy_start_names" | grep -qxF "$_old_name"; then
      rm -f "$_old"
      echo "旧ボタンを削除しました: スタート/$_old_name"
    fi
  done
  cp -R "$package_root/workspace-template/スタート/." "$workspace/スタート/"
  if [ -f "$package_root/スタート.html" ]; then
    # workspace 配置（スタート/スタート.html）では説明書が ../docs/ にあるため、
    # コピー時にリンクだけ書き換える。パッケージ直下の スタート.html は docs/ のままで正しい。
    sed 's#href="docs/#href="../docs/#g' "$package_root/スタート.html" > "$workspace/スタート/スタート.html"
  fi
  # 受講者が同名ファイル（.command と .bat）で迷わないよう、当該 OS 用だけ残す。
  if [[ "$PLATFORM" == "mac" ]]; then
    rm -f "$workspace/スタート/"*.bat
  elif [[ "$PLATFORM" == "win" ]]; then
    rm -f "$workspace/スタート/"*.command
  fi
  chmod +x "$workspace/スタート/"*.command 2>/dev/null || true
  echo "スタートフォルダを配置しました: $workspace/スタート"
fi

# 受講者向け説明書 (docs/) を workspace/docs/ に同期する。スタート.html や各ボタンの
# 案内が参照する説明書を、受講者が手元（ワークスペース）で開けるようにするのが目的。
# ・受講者向けのみ同期し、開発者向けの _dev/ と _archive/ は持ち込まない
# ・「パッケージ由来のファイルだけ」を上書き・削除の対象にする。前回配布した一覧
#   （マニフェスト）に載っていて今回の配布に無いファイルだけを消すので、受講者が
#   docs/ 内に置いた自作メモには触らない
# ・上書き前に既存 docs/ を丸ごと控え（backup_dir）に取る（copy_with_backup と同じ思想）
if [ -d "$package_root/docs" ]; then
  docs_dest="$workspace/docs"
  docs_manifest="$workspace/.ai-safety/docs-manifest.txt"
  if [ -e "$docs_dest" ]; then
    safe_name="$(printf '%s' "$docs_dest" | sed 's#[/:]#_#g')"
    cp -R "$docs_dest" "$backup_dir/$safe_name"
  fi
  mkdir -p "$docs_dest"
  # 今回配布するファイル一覧（docs/ からの相対パス。_dev / _archive は除外）
  docs_new_list="$(cd "$package_root/docs" && find . \( -name _dev -o -name _archive \) -prune -o -type f -print | sed 's#^\./##' | sort)"
  while IFS= read -r _rel; do
    [ -n "$_rel" ] || continue
    mkdir -p "$docs_dest/$(dirname "$_rel")"
    cp "$package_root/docs/$_rel" "$docs_dest/$_rel"
  done <<EOF_DOCS_COPY
$docs_new_list
EOF_DOCS_COPY
  # 前回パッケージが配ったのに今回の配布に無いファイルだけを掃除する（古い説明書の
  # 残留防止）。照合は NFC 正規化した名前で行う（Finder 展開の NFD 対策、install の
  # ハッシュ照合・旧ボタン掃除と同じ手法）。
  if [ -f "$docs_manifest" ]; then
    docs_new_list_nfc="$(printf '%s\n' "$docs_new_list" | while IFS= read -r _n; do
      if [ -n "$_n" ]; then
        printf '%s\n' "$(normalize_hash_rel_path "$_n")"
      fi
    done)"
    while IFS= read -r _old_rel; do
      [ -n "$_old_rel" ] || continue
      _old_rel_nfc="$(normalize_hash_rel_path "$_old_rel")"
      if ! printf '%s\n' "$docs_new_list_nfc" | grep -qxF "$_old_rel_nfc"; then
        if [ -f "$docs_dest/$_old_rel" ]; then
          rm -f "$docs_dest/$_old_rel"
          echo "旧説明書を削除しました: docs/$_old_rel"
        fi
      fi
    done < "$docs_manifest"
  fi
  printf '%s\n' "$docs_new_list" > "$docs_manifest"
  echo "説明書を配置しました: $docs_dest"
fi

# 動作確認済みツール版の表 (SSOT)。「9_AIツールを最新版に更新」が参照する。
if [ -f "$package_root/configs/tested-tool-versions.json" ]; then
  cp "$package_root/configs/tested-tool-versions.json" "$workspace/.ai-safety/tested-tool-versions.json"
fi

if [ "$install_global_claude" = "--global-claude" ]; then
  global_target="$HOME/.claude/settings.json"
  global_src="$package_root/configs/claude/settings.mac.json"
  deny_js="$package_root/scripts/common/apply-global-deny.js"
  # A案 (2026-07): settings を丸ごとコピーせず、permissions.deny だけを union マージする。
  # 丸ごとコピーは hook が ${CLAUDE_PROJECT_DIR}/.ai-safety を探し、そのフォルダが無い場所で
  # 全 Bash が exit2 ブロックになる落とし穴があったため廃止。既存の hooks/env/allow/ask は不変。
  if command -v node >/dev/null 2>&1; then
    echo "Merging package deny rules into global ~/.claude/settings.json (既存の hooks/env は不変)..."
    node "$deny_js" "$global_src" "$global_target" || echo "global deny merge failed (skipped)." >&2
  else
    echo "node not found; skipped global Claude deny merge (Node.js が必要です)." >&2
  fi
fi

# --- ダウンロード検疫（quarantine）の解除 ------------------------------------
# ZIP をブラウザで受け取ると、その中身すべてに com.apple.quarantine が付く。属性は
# コピーで引き継がれるため、install が配置したボタン（スタート/*.command）にもそのまま
# 移り、ダブルクリックのたびに「開発元を検証できません」で止まる。しかも更新するたび
# 新しいファイルが来て再発するので、受講者は毎回この壁に当たっていた。
#
# 外す対象は「install が今この場で配置した自分の配布物」だけに限定する（ワークスペース
# 全体や Downloads には触らない）。これらは上でファイルごとに SHA-256 照合を通しており、
# 素性が確かめられているファイルに限る、という線引き。
#
# Gatekeeper の肝心な部分は残る: 配布物を最初に開くとき（install-one-click.command 自体）
# のブロックはそのままなので、「知らない配布物を意図せず実行してしまう」ことは防がれる。
if command -v xattr >/dev/null 2>&1; then
  for _q in "$workspace/.ai-safety" "$workspace/スタート" "$workspace/docs"; do
    [ -e "$_q" ] || continue
    xattr -dr com.apple.quarantine "$_q" 2>/dev/null || true
  done
fi

# --- どこからでも打てる起動コマンド（oc-safe） -------------------------------
# OpenCode は「起動したフォルダ」が作業対象になり、動き出したあとで cd しても移らない
# （OpenCode 本体の仕様）。そのため「プロジェクトごとに分けて作業する」には、そのフォルダで
# 起動する必要がある。ccmux や Zed のターミナルからでも 1 行で起動できるよう、
# ~/.ai-safety/bin/oc-safe を置いて PATH に通す（Windows の setup-commands.ps1 と対称）。
oc_bin_dir="$HOME/.ai-safety/bin"
oc_template="$package_root/scripts/macos/oc-safe.template.sh"
if [ -f "$oc_template" ]; then
  mkdir -p "$oc_bin_dir"
  # ワークスペースの絶対パスを焼き込む（bin 配下からは呼び出し元をたどれないため）。
  awk -v ws="$workspace" '{ gsub(/__WORKSPACE__/, ws); print }' "$oc_template" > "$oc_bin_dir/oc-safe"
  chmod 755 "$oc_bin_dir/oc-safe"
  echo "起動コマンドを配置しました: $oc_bin_dir/oc-safe"

  # PATH 追加は冪等に。すでに書いてあれば触らない。
  zshrc="$HOME/.zshrc"
  path_line='export PATH="$HOME/.ai-safety/bin:$PATH"  # ai-agent-safety-package'
  if [ -f "$zshrc" ] && grep -qF '.ai-safety/bin' "$zshrc"; then
    :
  else
    {
      echo ""
      echo "# AI エージェント安全運用パッケージ（oc-safe などの起動コマンド）"
      echo "$path_line"
    } >> "$zshrc"
    echo "PATH に追加しました（新しいターミナルから oc-safe が使えます）: $oc_bin_dir"
  fi
fi

# --- 安全ランチャーのシム（codex-safe / claude-safe / agy-safe） -------------
# 壁 A の解消。安全ランチャーの実体は <ワークスペース>/.ai-safety/hooks/macos/ にあるが、
# `.ai-safety` は決定的 deny 床の保護パスなので、AI がそのパスを書いた瞬間に deny される。
# その結果「安全フックを通る形は禁止され、フックを通らない裸の codex / claude だけが通る」
# という反転が起きていた（2026-08-20 実測）。PATH 上に短い名前のシムを置くことで、
# コマンド文字列に `.ai-safety` を書かずに安全な形を起動できるようにする。
# deny 床（policy/safety-policy.json）は 1 文字も緩めていない。
# Windows は setup-commands.ps1 が元から同名のシムを作っており、これは mac 側の欠落を
# 埋めて対称にするもの。
agent_template="$package_root/scripts/macos/agent-safe.template.sh"
if [ -f "$agent_template" ]; then
  mkdir -p "$oc_bin_dir"
  for _pair in "codex-safe:codex" "claude-safe:claude" "agy-safe:agy"; do
    _name="${_pair%%:*}"
    _agent="${_pair##*:}"
    if [ ! -f "$workspace/.ai-safety/hooks/macos/launch-${_agent}-safe.sh" ]; then
      continue
    fi
    awk -v ws="$workspace" -v nm="$_name" -v ag="$_agent" \
      '{ gsub(/__WORKSPACE__/, ws); gsub(/__NAME__/, nm); gsub(/__AGENT__/, ag); print }' \
      "$agent_template" > "$oc_bin_dir/$_name"
    chmod 755 "$oc_bin_dir/$_name"
    echo "起動コマンドを配置しました: $oc_bin_dir/$_name"
  done
fi

# --- ~/.ai-safety の権限を締める（600 / 700） --------------------------------
# ここには API キーの平文ファイル（gemini-api-key.txt / gemini-api-key-paid.txt /
# buffer-api-key.txt 等）と、AI の実行ログが置かれる。ところが作成経路がボタン・
# ランチャー・手作業とばらばらで、実測で gemini-api-key-paid.txt が 644（同じ PC の
# 他ユーザーから読める）になっていた。導入のたびに実際の権限へ落とし直す。
# ・ディレクトリ 700（本人だけが開ける）
# ・鍵/トークンのファイル 600（本人だけが読める）
# bin/ 配下の起動コマンドは実行できる必要があるので 700 を維持し、中身は 755 のまま。
if [ -d "$HOME/.ai-safety" ]; then
  chmod 700 "$HOME/.ai-safety" 2>/dev/null || true
  for _d in bin logs cache backups doctor-logs rescue worktrees plugins; do
    [ -d "$HOME/.ai-safety/$_d" ] && chmod 700 "$HOME/.ai-safety/$_d" 2>/dev/null || true
  done
  # 鍵・トークンの平文ファイルは 600 に落とす（存在するものだけ）。
  for _f in "$HOME/.ai-safety/"*api-key*.txt "$HOME/.ai-safety/"*token*.txt "$HOME/.ai-safety/"*.key; do
    [ -f "$_f" ] && chmod 600 "$_f" 2>/dev/null || true
  done
  echo "権限を締めました: $HOME/.ai-safety（フォルダ 700 / 鍵ファイル 600）"
fi

# --- 秘密の自動移行（受講生の操作ゼロ / v1.17.0） ---------------------------
# 旧平文の API キーを OS の金庫（キーチェーン）へ移す。各キーごとに冪等で、
# 「金庫へ書く → 読み戻して一致を検証 → 一致したときだけ平文を削除」の順に進む。
# 一致しなければ平文はそのまま残し、次回もう一度試す。
_secret_migrate="$workspace/.ai-safety/hooks/common/secret-migrate.js"
if [ -f "$_secret_migrate" ] && command -v node >/dev/null 2>&1; then
  echo "登録済みのキーを金庫（キーチェーン）へ移します..."
  node "$_secret_migrate" || true
fi

# --- 作業フォルダを「信頼済み」にする（v1.17.0） ---------------------------
# Claude Code は初回に対話で信頼ダイアログを承認するまで、そのフォルダの
# permissions.allow を丸ごと無視する（実測: 「Ignoring 68 permissions.allow
# entries ... this workspace has not been trusted」）。受講者はボタンから
# 起動するため対話でダイアログを承認する機会が無く、意図した許可設定が効かない
# まま使うことになる。そこで install が ~/.claude.json に承認済みを記録する。
# 対象は「このスクリプトが今セットアップした作業フォルダ」だけで、他のフォルダは触らない。
_claude_json="$HOME/.claude.json"
if command -v node >/dev/null 2>&1; then
  if AI_SAFE_CLAUDE_JSON="$_claude_json" AI_SAFE_WORKSPACE="$workspace" AI_SAFE_BACKUP_DIR="$backup_dir" node -e '
const fs = require("fs");
const path = require("path");
const file = process.env.AI_SAFE_CLAUDE_JSON;
const ws = process.env.AI_SAFE_WORKSPACE;
const backupDir = process.env.AI_SAFE_BACKUP_DIR;
let data = {};
if (fs.existsSync(file)) {
  const raw = fs.readFileSync(file, "utf8");
  try {
    data = JSON.parse(raw);
  } catch (e) {
    // 壊れた設定を上書きして利用者の環境を壊さない。何もせず終了する。
    process.exit(3);
  }
  // 既存ファイルは必ず控えを取ってから触る。
  try { fs.copyFileSync(file, path.join(backupDir, "claude.json")); } catch (e) {}
}
if (!data.projects || typeof data.projects !== "object") data.projects = {};
if (!data.projects[ws] || typeof data.projects[ws] !== "object") data.projects[ws] = {};
if (data.projects[ws].hasTrustDialogAccepted === true) process.exit(1);
data.projects[ws].hasTrustDialogAccepted = true;
const tmp = file + ".ai-safety-tmp";
fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n", { mode: 0o600 });
fs.renameSync(tmp, file);
process.exit(0);
'; then
    echo "作業フォルダを Claude の信頼済みに登録しました（許可設定が最初から有効になります）。"
  else
    _trust_rc=$?
    if [ "$_trust_rc" = "1" ]; then
      : # すでに登録済み。何も言わない。
    elif [ "$_trust_rc" = "3" ]; then
      echo "注意: $_claude_json を読めなかったため、信頼済み登録をスキップしました。"
      echo "      Claude を1回ふつうに起動して、信頼の確認に「はい」と答えてください。"
    else
      echo "注意: 信頼済み登録に失敗しました。Claude を1回ふつうに起動して、"
      echo "      信頼の確認に「はい」と答えてください。"
    fi
  fi
fi

echo "AI Safety package installed."
echo "Workspace: $workspace"
echo "Backups: $backup_dir"
echo "Next: .ai-safety/hooks/macos/doctor.sh"
