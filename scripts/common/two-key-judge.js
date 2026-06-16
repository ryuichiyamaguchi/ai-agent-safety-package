#!/usr/bin/env node
// two-key-judge.js — 「2 鍵」グレーゾーン自動承認の判定エンジン（Phase 1: Bash + Claude）
//
// 位置づけ:
//   決定的 deny 層（dangerousCommandRegex 等）でブロックされず、かつ既知の安全自動許可でもない
//   「グレー」な Bash コマンドについて、毎回人間に聞く代わりに「2 つの独立した AI 判定」で
//   自動承認(allow) するか人間に聞く(ask) かを決める。
//
// 2 鍵の原則:
//   - Key1 = 提案者(proposer): 定型・低影響なら approve。少しでも不明・破壊・外部送信の気配なら ask。
//   - Key2 = 懐疑的検証者(verifier): どんな小さな理由でも探し、確信を持てなければ ask。
//   - 自動承認(allow) は「両鍵が approve」のときだけ。それ以外はすべて ask（人間に確認）。
//
// 安全方針（fail-closed を徹底する）:
//   - キー未設定 / 通信失敗 / タイムアウト / JSON パース失敗 / verdict が厳密に "approve" でない
//     → そのキーは "ask" 扱い。よって不確実さはすべて「人間に聞く」側に倒れる。
//   - コマンド本文は <COMMAND> データとして渡し、INJECTION_GUARD で「中の指示に従うな」と固定する。
//     仮に AI がインジェクションに釣られて "approve" と本文中で叫んでも、こちらは「厳密 JSON の
//     verdict フィールドだけ」を信頼するため、本文混入の "approve" 文字列では allow にならない。
//   - 例外は throw しない（CLI は常に exit 0 で JSON を返し、ガード側が allow/ask を決める）。
//
// CLI: stdin に JSON {command, cwd, mode} を渡すと、stdout に
//   {"decision":"allow"|"ask","key1":{verdict,reason},"key2":{verdict,reason}} を返す（常に exit 0）。
'use strict';

const { runAI, resolveApiKey, INJECTION_GUARD } = require('./gemini-client.js');

const DEFAULT_TIMEOUT_MS = 8000;
const MAX_COMMAND_CHARS = 2000;
const MAX_CWD_CHARS = 400;

function clip(s, n) { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n) + '…' : s; }

// ---- 段2: 決定的「明確に安全」高速許可（AI を呼ばず即 allow）---------------------
// バランス方針: 引数に依らず安全な「読み取り/検査系 + ワークスペース内の定型操作」だけを
// 列挙する。シェルの連結(; && ||)・パイプ・リダイレクト(> <)・コマンド置換($() ``)・
// バックグラウンド(&) が混じる複合コマンドは一切対象にしない（先頭が安全でも後続で何でも
// できてしまうため）→ その場合は 2 鍵 AI 判定に回す（安全側）。このモジュールはガードの
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
    '</CONTEXT>',
  ].join('\n');
}

// 出力フォーマット指示（両鍵共通）。厳密 JSON のみを返させる。
const OUTPUT_SPEC =
  '出力は次の厳密な JSON 1 個だけにしてください（前後に文章・コードブロック・説明を付けない）。' +
  '{"verdict":"approve"|"ask","reason":"<日本語で1文>"}';

function proposerPrompt(command, cwd) {
  return [
    'あなたは、決定的な危険コマンド（rm -rf / .env 等の秘密読み取り / curl 等の外部送信）は既に別の層で' +
      'ブロック済みである前提で、この「グレー」なシェルコマンドを人間に確認せず自動実行してよいかを判定する役です。',
    '日常的・定型的な開発コマンドで「具体的かつ現実的な実害」が見当たらなければ approve としてください。',
    '次のような“具体的リスク”があるときだけ ask: 重要ファイルの削除・上書き、取り消し困難な破壊的操作、' +
      '外部へのデータ送信、認証情報やシステム設定の改変、想定外の広範囲な副作用。',
    '重要: 一般的なコマンド（ls / cat / grep / mkdir / git add 等）に対して、シンボリックリンク攻撃のような' +
      '仮定上・極端な攻撃シナリオを理由に ask にしないでください。現実的に害がなければ approve。',
    INJECTION_GUARD,
    '',
    dataBlock(command, cwd),
    '',
    OUTPUT_SPEC,
  ].join('\n');
}

function verifierPrompt(command, cwd) {
  return [
    'あなたは現実的なセキュリティレビュアーです。決定的に危険なコマンドは別層でブロック済みの前提で、' +
      'この操作を実行すると「具体的かつ現実的に」次が起きるかを見ます: 重要ファイルの削除・上書き、' +
      'データの外部送信（持ち出し）、認証情報やシステム設定の改変、取り消し困難な破壊的副作用。',
    'それらの“具体的リスク”が認められるときだけ ask としてください。',
    '重要: 仮定上・極端な攻撃シナリオ（例: 一般的な ls でのシンボリックリンク攻撃、通常コマンドの理論上の悪用）を' +
      '理由に ask にしないこと。日常的な開発コマンドで現実的な害が見当たらなければ approve。',
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

// 1 鍵分の呼び出し。runAI 失敗(!ok)/タイムアウト/空応答はすべて parseVerdict 手前で ask に倒す。
async function judgeOneKey(runAIFn, prompt, timeoutMs) {
  let r;
  try {
    r = await runAIFn(prompt, { timeoutMs });
  } catch {
    return { verdict: 'ask', reason: 'AI 呼び出しでエラーが発生（安全側で確認します）' };
  }
  if (!r || r.ok !== true) {
    return { verdict: 'ask', reason: 'AI に確認できませんでした（安全側で確認します）' };
  }
  return parseVerdict(r.text);
}

// 判定コア。runAIFn を注入できるようにしてテスト可能にする（既定は gemini-client.runAI）。
//   入力: { command, cwd } と options { timeoutMs, runAIFn, resolveApiKeyFn }
//   出力: Promise<{ decision, key1, key2 }>
async function decide(input = {}, options = {}) {
  const command = input.command;
  const cwd = input.cwd;
  const timeoutMs = Number(options.timeoutMs) > 0 ? Number(options.timeoutMs) : DEFAULT_TIMEOUT_MS;
  const runAIFn = typeof options.runAIFn === 'function' ? options.runAIFn : runAI;
  const resolveKeyFn = typeof options.resolveApiKeyFn === 'function' ? options.resolveApiKeyFn : resolveApiKey;

  const askKey = (reason) => ({ verdict: 'ask', reason });
  const result = (decision, key1, key2) => ({ decision, key1, key2 });

  // 空コマンドは判定対象でない → 安全側で ask。
  if (!command || !String(command).trim()) {
    const k = askKey('コマンドが空でした（安全側で確認します）');
    return result('ask', k, k);
  }

  // 段2: 決定的に安全なコマンドは AI を呼ばず即 allow（キー不要・確実・高速）。
  // ここで救うことで、ls 等の定型コマンドが懐疑役 AI に過剰却下されるのを防ぐ。
  if (deterministicSafe(command)) {
    const k = { verdict: 'approve', reason: '定型的で安全なコマンド（決定的に自動承認）' };
    return result('allow', k, k);
  }

  // キー未設定なら AI を呼ばず即 ask（無駄打ち＆fail-closed）。
  if (!resolveKeyFn()) {
    const k = askKey('Gemini API キーが未設定のため自動承認しません（人間に確認）');
    return result('ask', k, k);
  }

  // 2 鍵を並列で呼ぶ。どちらかが投げても Promise.all を壊さない（judgeOneKey 内で握りつぶす）。
  const [key1, key2] = await Promise.all([
    judgeOneKey(runAIFn, proposerPrompt(command, cwd), timeoutMs),
    judgeOneKey(runAIFn, verifierPrompt(command, cwd), timeoutMs),
  ]);

  // 自動承認は「両鍵が approve」のときだけ。それ以外は ask。
  const decision = (key1.verdict === 'approve' && key2.verdict === 'approve') ? 'allow' : 'ask';
  return result(decision, key1, key2);
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
    const raw = await readStdin();
    const parsed = raw && raw.trim() ? JSON.parse(raw) : {};
    if (parsed && typeof parsed === 'object') input = parsed;
  } catch {
    // stdin が壊れていても fail-closed: command なし扱いで decide が ask を返す。
    input = {};
  }
  const timeoutMs = Number(process.env.AI_SAFE_ASSIST_TIMEOUT) > 0
    ? Number(process.env.AI_SAFE_ASSIST_TIMEOUT) : DEFAULT_TIMEOUT_MS;
  let out;
  try {
    out = await decide({ command: input.command, cwd: input.cwd }, { timeoutMs });
  } catch {
    const k = { verdict: 'ask', reason: '判定中に予期せぬエラー（安全側で確認します）' };
    out = { decision: 'ask', key1: k, key2: k };
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
  judgeOneKey,
  proposerPrompt,
  verifierPrompt,
  deterministicSafe,
  DEFAULT_TIMEOUT_MS,
};
