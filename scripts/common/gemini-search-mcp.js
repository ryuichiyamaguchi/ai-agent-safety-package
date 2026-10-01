#!/usr/bin/env node
// gemini-search-mcp.js — 依存ゼロの最小 MCP サーバー（stdio）。
//
// 目的:
//   d-claude（DeepSeek 駆動の Claude Code）に web 検索を与える。標準 WebSearch は
//   Anthropic サーバー側実装のため非 Anthropic バックエンドでは動かない。そこで
//   「Gemini の Google 検索 grounding」を 1 個の MCP ツール `web_search` として公開し、
//   DeepSeek がツール呼び出しで検索結果（要約＋出典 URL）を受け取れるようにする。
//
// 設計方針:
//   - 依存ゼロ（本パッケージの ds-gateway / command-judge / gemini-client と同じ純 Node）。
//   - キーは既存の安全パッケージ Gemini キーを使い回す（gemini-client.resolveApiKey）。
//     受講者は新しいアカウントを作らなくてよい（コーチ用キーをそのまま利用）。
//   - 検索モデルは gemini-2.5-flash-lite 既定、予備 gemini-2.5-flash（AI_SAFE_SEARCH_MODEL /
//     AI_SAFE_SEARCH_FALLBACK で上書き可）。無料枠で Google 検索 grounding が返るのは 2.5 系だけ
//     （2026-10-02 実測: 3.1-flash-lite / 3.5-flash-lite / 3.5〜3.8-flash はすべて 429）。
//     2.5-flash は 1 日の無料枠が小さく昼過ぎに 429 になるため、軽い 2.5-flash-lite を先に使う。
//     ※ Google は 2.5 系を「以前から使っていた利用者だけ」に制限しているため、新しく作った
//       キーでは検索が使えない可能性がある（未検証）。その場合も他の機能には影響しない。
//   - 混雑（5xx / UNAVAILABLE）・通信エラー・時間切れのときは、同じモデルで 1 回だけ待って
//     やり直し、だめなら予備へ。上限切れ（429）・未提供（404）・権限（403）はすぐ予備へ。
//     2026-10-02 の教室で UNAVAILABLE が数分続き、旧版（やり直しなし）は検索に失敗した。
//   - 検索のみ。任意 URL の取得やシェル実行はしない。クエリは Google に送られる
//     （AI コーチと同じ信頼境界）。機微情報を含むクエリは投げない前提。
//   - どんな失敗も例外で落とさず、MCP のエラー応答として返す（接続を維持する）。
//
// MCP stdio 転送: JSON-RPC 2.0 メッセージを「改行区切り」で送受信する（1 行 1 メッセージ、
// 埋め込み改行なし）。stdout はプロトコル専用。ログは stderr のみ。
'use strict';

const https = require('https');
let resolveApiKey, GEMINI_HOST;
try {
  ({ resolveApiKey, GEMINI_HOST } = require('./gemini-client.js'));
} catch (_e) {
  // gemini-client が隣に無い場合のフォールバック。順序は本体と同じ
  // 「環境変数 → OS の金庫 → 旧平文」に揃える（独自順序を持たせない）。
  GEMINI_HOST = 'generativelanguage.googleapis.com';
  const store = require('./secret-store.js');
  resolveApiKey = function () { return store.resolve('gemini').value; };
}

const SERVER_NAME = 'gemini-search';
const SERVER_VERSION = '1.0.0';
const DEFAULT_PROTOCOL = '2025-06-18';
const SEARCH_MODEL = process.env.AI_SAFE_SEARCH_MODEL || 'gemini-2.5-flash-lite';
const SEARCH_FALLBACKS = String(process.env.AI_SAFE_SEARCH_FALLBACK || 'gemini-2.5-flash')
  .split(',').map((m) => m.trim()).filter(Boolean);
const RETRY_DELAY_MS = Number(process.env.AI_SAFE_SEARCH_RETRY_DELAY || 3000);
const REQUEST_TIMEOUT_MS = Number(process.env.AI_SAFE_SEARCH_TIMEOUT || 30000);
const MAX_QUERY_CHARS = 800;

// ---- Gemini grounding 呼び出し ---------------------------------------------
// 成功: { ok:true, text, sources:[{title,uri}], queries:[...] }
// 失敗: { ok:false, message }（429/キー無し/ネットワーク等は全部ここに寄せる）
function groundedSearchOnce(query, model) {
  return new Promise((resolve) => {
    const key = resolveApiKey();
    if (!key) {
      return resolve({ ok: false, kind: 'nokey', message: 'Gemini API キーが未設定です（「キーと金庫/3_AIコーチのキーを登録」で登録してください）。' });
    }
    const body = JSON.stringify({
      contents: [{ role: 'user', parts: [{ text: String(query).slice(0, MAX_QUERY_CHARS) }] }],
      tools: [{ google_search: {} }],
    });
    const req = https.request({
      hostname: GEMINI_HOST,
      path: '/v1beta/models/' + encodeURIComponent(model) + ':generateContent',
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': key, 'content-length': Buffer.byteLength(body) },
      timeout: REQUEST_TIMEOUT_MS,
    }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        let json = null; try { json = JSON.parse(data); } catch { /* below */ }
        if (!json) return resolve({ ok: false, kind: res.statusCode >= 500 ? 'busy' : 'other', message: 'Gemini 応答を解釈できませんでした（HTTP ' + res.statusCode + '）。' });
        if (json.error) {
          const st = json.error.status || ('HTTP ' + res.statusCode);
          let msg = 'Gemini 検索に失敗しました（' + st + '）。';
          let kind = 'other';
          if (st === 'RESOURCE_EXHAUSTED' || res.statusCode === 429) {
            kind = 'quota';
            msg = 'Gemini 検索の無料クォータを超過しました（RESOURCE_EXHAUSTED）。しばらく時間をおいて再試行してください。';
          } else if (res.statusCode === 404 || res.statusCode === 403 || st === 'NOT_FOUND' || st === 'PERMISSION_DENIED') {
            kind = 'model';
          } else if (res.statusCode >= 500 || st === 'UNAVAILABLE' || st === 'INTERNAL' || st === 'DEADLINE_EXCEEDED') {
            kind = 'busy';
          }
          return resolve({ ok: false, kind, message: msg });
        }
        const cand = (json.candidates && json.candidates[0]) || {};
        const text = ((cand.content && cand.content.parts) || []).map((p) => p.text || '').join('').trim();
        const gm = cand.groundingMetadata || {};
        const sources = (gm.groundingChunks || [])
          .map((c) => c && c.web ? { title: c.web.title || '', uri: c.web.uri || '' } : null)
          .filter((s) => s && s.uri);
        resolve({ ok: true, text, sources, queries: gm.webSearchQueries || [] });
      });
    });
    req.on('error', (e) => resolve({ ok: false, kind: 'busy', message: 'ネットワークエラー: ' + e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ ok: false, kind: 'busy', message: 'Gemini 検索がタイムアウトしました。' }); });
    req.write(body);
    req.end();
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 既定モデル → 予備の順に試す。混雑・通信・時間切れは同じモデルで 1 回だけ待ってやり直す。
// once は差し替え可能（テスト用）。
async function groundedSearch(query, { once = groundedSearchOnce, delayMs = RETRY_DELAY_MS } = {}) {
  const chain = [SEARCH_MODEL, ...SEARCH_FALLBACKS.filter((m) => m !== SEARCH_MODEL)];
  let r = null;
  let quota = false;
  for (const model of chain) {
    r = await once(query, model);
    if (!r.ok && r.kind === 'busy') {
      await sleep(delayMs);
      r = await once(query, model);
    }
    if (r.ok || r.kind === 'nokey' || r.kind === 'other') break;
    if (r.kind === 'quota') quota = true;
  }
  if (!r.ok && quota && r.kind !== 'quota') {
    r = { ok: false, kind: 'quota', message: 'Gemini 検索の無料クォータを超過しました（RESOURCE_EXHAUSTED）。しばらく時間をおいて再試行してください。' };
  } else if (!r.ok && r.kind === 'busy') {
    r = { ok: false, kind: 'busy', message: r.message + '（やり直しと予備のモデルでも応答がありませんでした。Google 側の混雑の可能性があります。少し待って再試行してください）' };
  }
  return r;
}

// 検索結果をモデルが読みやすい 1 つのテキストに整形する。
function formatResult(query, r) {
  if (!r.ok) return { text: r.message, isError: true };
  const lines = [];
  lines.push(r.text || '(要約なし)');
  if (r.sources && r.sources.length) {
    lines.push('', '出典:');
    r.sources.forEach((s, i) => lines.push((i + 1) + '. ' + (s.title ? s.title + ' — ' : '') + s.uri));
  } else {
    lines.push('', '(このクエリでは Google 検索の出典が取得できませんでした。回答はモデル知識の可能性があります。)');
  }
  return { text: lines.join('\n'), isError: false };
}

// ---- MCP (JSON-RPC 2.0 over stdio, newline-delimited) ----------------------
const TOOL = {
  name: 'web_search',
  description: 'Google 検索（Gemini grounding）で最新の web 情報を調べ、要約と出典 URL を返す。'
    + '最新ニュース・製品情報・事実確認など、モデルの知識だけでは古い/不確実な事柄に使う。',
  inputSchema: {
    type: 'object',
    properties: {
      query: { type: 'string', description: '検索したい内容（自然文の質問でよい）。' },
    },
    required: ['query'],
  },
};

function send(msg) {
  try { process.stdout.write(JSON.stringify(msg) + '\n'); } catch (_e) { /* stdout closed */ }
}
function ok(id, result) { send({ jsonrpc: '2.0', id, result }); }
function err(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }); }

async function handle(msg) {
  if (!msg || msg.jsonrpc !== '2.0') return;
  const { id, method, params } = msg;
  const isNotification = (id === undefined || id === null);

  switch (method) {
    case 'initialize': {
      const proto = (params && params.protocolVersion) || DEFAULT_PROTOCOL;
      return ok(id, {
        protocolVersion: proto,
        capabilities: { tools: {} },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      });
    }
    case 'notifications/initialized':
    case 'initialized':
      return; // 通知（応答不要）
    case 'ping':
      return ok(id, {});
    case 'tools/list':
      return ok(id, { tools: [TOOL] });
    case 'tools/call': {
      const name = params && params.name;
      const args = (params && params.arguments) || {};
      if (name !== 'web_search') {
        if (!isNotification) err(id, -32602, 'Unknown tool: ' + name);
        return;
      }
      const query = typeof args.query === 'string' ? args.query.trim() : '';
      if (!query) {
        return ok(id, { content: [{ type: 'text', text: 'query が空です。検索語を指定してください。' }], isError: true });
      }
      const r = await groundedSearch(query);
      const out = formatResult(query, r);
      return ok(id, { content: [{ type: 'text', text: out.text }], isError: out.isError });
    }
    default:
      if (!isNotification) err(id, -32601, 'Method not found: ' + method);
      return;
  }
}

function main() {
  let buf = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line) continue;
      let msg = null;
      try { msg = JSON.parse(line); } catch { continue; } // 壊れた行は無視（接続維持）
      // handle は async。1 メッセージずつ順に処理（並列でも可だが順序保持で単純化）。
      Promise.resolve().then(() => handle(msg)).catch((e) => {
        if (msg && msg.id != null) err(msg.id, -32603, 'Internal error: ' + (e && e.message));
      });
    }
  });
  process.stdin.on('end', () => process.exit(0));
  process.stderr.write('[gemini-search-mcp] ready (model=' + SEARCH_MODEL + ')\n');
}

if (require.main === module) main();

module.exports = { groundedSearch, groundedSearchOnce, formatResult, handle, TOOL, SEARCH_MODEL, SEARCH_FALLBACKS };
