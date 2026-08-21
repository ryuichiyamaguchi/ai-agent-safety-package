#!/usr/bin/env bash
# bash32-empty-array.test.sh — bash 3.2 の「空配列展開 = unbound variable」回帰テスト
#
# ■ なぜこのテストがあるのか（実機で起きた事故）
#   macOS 標準の /bin/bash は 3.2.57 で固定されている（GPLv3 のため Apple が更新しない）。
#   この 3.2 系には、bash 4.4 以降では起きない固有の罠がある:
#
#       set -u
#       arr=()
#       echo "${arr[@]}"      # → bash 3.2: "arr[@]: unbound variable" で即死
#                             #   bash 4.4+: 何も起きない（空に展開される）
#
#   要素ゼロの配列を "${arr[@]}" / ${arr[@]} / "${arr[*]}" のいずれで展開しても落ちる。
#   開発機の bash（Homebrew の 5.x など）では絶対に再現しないので、レビューをすり抜ける。
#
#   実際に v1.14.1 で受講者の Mac が踏んだ:
#     apply-global-guard.sh:121: STATE_ARGS[@]: unbound variable
#     （AI_SAFE_GLOBAL_STATE 未設定 → STATE_ARGS=() のまま "${STATE_ARGS[@]}" を展開）
#   「（上級）5_このPC全体に最低限の安全設定を入れる」を押した全 Mac 利用者が踏む事故だった。
#
# ■ 安全な書き方
#       ${arr[@]+"${arr[@]}"}      # 空配列でも落ちず、要素があれば正しく個別クォートされる
#
# ■ このテストがやること
#   1. /bin/bash（= 3.2）でこの罠が実在することを実測で確認する（環境の前提チェック）
#   2. 安全な書き方が空配列でも通ることを実測で確認する
#   3. scripts/ と workspace-template/ の全 .sh / .command を静的スキャンし、
#      「安全形になっていない配列展開」を検出する。空にならないと監査済みのものだけ
#      SAFE_AUDITED 許可リストに置く。新しい配列が増えたら、監査するまでこのテストが落ちる。
#
# 実行: /bin/bash scripts/macos/test/bash32-empty-array.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT

# ------------------------------------------------------------------
# 1) 環境の前提: /bin/bash で空配列の "${arr[@]}" が本当に落ちること
#    （落ちなくなったら bash が更新されたということ。テストの前提が変わるので知らせる）
# ------------------------------------------------------------------
cat > "$TD/trap.sh" <<'EOF'
set -u
arr=()
echo "${arr[@]}"
EOF
if /bin/bash "$TD/trap.sh" >/dev/null 2>"$TD/trap.err"; then
  ng "bash-3.2-trap-exists: /bin/bash で空配列の \"\${arr[@]}\" が落ちなかった（$(/bin/bash --version | head -n1)）"
elif grep -q 'unbound variable' "$TD/trap.err"; then
  ok "bash-3.2-trap-exists: 空配列の \"\${arr[@]}\" は unbound variable で落ちる（想定どおり）"
else
  ng "bash-3.2-trap-exists: 想定外のエラー: $(cat "$TD/trap.err")"
fi

# ------------------------------------------------------------------
# 2) 安全形 ${arr[@]+"${arr[@]}"} は空でも要素ありでも正しく動くこと
# ------------------------------------------------------------------
cat > "$TD/safe.sh" <<'EOF'
set -u
join() { j=""; for _x in "$@"; do j="$j[$_x]"; done; printf '%s' "$j"; }
empty=()
printf 'empty:%s\n' "$(join ${empty[@]+"${empty[@]}"})"
filled=(--a "b c" --d)
printf 'filled:%s\n' "$(join ${filled[@]+"${filled[@]}"})"
EOF
if out="$(/bin/bash "$TD/safe.sh" 2>&1)"; then
  if [ "$(printf '%s\n' "$out" | grep -c '^empty:$')" -eq 1 ] \
     && [ "$(printf '%s\n' "$out" | grep -cF 'filled:[--a][b c][--d]')" -eq 1 ]; then
    ok "safe-form-works: \${arr[@]+\"\${arr[@]}\"} は空でも通り、要素は個別クォートを保つ"
  else
    ng "safe-form-works: 展開結果が想定と違う: $out"
  fi
else
  ng "safe-form-works: 安全形が落ちた: $out"
fi

# ------------------------------------------------------------------
# 3) 静的スキャン: 安全形になっていない配列展開を全部拾う
#
#    SAFE_AUDITED = 「その配列は空になり得ない」と 1 件ずつ人間が確認したもの。
#    形式は <リポジトリ相対パス>:<配列名>。根拠を必ずコメントに残すこと。
#    ここに無い配列展開が見つかったらテストは落ちる。安全形に直すか、
#    空にならない根拠を書いてこのリストに足すか、どちらかを必ず行うこと。
# ------------------------------------------------------------------
SAFE_AUDITED="
scripts/release-version-check.sh:ACTIVE_FILES
scripts/macos/launch-agy-safe.sh:cmd
scripts/macos/launch-claude-safe.sh:_args
scripts/macos/launch-claude-safe.sh:claude_args
scripts/macos/launch-codex-safe.sh:cmd
scripts/macos/launch-longrun.sh:claude_args
scripts/macos/opencode/launch-opencode-deepseek.sh:_user_plugin_files
scripts/macos/opencode/launch-opencode-deepseek.sh:CONFIG_ARGS
scripts/macos/野良d-claudeを退治.command:ROGUE_FILES
"
#   根拠（監査日 2026-08-21）:
#     ACTIVE_FILES        … リテラル配列。宣言時点で 17 要素固定、空になる経路が無い
#     launch-agy-safe:cmd … cmd=("$AGY" --sandbox --add-dir "$workspace" ...) で常に 4 要素以上
#     _args               … 使用箇所が [ "${#_args[@]}" -gt 0 ] の中だけ
#     claude_args (両方)  … claude_args=(--settings ... --setting-sources ...) で常に 3 要素以上
#     launch-codex-safe:cmd … cmd=(codex --cd ... ) で常に 9 要素以上
#     _user_plugin_files  … 使用箇所が [ "${#_user_plugin_files[@]}" -gt 0 ] の中だけ
#     CONFIG_ARGS         … CONFIG_ARGS=(--port ... --monitor-plugin ...) で常に 4 要素
#     ROGUE_FILES         … 使用箇所は要素数チェック済みの分岐内（0 件なら手前で exit）

is_audited() {
  # $1 = "path:array"
  printf '%s\n' "$SAFE_AUDITED" | grep -qxF "$1"
}

scan_fail=0
scan_seen=0
while IFS= read -r file; do
  rel="${file#"$REPO"/}"
  # このテスト自身は「危険な書き方」を実例として持っているのでスキャン対象外
  [ "$rel" = "scripts/macos/test/bash32-empty-array.test.sh" ] && continue
  # コメント行を落としてから、安全形 ${x[@]+"${x[@]}"} を消し、残った生展開を拾う
  raw="$(sed -e 's/^[[:space:]]*#.*$//' "$file" \
    | sed -e 's/\${[A-Za-z_][A-Za-z0-9_]*\[@\]+"\${[A-Za-z_][A-Za-z0-9_]*\[@\]}"}//g' \
    | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]' \
    | sed -e 's/^\${//' -e 's/\[[@*]\]$//' \
    | sort -u)"
  [ -n "$raw" ] || continue
  while IFS= read -r arrname; do
    [ -n "$arrname" ] || continue
    scan_seen=$((scan_seen + 1))
    if ! is_audited "$rel:$arrname"; then
      scan_fail=$((scan_fail + 1))
      printf '  [危険の疑い] %s: 配列 %s が生の "${%s[@]}" 形で展開されています\n' "$rel" "$arrname" "$arrname"
      printf '               空になり得るなら ${%s[@]+"${%s[@]}"} に直してください（bash 3.2 対策）。\n' "$arrname" "$arrname"
      printf '               空になり得ないなら、根拠を添えて SAFE_AUDITED に追加してください。\n'
    fi
  done <<EOF
$raw
EOF
done <<EOF
$(find "$REPO/scripts" "$REPO/workspace-template" -type f \( -name '*.sh' -o -name '*.command' \) | sort)
EOF

if [ "$scan_fail" -eq 0 ]; then
  ok "no-unguarded-array-expansion: 生の配列展開 $scan_seen 件はすべて監査済み（空にならない）"
else
  ng "no-unguarded-array-expansion: 未監査の生の配列展開が $scan_fail 件あります"
fi

# ------------------------------------------------------------------
# 4) 実機で落ちた 2 本を、空配列の条件で実際に動かす（構文だけでなく実行で確認）
# ------------------------------------------------------------------
SBX="$TD/sbx"
mkdir -p "$SBX/home"

# 判定は「unbound variable が出ないこと」に限定する。終了コードは環境（node の有無、
# 既存設定の状態など）で変わりうるし、このテストの関心事ではない。
if command -v node >/dev/null 2>&1; then
  # AI_SAFE_GLOBAL_STATE 未設定 → STATE_ARGS=() のまま 4 エンジン分を展開する経路
  env -u AI_SAFE_GLOBAL_STATE \
      HOME="$SBX/home" \
      AI_SAFE_DENY_SRC="$REPO/configs/claude/settings.mac.json" \
      AI_SAFE_GLOBAL_CLAUDE="$SBX/claude-settings.json" \
      AI_SAFE_GLOBAL_CODEX="$SBX/codex-config.toml" \
      AI_SAFE_GLOBAL_CODEX_HOOKS="$SBX/codex-hooks.json" \
      AI_SAFE_GLOBAL_AGY="$SBX/gemini-settings.json" \
      AI_SAFE_GLOBAL_OPENCODE_DIR="$SBX/opencode" \
      /bin/bash "$REPO/scripts/macos/apply-global-guard.sh" --dry-run >"$TD/apply.out" 2>&1
  if grep -q 'unbound variable' "$TD/apply.out"; then
    ng "apply-global-guard-empty-state: $(grep -m1 'unbound variable' "$TD/apply.out")"
  elif grep -q '4) OpenCode' "$TD/apply.out"; then
    ok "apply-global-guard-empty-state: STATE_ARGS が空でも 4 エンジン分すべて通る"
  else
    ng "apply-global-guard-empty-state: 4 エンジン分に到達しなかった: $(tail -n3 "$TD/apply.out")"
  fi

  env -u AI_SAFE_GLOBAL_STATE HOME="$SBX/home" \
      /bin/bash "$REPO/scripts/macos/uninstall-global-guard.sh" --dry-run >"$TD/uninstall.out" 2>&1
  if grep -q 'unbound variable' "$TD/uninstall.out"; then
    ng "uninstall-global-guard-empty-state: $(grep -m1 'unbound variable' "$TD/uninstall.out")"
  elif grep -q '4) OpenCode' "$TD/uninstall.out"; then
    ok "uninstall-global-guard-empty-state: STATE_ARGS が空でも 4 エンジン分すべて通る"
  else
    ng "uninstall-global-guard-empty-state: 4 エンジン分に到達しなかった: $(tail -n3 "$TD/uninstall.out")"
  fi
else
  printf 'SKIP apply/uninstall-global-guard-empty-state（node が無い）\n'
fi

# 引数なしで呼ぶのが既定の使い方（safe-paste）→ ARGS=() になる経路
mkdir -p "$SBX/bin"
printf '#!/bin/sh\nprintf %%s "dummy text"\n' > "$SBX/bin/pbpaste"
printf '#!/bin/sh\ncat > /dev/null\n' > "$SBX/bin/pbcopy"
chmod +x "$SBX/bin/pbpaste" "$SBX/bin/pbcopy"
env HOME="$SBX/home" PATH="$SBX/bin:$PATH" AI_SAFE_LOG_DIR="$SBX/home/logs" \
  /bin/bash "$REPO/scripts/macos/clipboard-safe-paste.sh" >"$TD/clip.out" 2>&1
if grep -q 'unbound variable' "$TD/clip.out"; then
  ng "clipboard-safe-paste-no-args: $(grep -m1 'unbound variable' "$TD/clip.out")"
else
  ok "clipboard-safe-paste-no-args: 引数なし（ARGS が空）でも unbound variable にならない"
fi

printf '\n----\nPASS: %s / FAIL: %s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  printf 'ALL PASS\n'
  exit 0
fi
exit 1
