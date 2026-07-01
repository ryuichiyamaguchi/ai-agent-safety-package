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
//   - 依存ゼロ（本パッケージの ds-gateway / two-key-judge / gemini-client と同じ純 Node）。
//   - キーは既存の安全パッケージ Gemini キーを使い回す（gemini-client.resolveApiKey）。
//     受講者は新しいアカウントを作らなくてよい（コーチ用キーをそのまま利用）。
//   - 検索モデルは gemini-2.5-flash 固定（無料枠で Google 検索 grounding が実際に返る
//     ことを実測で確認済みのモデル。3.x flash 系は無料の grounding 枠がほぼ無く 429）。
//     AI_SAFE_SEARCH_MODEL で上書き可。
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
  // gemini-client が隣に無い場合のフォールバック（キーは env / 既定ファイルから解決）。
  const fs = require('fs'), os = require('os'), path = require('path');
  GEMINI_HOST = 'generativelanguage.googleapis.com';
  resolveApiKey = function () {
    if (process.env.GEMINI_API_KEY) return process.env.GEMINI_API_KEY;
    if (process.env.GOOGLE_API_KEY) return process.env.GOOGLE_API_KEY;
    try { return fs.readFileSync(path.join(os.homedir(), '.ai-safety', 'gemini-api-key.txt'), 'utf8').trim(); } catch { return null; }
  };
}

const SERVER_NAME = 'gemini-search';
const SERVER_VERSION = '1.0.0';
const DEFAULT_PROTOCOL = '2025-06-18';
const SEARCH_MODEL = process.env.AI_SAFE_SEARCH_MODEL || 'gemini-2.5-flash';
const REQUEST_TIMEOUT_MS = Number(process.env.AI_SAFE_SEARCH_TIMEOUT || 30000);
const MAX_QUERY_CHARS = 800;

// ---- Gemini grounding 呼び出し ---------------------------------------------
// 成功: { ok:true, text, sources:[{title,uri}], queries:[...] }
// 失敗: { ok:false, message }（429/キー無し/ネットワーク等は全部ここに寄せる）
function groundedSearch(query) {
  return new Promise((resolve) => {
    const key = resolveApiKey();
    if (!key) {
      return resolve({ ok: false, message: 'Gemini API キーが未設定です（~/.ai-safety/gemini-api-key.txt）。' });
    }
    const body = JSON.stringify({
      contents: [{ role: 'user', parts: [{ text: String(query).slice(0, MAX_QUERY_CHARS) }] }],
      tools: [{ google_search: {} }],
    });
    const req = https.request({
      hostname: GEMINI_HOST,
      path: '/v1beta/models/' + encodeURIComponent(SEARCH_MODEL) + ':generateContent',
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': key, 'content-length': Buffer.byteLength(body) },
      timeout: REQUEST_TIMEOUT_MS,
    }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        let json = null; try { json = JSON.parse(data); } catch { /* below */ }
        if (!json) return resolve({ ok: false, message: 'Gemini 応答を解釈できませんでした（HTTP ' + res.statusCode + '）。' });
        if (json.error) {
          const st = json.error.status || ('HTTP ' + res.statusCode);
          let msg = 'Gemini 検索に失敗しました（' + st + '）。';
          if (st === 'RESOURCE_EXHAUSTED' || res.statusCode === 429) {
            msg = 'Gemini 検索の無料クォータを超過しました（RESOURCE_EXHAUSTED）。しばらく時間をおいて再試行してください。';
          }
          return resolve({ ok: false, message: msg });
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
    req.on('error', (e) => resolve({ ok: false, message: 'ネットワークエラー: ' + e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ ok: false, message: 'Gemini 検索がタイムアウトしました。' }); });
    req.write(body);
    req.end();
  });
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

module.exports = { groundedSearch, formatResult, handle, TOOL };
