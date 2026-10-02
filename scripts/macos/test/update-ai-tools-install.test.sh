#!/bin/bash
# update-ai-tools.sh が「入っていないツールを新しく入れる」ことの実走テスト（v1.19.5）。
# 本物の npm / インストーラーは使わない。偽の npm と curl を PATH の先頭に置き、
# ツールが 1 つも無い仮のホームで 1 回目＝新規インストール、2 回目＝更新（agy は触らない）を確かめる。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../update-ai-tools.sh"
fail=0
pass() { echo "PASS $1"; }
ng() { echo "FAIL $1"; fail=1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/uat.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/stub" "$T/npmbin"

# 偽 npm: install -g <pkg> を受けたら、対応するコマンドを npmbin に作る（2 回目は版を上げる）
cat > "$T/stub/npm" <<'EOF'
#!/bin/bash
[ "$1" = "install" ] && [ "$2" = "-g" ] || exit 0
case "$3" in
  @openai/codex@*) name=codex ;;
  @anthropic-ai/claude-code@*) name=claude ;;
  opencode-ai@*) name=opencode ;;
  *) echo "unknown package $3" >&2; exit 1 ;;
esac
echo "$3" >> "$NPM_LOG"
f="$NPM_BIN/$name"
if [ -f "$f" ]; then ver="2.0.0"; else ver="1.0.0"; fi
printf '#!/bin/bash\necho "%s %s"\n' "$name" "$ver" > "$f"
chmod +x "$f"
EOF
# 偽 curl: -o <file> に「~/.local/bin/agy を作る」インストーラーを書く。取得先 URL を記録する
cat > "$T/stub/curl" <<'EOF'
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "$url" >> "$CURL_LOG"
cat > "$out" <<'INST'
#!/bin/bash
mkdir -p "$HOME/.local/bin"
printf '#!/bin/bash\necho "agy 0.9.0"\n' > "$HOME/.local/bin/agy"
chmod +x "$HOME/.local/bin/agy"
INST
EOF
chmod +x "$T/stub/npm" "$T/stub/curl"

run() {
  env -i HOME="$T/home" PATH="$T/stub:$T/npmbin:/usr/bin:/bin" TMPDIR="$T" \
    NPM_BIN="$T/npmbin" NPM_LOG="$T/npm.log" CURL_LOG="$T/curl.log" AI_SAFE_NO_PROMPT=1 \
    bash "$SCRIPT" "$T/ws" 2>&1
}

out1="$(run)"
for name in "Codex CLI" "Claude Code" "OpenCode"; do
  echo "$out1" | grep -q "$name: 新しく入れました" && pass "1回目: $name を新しく入れた" || ng "1回目: $name を新しく入れていない"
done
echo "$out1" | grep -q "agy: 新しく入れました" && pass "1回目: agy を公式インストーラーで入れた" || ng "1回目: agy を入れていない"
grep -qx "https://antigravity.google/cli/install.sh" "$T/curl.log" && pass "agy は公式の URL から取得" || ng "agy の取得先が公式でない"
[ "$(wc -l < "$T/npm.log" | tr -d ' ')" = "3" ] && pass "npm は 3 つだけ（agy は npm で入れない）" || ng "npm の呼び出し回数が違う: $(cat "$T/npm.log")"
echo "$out1" | grep -q "入っていないので新しく入れる" && pass "最初に「新しく入れる」と予告する" || ng "予告が無い"

out2="$(run)"
for name in "Codex CLI" "Claude Code" "OpenCode"; do
  echo "$out2" | grep -q "$name: 更新OK (1.0.0 → 2.0.0)" && pass "2回目: $name は更新" || ng "2回目: $name が更新になっていない"
done
echo "$out2" | grep -q "agy: 入っている（更新は公式の自動更新に任せる）" && pass "2回目: agy は触らない" || ng "2回目: agy の扱いが違う"
[ "$(wc -l < "$T/curl.log" | tr -d ' ')" = "1" ] && pass "2回目はインストーラーを取りに行かない" || ng "2回目もインストーラーを取得した"

exit $fail
