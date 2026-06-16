#!/usr/bin/env bash
set -u
AI_SAFE_MODE="bash"
. "$(dirname "$0")/lib/safety_policy.sh"
read_hook_input
. "$(dirname "$0")/lib/explainer.sh"
explain
has_sensitive_text && block "sensitive pattern in shell command"
has_protected_path && block "protected path referenced in shell command"
has_dangerous_command && block "dangerous shell command matched"

# ---------------------------------------------------------------------------
# ここに来た時点でコマンドは「グレー」（決定的 deny に当たらず・既知の安全自動許可でもない）。
# 既定では従来どおり allow（JSON 無し exit 0 = settings.json の承認フローに委ねる）。
#
# 2 鍵グレーゾーン自動承認（opt-in・既定 OFF）:
#   AI_SAFE_ASSISTED_APPROVAL=1 のときだけ、2 つの独立 AI 判定で allow/ask を決める。
#   - d-claude セッション（coach-engine マーカーが fresh<12h で "d-claude"）はスキップ。
#   - node が無い / 判定が失敗・タイムアウト → ask（fail-closed。決して allow に倒さない）。
#   - 判定ロジックは scripts/common/two-key-judge.js（共有 Node モジュール）に集約。bash は
#     コマンドを渡して結果を Claude の permissionDecision JSON に翻訳するだけ。
# OFF（未設定/0）のときはこのブロックを完全にスキップし、従来の allow にフォールスルーする。
# ---------------------------------------------------------------------------
assisted_approval() {
  # opt-in でなければ何もしない（呼び出し側が従来 allow に進む）。
  [ "${AI_SAFE_ASSISTED_APPROVAL:-0}" = "1" ] || return 1

  # d-claude セッションはスキップ（monitor-server.js の coachRedact と同じ検出）。
  # coach-engine マーカーが存在し、12h より新しく、中身が "d-claude" のとき。
  local ldir marker
  ldir="$(log_dir)"
  marker="$ldir/coach-engine"
  if [ -f "$marker" ]; then
    local mtime now age
    mtime="$(stat -f '%m' "$marker" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age=$(( now - mtime ))
    if [ "$age" -ge 0 ] && [ "$age" -le 43200 ]; then
      if [ "$(cat "$marker" 2>/dev/null | tr -d '[:space:]')" = "d-claude" ]; then
        return 1   # d-claude → assisted approval せず従来 allow へ
      fi
    fi
  fi

  # node が無ければ fail-closed で ask（従来 allow には倒さない＝opt-in 時は安全側）。
  local node_bin
  node_bin="$(command -v node 2>/dev/null || true)"
  [ -n "$node_bin" ] || { assisted_emit_ask "AI 判定に必要な node が見つかりません（安全側で確認します）"; return 0; }

  # 検査対象コマンド（命令ではなくデータ）と cwd を JSON で組み立てて judge に渡す。
  local cmd cwd judge stdout
  cmd="$(_extract_json_field "command")"
  cwd="$(pwd)"
  judge="$(cd "$(dirname "$0")/../common" 2>/dev/null && pwd)/two-key-judge.js"
  if [ ! -r "$judge" ]; then
    assisted_emit_ask "AI 判定スクリプトが見つかりません（安全側で確認します）"
    return 0
  fi

  # 全体タイムアウト: 各鍵 8s × 並列なので余裕をみて 20s。timeout コマンドが無くても動くよう
  # フォールバックする（その場合は node 内のタイムアウトに委ねる）。
  local input
  input="$(assisted_build_input "$cmd" "$cwd")"
  local timeout_bin
  timeout_bin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  if [ -n "$timeout_bin" ]; then
    stdout="$(printf '%s' "$input" | "$timeout_bin" 20 "$node_bin" "$judge" 2>/dev/null || true)"
  else
    stdout="$(printf '%s' "$input" | "$node_bin" "$judge" 2>/dev/null || true)"
  fi

  # 判定結果を解析。decision=allow を厳密に確認できたときだけ allow、それ以外は ask（fail-closed）。
  local decision k1v k1r k2v k2r
  decision="$(assisted_json_field "$stdout" 'decision')"
  k1v="$(assisted_json_nested "$stdout" 'key1' 'verdict')"
  k1r="$(assisted_json_nested "$stdout" 'key1' 'reason')"
  k2v="$(assisted_json_nested "$stdout" 'key2' 'verdict')"
  k2r="$(assisted_json_nested "$stdout" 'key2' 'reason')"

  # 監査ログ（両鍵 + 最終）を残す。reason は redact 済 audit_log を流用。
  audit_log "assist-key1" "key1=$k1v: $k1r"
  audit_log "assist-key2" "key2=$k2v: $k2r"

  if [ "$decision" = "allow" ]; then
    audit_log "assist-allow" "2鍵承認: key1=$k1v / key2=$k2v"
    assisted_now_append "✅ AI2鍵で自動承認" "key1=${k1v} / key2=${k2v}"
    assisted_emit_allow "AI 2 鍵がともに承認（定型・低影響と判断）"
    return 0
  fi

  audit_log "assist-ask" "人間に確認: key1=$k1v / key2=$k2v"
  assisted_now_append "❓ AI判定→人間に確認" "key1=${k1v} / key2=${k2v}"
  assisted_emit_ask "AI 2 鍵のどちらかが確信を持てませんでした（人間に確認します）"
  return 0
}

# {command, cwd, mode} の最小 JSON を組み立てる（json_escape は safety_policy.sh 由来）。
assisted_build_input() {
  local cmd="$1" cwd="$2"
  printf '{"command":"%s","cwd":"%s","mode":"bash"}' "$(json_escape "$cmd")" "$(json_escape "$cwd")"
}

# judge の stdout からトップレベル文字列フィールドを 1 個取り出す（単純・依存なし）。
assisted_json_field() {
  printf '%s' "$1" | sed -nE "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" | head -n 1
}

# key1/key2 のような入れ子オブジェクト内の文字列フィールドを取り出す。
assisted_json_nested() {
  printf '%s' "$1" \
    | sed -nE "s/.*\"$2\"[[:space:]]*:[[:space:]]*\{[^}]*\"$3\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" \
    | head -n 1
}

# Claude PreToolUse hook の permissionDecision JSON を stdout に出して exit 0。
# JSON は exit 0 のときだけ処理される（exit 2 では無視される＝決定的 deny 経路とは別物）。
assisted_emit_allow() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"%s"}}\n' \
    "$(json_escape "$1")"
  exit 0
}
assisted_emit_ask() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
    "$(json_escape "$1")"
  exit 0
}

# now.html へ 1 行サマリを最小追記する（explain が既に書いたカードの直後に差し込む）。
# explainer の正規 writer には手を入れず、</div></body> 直前へ <div> を 1 つ挿入するだけ。
# 失敗してもガードの判定は止めない（best-effort）。
assisted_now_append() {
  local title="$1" detail="$2"
  local dir out tmp esc_title esc_detail
  dir="$(log_dir)"
  out="$dir/now.html"
  [ -f "$out" ] || return 0
  esc_title="$(html_escape "$title" 2>/dev/null || printf '%s' "$title")"
  esc_detail="$(html_escape "$detail" 2>/dev/null || printf '%s' "$detail")"
  tmp="$out.assist.$$"
  # 最後の </body> の直前に 1 行だけ挿入。複数回呼ばれても 1 行ずつ増えるだけで壊れない。
  awk -v line="<div class=\"cmeta\">🔑 ${esc_title} ・ ${esc_detail}</div>" '
    { buf[NR]=$0 }
    END {
      inserted=0
      for (i=1;i<=NR;i++) {
        if (!inserted && buf[i] ~ /<\/body>/) { print line; inserted=1 }
        print buf[i]
      }
      if (!inserted) print line
    }
  ' "$out" > "$tmp" 2>/dev/null && mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  if [ -f "$out" ] && [ -O "$out" ]; then chmod 600 "$out" 2>/dev/null || true; fi
  return 0
}

# グレー確定後: assisted approval が判定を下したら（allow/ask いずれも）そこで exit する。
# OFF / スキップ条件のときだけ下の従来 allow にフォールスルーする。
assisted_approval

allow "command passed policy"
