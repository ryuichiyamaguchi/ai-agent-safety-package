#!/usr/bin/env bash
# guard-prompt.sh — UserPromptSubmit ガード（発話は寛容・実行は guard-bash が守る）
#
# 方針: プロンプトは「発話」であって「実行」ではない。危険なコマンドの実際の実行は
# PreToolUse の guard-bash が捕捉する。よってここでは危険コマンド regex(dangerousCommandRegex)
# も保護パス regex(protectedPathRegex) もプロンプトに適用しない。受講者が学ぶために
# 「rm -r って何？」「cat .env で中身を見たい」「password=mytestpass123 と例に書いた」
# と質問することを封じないためである（教える対象を聞くことすら止めるのは製品目的の真逆）。
#
# 唯一のブロック条件: 本物の API キー書式（outputSecretRegex = Generic sensitive assignment
# を除いた実キーのみ = OpenAI/Anthropic/Google/AWS/GitHub/Slack/JWT/秘密鍵ブロック）を
# AI に送ろうとした場合だけ。Generic な代入（password=... 等）は通す。
#
# 可視化(now.html カード)は fail-safe。explain は内部で `{...} 2>/dev/null || true; return 0`
# のため、どんな例外でも発話を止めない。
set -u
AI_SAFE_MODE="prompt"
. "$(dirname "$0")/lib/safety_policy.sh"
read_hook_input
. "$(dirname "$0")/lib/explainer.sh"

# 本物のキー検出時のブロック。英語生 stderr でなく日本語で理由＋次の一手＋コーチ誘導を出す。
block_prompt_secret() {
  audit_log "block" "sensitive API key format in user input (narrow)"
  {
    printf '【AI 安全ガード】入力に本物の API キーらしき文字列が含まれています。\n'
    printf 'API キーやアクセストークンは AI に送らないでください（会話履歴やログに残る恐れがあります）。\n'
    printf '次の一手: キー本体を伏せて（例: sk-xxxx… や「自分の APIキー」と書く）質問し直してください。\n'
    printf '使い方が分からないときは、モニター画面の AI コーチに「APIキーの扱い方」と聞いてください。\n'
  } >&2
  exit 2
}

# 唯一の deny 条件: 本物の API キー書式（narrow = outputSecretRegex）。
# guard-post-output と同じ has_sensitive_output_text を再利用する（Generic 代入は対象外）。
# ★可視化(explain)より先に検査する。本物キーを含む入力は now.html カードにも残さないため、
#   キー検出時は explain を呼ばず即ブロックする（explain が生プロンプトを now.html に書く前に止める）。
if has_sensitive_output_text; then
  block_prompt_secret
fi

# 可視化カードを書く（失敗しても発話は止めない）。本物キーが無いと確認できた後にだけ書く。
explain

allow "prompt passed policy (narrow secret check only)"
