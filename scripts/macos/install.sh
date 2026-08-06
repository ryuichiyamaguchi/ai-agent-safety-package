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

# Bouncer最大保護モード用のローカルGateway。標準モードでは起動しないため、
# ローカルLLMを動かせないPCでもCodex/Claude/OpenCodeの標準モードを利用できる。
if [ -d "$package_root/bouncer-gateway" ]; then
  bouncer_dest="$workspace/.ai-safety/bouncer"
  if [ -e "$bouncer_dest" ]; then
    safe_name="$(printf '%s' "$bouncer_dest" | sed 's#[/:]#_#g')"
    cp -R "$bouncer_dest" "$backup_dir/$safe_name"
    rm -rf "$bouncer_dest"
  fi
  cp -R "$package_root/bouncer-gateway" "$bouncer_dest"
  chmod +x "$bouncer_dest/scripts/"*.zsh 2>/dev/null || true
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
  cp -R "$package_root/workspace-template/スタート/." "$workspace/スタート/"
  if [ -f "$package_root/スタート.html" ]; then
    cp "$package_root/スタート.html" "$workspace/スタート/スタート.html"
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
  for _q in "$workspace/.ai-safety" "$workspace/スタート"; do
    [ -e "$_q" ] || continue
    xattr -dr com.apple.quarantine "$_q" 2>/dev/null || true
  done
fi

echo "AI Safety package installed."
echo "Workspace: $workspace"
echo "Backups: $backup_dir"
echo "Next: .ai-safety/hooks/macos/doctor.sh"
