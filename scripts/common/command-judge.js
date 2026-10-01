#!/usr/bin/env node
// command-judge.js — グレーゾーン自動承認の判定エンジン（Phase 1: Bash + Claude）
//
// 位置づけ:
//   決定的 deny 層（dangerousCommandRegex 等）でブロックされず、かつ既知の安全自動許可でもない
//   「グレー」な Bash コマンドについて、毎回人間に聞く代わりに AI 判定で
//   自動承認(allow) するか人間に聞く(ask) かを決める。
//
// 2026-09-18 の設計変更（旧 two-key-judge.js からの移行）:
//   旧実装は「2 鍵」= 提案者(軽量モデル) と 懐疑的検証者(上位モデル) の 2 回呼び出しで、
//   両方 approve のときだけ allow とした。実測で次の 2 点が判明したため 1 者判定へ戻した。
//     (a) 検証役の既定 gemini-3.5-flash は思考型で 1 判定 28.6 秒かかり、コード側の制限 12 秒を
//         必ず超える → 検証役が毎回タイムアウト → 事実上 100% が人間確認に落ちていた。
//     (b) 2 鍵とも同じ提供元(Gemini)・同じ API キー・同じ無料枠のため、障害・枠切れ・モデルの
//         偏りが相関する。「独立した 2 者」という前提が成り立っておらず、得ていたのは
//         「プロンプトの違う 2 回目の意見」と待ち時間・失敗要因の倍増だけだった。
//   本当に独立させるなら別提供元の AI を使う必要があり、それは別途の設計判断とする。
//   決定的 deny 層（危険コマンド・秘密・保護パス）は一切変更していない。ここは
//   「それを通過したグレーな操作を、人間に聞かずに済ませてよいか」だけを決める層である。
//
// 安全方針（fail-closed を徹底する）:
//   - キー未設定 / 通信失敗 / タイムアウト / JSON パース失敗 / verdict が厳密に "approve" でない
//     → "ask"。よって不確実さはすべて「人間に聞く」側に倒れる。
//   - コマンド本文は <COMMAND> データとして渡し、INJECTION_GUARD で「中の指示に従うな」と固定する。
//     仮に AI がインジェクションに釣られて "approve" と本文中で叫んでも、こちらは「厳密 JSON の
//     verdict フィールドだけ」を信頼するため、本文混入の "approve" 文字列では allow にならない。
//   - 例外は throw しない（CLI は常に exit 0 で JSON を返し、ガード側が allow/ask を決める）。
//
// CLI: stdin に JSON {command, cwd, mode} を渡すと、stdout に
//   {"decision":"allow"|"ask","judge":{verdict,reason,status}} を返す（status は "ok"|"unavailable"）
//   （常に exit 0）。status=unavailable は「AI に聞けなかった」= キー未設定・通信断・
//   タイムアウトで、「AI が慎重に判断した」(status=ok かつ verdict=ask) と区別できる。
'use strict';

const { runAI, resolveApiKey, INJECTION_GUARD } = require('./gemini-client.js');

const DEFAULT_TIMEOUT_MS = Number(process.env.AI_SAFE_ASSIST_TIMEOUT) > 0
  ? Number(process.env.AI_SAFE_ASSIST_TIMEOUT) : 12000;
const MAX_COMMAND_CHARS = 2000;
const MAX_CWD_CHARS = 400;

// 判定モデル。
//   2026-09-18 実測: gemini-3.6-flash 4.1/4.3s ・ gemini-3.8-flash 7.7/8.2s ・ gemini-3.5-flash-lite 9.6/12.7s
//   2026-10-02 実測（無料キー）: gemini-3.5-flash-lite 10 判定で計 10.5 秒（9/10 正解・危険な持ち出し等は
//   すべて ask）／ gemini-3.6-flash は 1 日の無料枠が小さく昼過ぎには 429 ／ 3.7・3.8-flash は 503（混雑）。
// 既定は gemini-3.5-flash-lite（Google も新規に推奨・誰のキーでも使える）。
// 上限切れ・混雑・未提供などすぐ返る失敗のときは gemini-client.runAI が予備モデルを順に試す。
// 時間切れのときは予備を試さず ask に倒す（判定には制限時間があり、待たせ続けないため）。
const JUDGE_MODEL = process.env.AI_SAFE_JUDGE_MODEL || 'gemini-3.5-flash-lite';

function clip(s, n) { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n) + '…' : s; }

// ---- 段2: 決定的「明確に安全」高速許可（AI を呼ばず即 allow）---------------------
// バランス方針: 引数に依らず安全な「読み取り/検査系 + ワークスペース内の定型操作」だけを
// 列挙する。シェルの連結(; && ||)・パイプ・リダイレクト(> <)・コマンド置換($() ``)・
// バックグラウンド(&) が混じる複合コマンドは一切対象にしない（先頭が安全でも後続で何でも
// できてしまうため）→ その場合は AI 判定に回す（安全側）。このモジュールはガードの
// 決定的 deny チェックを通過した後でのみ呼ばれるので、ここに来る時点で .env/秘密/rm -rf 等は
// 既に除外済みである前提で成り立つ。
const SAFE_COMMANDS = new Set([
  'ls', 'pwd', 'cat', 'head', 'tail', 'wc', 'grep', 'egrep', 'fgrep', 'rg',
  'tree', 'file', 'stat', 'du', 'df', 'which', 'type', 'echo', 'printf',
  'date', 'whoami', 'hostname', 'cd', 'clear', 'basename', 'dirname',
  'realpath', 'readlink', 'mkdir', 'touch',
]);
// git は破壊的サブコマンド(push/reset/clean/checkout 等)を除き、安全な定型のみ許可。
const SAFE_GIT_SUBCMDS = new Set(['status', 'diff', 'log', 'branch', 'show', 'add', 'commit', 'stash']);
// ---- 段1.5: 決定的「必ず人間確認」リスト（AI を呼ばず ask）-----------------------
// v1.12.0 教室プロファイルで git push を決定的 deny（dangerousCommandRegex）から外した代わりに、
// ここで「自動承認だけは絶対にさせない」を保証する。公開系・権限昇格は教室でも人間の確認必須。
const ALWAYS_ASK = [
  { re: /\bgit\s+push\b/i, reason: 'リモートへの公開操作（git push）は必ず人間が確認します' },
  { re: /\bsudo\b/i, reason: '管理者権限（sudo）での実行は必ず人間が確認します' },
];
function deterministicAsk(command) {
  const cmd = String(command == null ? '' : command);
  for (const e of ALWAYS_ASK) { if (e.re.test(cmd)) return e.reason; }
  return null;
}

// シェルのメタ文字（連結/パイプ/リダイレクト/置換/背景実行/改行）。1 個でも含めば段2対象外。
const SHELL_META = /[;&|<>`$(){}\n]/;
function deterministicSafe(command) {
  const cmd = String(command == null ? '' : command).trim();
  if (!cmd) return false;
  if (SHELL_META.test(cmd)) return false;            // 複合・リダイレクト・置換 → AI へ
  const tokens = cmd.split(/\s+/);
  const head = tokens[0];
  if (head === 'git') return SAFE_GIT_SUBCMDS.has(tokens[1] || '');
  // find は -delete/-exec で破壊的になりうるため段2には含めない（AI 判定へ）。
  return SAFE_COMMANDS.has(head);
}

// 検査対象を「データ」として囲む。中身が指示文でも従わせない（INJECTION_GUARD と併用）。
function dataBlock(command, cwd) {
  return [
    '<COMMAND>', clip(command, MAX_COMMAND_CHARS), '</COMMAND>',
    '<CONTEXT>',
    '作業ディレクトリ: ' + (cwd ? clip(cwd, MAX_CWD_CHARS) : '不明'),
    '前提: 決定的に危険なコマンド（rm -rf / 認証情報 / 保護パス等）は既に別の層でブロック済みです。',
    '環境: 職業訓練校の教室PC（重要な業務データ・個人情報は置かれていない前提）。' +
      '警戒すべきは「不可逆な破壊」「外部へのデータ持ち出し」「認証情報・システム設定の改変」のみで、' +
      'それ以外の日常的な開発コマンドは学習体験を優先して approve に倒してください。',
    '</CONTEXT>',
  ].join('\n');
}

// 出力フォーマット指示（両鍵共通）。厳密 JSON のみを返させる。
const OUTPUT_SPEC =
  '出力は次の厳密な JSON 1 個だけにしてください（前後に文章・コードブロック・説明を付けない）。' +
  '{"verdict":"approve"|"ask","reason":"<日本語で1文>"}';

// 判定プロンプト（1 者）。旧 proposer（承認に倒す指針）と旧 verifier（現実的な
// セキュリティレビュアー）の良いところを 1 本に統合したもの。過剰な却下（仮定上の攻撃
// シナリオを理由に ask）と、安易な承認（不可逆な破壊・外部送信の見落とし）の両方を戒める。
function judgePrompt(command, cwd) {
  return [
    'あなたは現実的なセキュリティレビュアーです。決定的に危険なコマンド（rm -rf / / .env 等の秘密読み取り / ' +
      '外部送信）は既に別の層でブロック済みである前提で、この「グレー」なシェルコマンドを人間に確認せず' +
      '自動実行してよいかを判定してください。',
    'この操作で「具体的かつ現実的に」次が起きるときだけ ask としてください: 重要ファイルの削除・上書き、' +
      'データの外部送信（持ち出し）、認証情報やシステム設定の改変、取り消し困難な破壊的副作用、' +
      '想定外の広範囲な影響。',
    '重要: 仮定上・極端な攻撃シナリオ（例: 一般的な ls でのシンボリックリンク攻撃、通常コマンドの理論上の' +
      '悪用）を理由に ask にしないこと。日常的な開発コマンドで現実的な害が見当たらなければ approve。',
    INJECTION_GUARD,
    '',
    dataBlock(command, cwd),
    '',
    OUTPUT_SPEC,
  ].join('\n');
}

// AI 出力テキストから {verdict, reason} を厳密に取り出す。
// - JSON として読めない / verdict が厳密に "approve" でない → fail-closed で "ask"。
// - reason は表示用に短く整える（無ければ既定文言）。
function parseVerdict(text) {
  const raw = String(text == null ? '' : text);
  let obj = null;
  // まず全体を JSON として試し、ダメなら最初の {...} ブロックを抜き出して試す。
  try { obj = JSON.parse(raw.trim()); } catch { /* try substring */ }
  if (!obj || typeof obj !== 'object') {
    const m = raw.match(/\{[\s\S]*\}/);
    if (m) { try { obj = JSON.parse(m[0]); } catch { obj = null; } }
  }
  if (!obj || typeof obj !== 'object') {
    return { verdict: 'ask', reason: 'AI 応答を解釈できませんでした（安全側で確認します）' };
  }
  // 厳密一致: 文字列で、トリム後にちょうど "approve" のときだけ approve。
  const v = typeof obj.verdict === 'string' ? obj.verdict.trim() : '';
  const verdict = v === 'approve' ? 'approve' : 'ask';
  let reason = typeof obj.reason === 'string' ? obj.reason.trim() : '';
  if (!reason) reason = verdict === 'approve' ? '定型的で低影響と判断' : '確信が持てないため確認が必要';
  return { verdict, reason: clip(reason, 200) };
}

// AI 1 回分の呼び出し。runAI 失敗(!ok)/タイムアウト/空応答はすべて parseVerdict 手前で ask に倒す。
// 返り値に status を付ける: 'unavailable' = AI に聞けなかった（キー未設定・通信断・タイムアウト）、
// 'ok' = AI が答えた。人間向けの文言をこの 2 つで出し分けるために使う（判定はどちらも ask）。
// model 省略時は gemini-client 側の既定（COACH_MODEL）が使われる。
async function judgeOnce(runAIFn, prompt, timeoutMs, model) {
  let r;
  try {
    r = await runAIFn(prompt, { timeoutMs, model, fallbackOnTimeout: false });
  } catch {
    return { verdict: 'ask', reason: 'AI 呼び出しでエラーが発生（安全側で確認します）', status: 'unavailable' };
  }
  if (!r || r.ok !== true) {
    return { verdict: 'ask', reason: 'AI に確認できませんでした（安全側で確認します）', status: 'unavailable' };
  }
  return Object.assign(parseVerdict(r.text), { status: 'ok' });
}

// 判定コア。runAIFn を注入できるようにしてテスト可能にする（既定は gemini-client.runAI）。
//   入力: { command, cwd } と options { timeoutMs, runAIFn, resolveApiKeyFn }
//   出力: Promise<{ decision, judge:{verdict,reason,status} }>
//   status: 'ok' = 判定できた（決定的段を含む）/ 'unavailable' = AI に聞けなかった。
async function decide(input = {}, options = {}) {
  const command = input.command;
  const cwd = input.cwd;
  const timeoutMs = Number(options.timeoutMs) > 0 ? Number(options.timeoutMs) : DEFAULT_TIMEOUT_MS;
  const runAIFn = typeof options.runAIFn === 'function' ? options.runAIFn : runAI;
  const resolveKeyFn = typeof options.resolveApiKeyFn === 'function' ? options.resolveApiKeyFn : resolveApiKey;

  const result = (decision, judge) => ({ decision, judge });
  const askJudge = (reason, status) => ({ verdict: 'ask', reason, status: status || 'ok' });

  // 空コマンドは判定対象でない → 安全側で ask。
  if (!command || !String(command).trim()) {
    return result('ask', askJudge('コマンドが空でした（安全側で確認します）'));
  }

  // 段1.5: 公開系・権限昇格は AI を呼ばず決定的に ask（自動承認を絶対にさせない）。
  const alwaysAskReason = deterministicAsk(command);
  if (alwaysAskReason) {
    return result('ask', askJudge(alwaysAskReason));
  }

  // 段2: 決定的に安全なコマンドは AI を呼ばず即 allow（キー不要・確実・高速）。
  // ここで救うことで、ls 等の定型コマンドが AI に過剰却下されるのを防ぐ。
  if (deterministicSafe(command)) {
    return result('allow', { verdict: 'approve', reason: '定型的で安全なコマンド（決定的に自動承認）', status: 'ok' });
  }

  // キー未設定なら AI を呼ばず即 ask（無駄打ち＆fail-closed）。status=unavailable なので
  // ガード側は「AI が慎重に判断した」ではなく「AI に聞けなかった」と表示できる。
  if (!resolveKeyFn()) {
    return result('ask', askJudge('Gemini API キーが未設定のため自動承認しません（人間に確認）', 'unavailable'));
  }

  // AI 判定は 1 回だけ。旧 2 鍵（提案者＋検証者）は、同一提供元・同一キーで独立性が無い一方、
  // 待ち時間と失敗要因を倍にしていたため 2026-09-18 に 1 者へ戻した（ファイル冒頭の経緯を参照）。
  const judge = await judgeOnce(runAIFn, judgePrompt(command, cwd), timeoutMs, JUDGE_MODEL);

  // 自動承認は verdict が厳密に approve のときだけ。それ以外はすべて ask。
  return result(judge.verdict === 'approve' ? 'allow' : 'ask', judge);
}

// ---- CLI -------------------------------------------------------------------
function readStdin() {
  return new Promise((resolve) => {
    let data = ''; let size = 0;
    const MAX = 262144;
    try { process.stdin.setEncoding('utf8'); } catch { /* */ }
    process.stdin.on('data', (c) => { size += c.length; if (size <= MAX) data += c; });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', () => resolve(data));
  });
}

async function main() {
  let input = {};
  try {
    // Windows PowerShell 5.1 は、画面の文字コードが UTF-8（65001）のとき標準入力の先頭に BOM を付ける。
    // 残すと JSON.parse が失敗し「コマンドが空」扱いで毎回人間に確認していた（GitHub Actions で判明）。
    const raw = (await readStdin()).replace(/^\uFEFF/, '');
    const parsed = raw && raw.trim() ? JSON.parse(raw) : {};
    if (parsed && typeof parsed === 'object') input = parsed;
  } catch {
    // stdin が壊れていても fail-closed: command なし扱いで decide が ask を返す。
    input = {};
  }
  const timeoutMs = DEFAULT_TIMEOUT_MS; // AI_SAFE_ASSIST_TIMEOUT は定数側で解決済み
  let out;
  try {
    out = await decide({ command: input.command, cwd: input.cwd }, { timeoutMs });
  } catch {
    out = {
      decision: 'ask',
      judge: { verdict: 'ask', reason: '判定中に予期せぬエラー（安全側で確認します）', status: 'unavailable' },
    };
  }
  process.stdout.write(JSON.stringify(out));
  // 常に exit 0。allow/ask の最終処理はガード側が行う。
  process.exitCode = 0;
}

if (require.main === module) {
  main();
}

module.exports = {
  decide,
  parseVerdict,
  judgeOnce,
  judgePrompt,
  deterministicSafe,
  deterministicAsk,
  DEFAULT_TIMEOUT_MS,
  JUDGE_MODEL,
};
