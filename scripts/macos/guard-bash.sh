#!/usr/bin/env bash
set -u
AI_SAFE_MODE="bash"
. "$(dirname "$0")/lib/safety_policy.sh"
read_hook_input
. "$(dirname "$0")/lib/explainer.sh"
explain
# 安全な loopback fetch（自分の localhost 開発サーバへの curl/wget）だけ decisive deny から救う。
# 外部宛て・複合コマンド・proxy/resolve 等のトリックは一切許可せず、従来どおり deny の底に残す。
# 判定は厳格ホワイトリスト:「シェルメタ文字ゼロ + 先頭 curl|wget + 宛先が loopback リテラルのみ」。
# 少しでも形が外れたら return 1 → 下の has_dangerous_command（deny）にフォールスルー（fail-safe）。
is_safe_loopback_fetch() {
  local cmd
  cmd="$(_extract_json_field "command")"
  [ -n "$cmd" ] || return 1
  # 複数行コマンドは対象外。grep は行単位で照合するため、1 行目だけがホワイトリストに
  # 当たる 2 行コマンド（1 行目 curl / 2 行目 rm -rf）を許可してしまうのを防ぐ。
  is_single_line_value "$cmd" || return 1
  # メタ文字・制御文字・クォート・変数展開・バックスラッシュを 1 個でも含めば対象外。
  # これらが無ければ ; や $() / バッククォートによるコマンド連結・注入は成立しない。IPv6 の [] は許可。
  printf '%s' "$cmd" | LC_ALL=C grep -qE '[;&|<>`$(){}"'"'"'\\*?[:cntrl:]]' && return 1
  # proxy/resolve/connect-to/interface 系（宛先すり替え）フラグは明示的に拒否（多重防御）。
  printf '%s' "$cmd" | grep -qiE -- '(--resolve|--connect-to|--proxy|--interface|(^|[[:space:]])-x([[:space:]]|$))' && return 1
  # curl|wget + 単純フラグ列 + (scheme://)? loopbackホスト (:port)? (/path)? を末尾に 1 個だけ。
  printf '%s' "$cmd" | grep -qiE '^(curl|wget)([[:space:]]+-{1,2}[A-Za-z][A-Za-z0-9=._-]*)*[[:space:]]+(https?://)?(localhost|127(\.[0-9]{1,3}){3}|\[::1\]|::1)(:[0-9]{1,5})?(/[^[:space:]]*)?$' || return 1
  return 0
}

is_scoped_generated_cleanup() {
  local cmd
  cmd="$(_extract_json_field "command")"
  [ -n "$cmd" ] || return 1
  # 複数行コマンドは対象外（1 行目だけが当たって ask に格下げされるのを防ぐ）。
  is_single_line_value "$cmd" || return 1
  printf '%s' "$cmd" | LC_ALL=C grep -qE \
    '^rm[[:space:]]+(-[A-Za-z]*r[A-Za-z]*|--recursive)([[:space:]]+(-f|--force))?[[:space:]]+(\./)?(node_modules|build|dist|coverage|target|\.next|\.turbo)([[:space:]]+(\./)?(node_modules|build|dist|coverage|target|\.next|\.turbo))*[[:space:]]*$'
}

has_sensitive_text && block "sensitive pattern in shell command"
has_protected_path && block "protected path referenced in shell command"
# 書き込み先（> >> tee）が設定ファイル等なら止める。読み取りは止めない。
has_redirect_protected_target && block "protected file targeted by output redirect (設定ファイルの書き換え)"
# loopback（localhost/127.0.0.1/::1）宛ての単純 fetch は許可。外部宛ては下の decisive deny に落とす。
if is_safe_loopback_fetch; then
  allow "loopback fetch to localhost permitted"
fi
if is_scoped_generated_cleanup; then
  ask "プロジェクト内の生成物をまとめて削除します。対象を確認できた場合だけ、今回だけ許可してください"
fi
has_dangerous_command && block "dangerous shell command matched"

# ---------------------------------------------------------------------------
# ここに来た時点でコマンドは「グレー」（決定的 deny に当たらず・既知の安全自動許可でもない）。
# 既定では従来どおり allow（JSON 無し exit 0 = settings.json の承認フローに委ねる）。
#
# AI グレーゾーン自動承認（opt-in・既定 OFF）:
#   AI_SAFE_ASSISTED_APPROVAL=1 のときだけ、AI 判定で allow/ask を決める。
#   2026-09-18: 旧「2 鍵」（提案者＋検証者の 2 回呼び出し）は 1 者判定に戻した。検証役の
#   既定モデルが 1 判定 28.6 秒かかり制限 12 秒を必ず超えて毎回タイムアウトしていたこと、
#   2 鍵とも同一提供元・同一キーで独立性が無かったことが理由（command-judge.js 冒頭参照）。
#   - d-claude セッション（coach-engine マーカーが fresh<12h で "d-claude"）はスキップ。
#   - node が無い / 判定が失敗・タイムアウト → ask（fail-closed。決して allow に倒さない）。
#   - 判定ロジックは scripts/common/command-judge.js（共有 Node モジュール）に集約。bash は
#     コマンドを渡して結果を Claude の permissionDecision JSON に翻訳するだけ。
# OFF（未設定/0）のときはこのブロックを完全にスキップし、従来の allow にフォールスルーする。
# ---------------------------------------------------------------------------
assisted_approval() {
  # opt-in でなければ何もしない（呼び出し側が従来 allow に進む）。
  if [ "${AI_SAFE_ASSISTED_APPROVAL:-0}" != "1" ]; then
    # judge が回らない（env≠1）。d-claude 経路（本来 judge ON のはず）では「黙って無効化」を検知できるよう
    # OFF を必ず監査＋now に残す。素の claude-safe/codex-safe（DS_CLAUDE_MODE≠1）では OFF が正常なので残さない。
    # 判定ロジックは変えない（表示のみ・従来 allow にフォールスルー）。
    if [ "${DS_CLAUDE_MODE:-0}" = "1" ]; then
      audit_log "assist-off" "assisted OFF (env≠1): AI judge 無効のまま従来allowへフォールスルー"
      assisted_now_append "⚠️ AI judge OFF" "env≠1 のため判定せず従来allow（d-claude では要確認）"
    fi
    return 1
  fi

  # judge を実施（発火）することを監査に明示。以降 assist-judge と最終 allow/ask も記録される。
  audit_log "assist-on" "AI judge で判定します（AI_SAFE_ASSISTED_APPROVAL=1）"

  # d-claude（DeepSeek 駆動）でも Gemini 判定を有効にする。判定役は DeepSeek ではなく
  # 独立した Gemini（command-judge.js → gemini-client.js）なので「自分のコマンドを自分で
  # 審査する」自己審査問題は起きない。かつ、ここに来る時点で秘密情報・保護パス・決定的
  # 危険コマンドは上流（has_sensitive_text / has_protected_path / has_dangerous_command）で
  # block 済みなので、judge に渡るのはグレーな定型コマンドのみ（秘密は Google に出ない）。
  # 以前はここで d-claude を skip して従来 allow に倒していたが、「AI が危険判定して自律的に
  # 回す」要望によりスキップを廃止。d-claude で無効化したい場合は起動側で
  # AI_SAFE_ASSISTED_APPROVAL_OPTOUT=1 を指定する（launch-deepseek-gateway.sh 参照）。

  # node が無ければ fail-closed で ask（従来 allow には倒さない＝opt-in 時は安全側）。
  local node_bin
  node_bin="$(command -v node 2>/dev/null || true)"
  [ -n "$node_bin" ] || { assisted_emit_ask "AI 判定に必要な node が見つかりません（安全側で確認します）"; return 0; }

  # 検査対象コマンド（命令ではなくデータ）と cwd を JSON で組み立てて judge に渡す。
  local cmd cwd judge stdout
  cmd="$(_extract_json_field "command")"
  cwd="$(pwd)"
  judge="$(cd "$(dirname "$0")/../common" 2>/dev/null && pwd)/command-judge.js"
  if [ ! -r "$judge" ]; then
    assisted_emit_ask "AI 判定スクリプトが見つかりません（安全側で確認します）"
    return 0
  fi

  # 全体タイムアウト: judge 1 回（既定モデルは実測 4 秒台・上限 12s）に余裕をみて 30s。
  # timeout コマンドが無くてもフォールバックする（その場合は node 内のタイムアウトに委ねる）。
  local input
  input="$(assisted_build_input "$cmd" "$cwd")"
  local timeout_bin
  timeout_bin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  if [ -n "$timeout_bin" ]; then
    stdout="$(printf '%s' "$input" | "$timeout_bin" 30 "$node_bin" "$judge" 2>/dev/null || true)"
  else
    stdout="$(printf '%s' "$input" | "$node_bin" "$judge" 2>/dev/null || true)"
  fi

  # 判定結果を解析。decision=allow を厳密に確認できたときだけ allow、それ以外は ask（fail-closed）。
  local decision verdict reason status
  decision="$(assisted_json_field "$stdout" 'decision')"
  verdict="$(assisted_json_nested "$stdout" 'judge' 'verdict')"
  reason="$(assisted_json_nested "$stdout" 'judge' 'reason')"
  status="$(assisted_json_nested "$stdout" 'judge' 'status')"
  # judge が何も返さなかった（異常終了・30 秒の打ち切り・出力が壊れている）ときは status が空になる。
  # これは「AI が慎重に判断した」ではなく「AI に聞けなかった」なので unavailable に倒す。
  # Windows 側（guard-bash.ps1）は $status の初期値が "unavailable" で、同じ扱いになっている。
  if [ -z "$status" ]; then
    status="unavailable"
    [ -n "$reason" ] || reason="判定プログラムが応答しませんでした（異常終了・時間切れ）"
  fi

  # 監査ログ（判定 + 最終）を残す。reason は redact 済 audit_log を流用。
  audit_log "assist-judge" "judge=$verdict ($status): $reason"

  if [ "$decision" = "allow" ]; then
    audit_log "assist-allow" "AI 判定で自動承認: judge=$verdict"
    assisted_now_append "✅ AI判定で自動承認" "judge=${verdict}"
    assisted_emit_allow "AI が承認しました（定型・低影響と判断）"
    return 0
  fi

  # 「AI に聞けなかった」(status=unavailable: キー未設定・通信断・タイムアウト) と
  # 「AI が慎重に判断した」(status=ok) は同じ ask でも原因が違うので文言を分ける。
  # 旧実装は両方を同じ「確信を持てませんでした」で表示していたため、キーや時間切れの
  # 不具合が「AI が慎重なだけ」に見えて発見が遅れた。
  audit_log "assist-ask" "人間に確認: judge=$verdict ($status)"
  if [ "$status" = "unavailable" ]; then
    assisted_now_append "⚠️ AI判定できず→人間に確認" "judge 実行不可（${reason}）"
    assisted_emit_ask "AI 判定を実行できませんでした（AIコーチのキー・通信・時間切れ）。人間に確認します"
  else
    assisted_now_append "❓ AI判定→人間に確認" "judge=${verdict}: ${reason}"
    # 理由をそのまま見せる（「なぜ聞かれたか」が分からないと利用者は判断できない）。
    if [ -n "$reason" ]; then
      assisted_emit_ask "自動承認しませんでした: ${reason}"
    else
      assisted_emit_ask "AI が自動承認してよいと確信できませんでした（人間に確認します）"
    fi
  fi
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

# judge のような入れ子オブジェクト内の文字列フィールドを取り出す。
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
