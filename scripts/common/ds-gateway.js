// DeepSeek 送信検査 Gateway（loopback 専用・依存ゼロ）
'use strict';
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { URL } = require('node:url');
const { maskText } = require('./secret-patterns.js');
const { createTokenMap } = require('./token-map.js');
const { loadDenylist } = require('./denylist.js');

const DEFAULT_PORT = Number(process.env.DS_GATEWAY_PORT || 8788);
const DEFAULT_UPSTREAM = process.env.DS_GATEWAY_UPSTREAM || 'https://api.deepseek.com/anthropic';
const DEFAULT_MAX_BODY = Number(process.env.DS_GATEWAY_MAX_BODY || 10 * 1024 * 1024); // 10MB（M2: ReDoS/メモリ枯渇の上限）

function createGateway({ upstream = DEFAULT_UPSTREAM, port = DEFAULT_PORT,
                        tokenMap = createTokenMap(), denylistTerms = loadDenylist(),
                        maxBody = DEFAULT_MAX_BODY } = {}) {
  const upstreamUrl = new URL(upstream);
  const session = { tokenMap, denylistTerms, maxBody };
  const server = http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/healthz') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{"status":"ok"}');
      return;
    }
    handleProxy(req, res, upstreamUrl, session).catch(() => {
      if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json' });
      if (!res.writableEnded) res.end('{"error":"ds-gateway: internal error (fail-closed)"}');
    });
  });
  // ポート bind 失敗（EADDRINUSE 等）は致命的に扱い即終了。
  // launcher 側は「spawn した node が health 後も生存している」ことで自プロセスの占有を確認する。
  server.on('error', (e) => {
    console.error(`ds-gateway: listen failed: ${e && e.message ? e.message : e}`);
    process.exit(1);
  });
  return {
    listen() {
      return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve(server)));
    },
  };
}

function readBody(req, max) {
  return new Promise((resolve, reject) => {
    const chunks = []; let len = 0; let over = false;
    req.on('data', (c) => {
      if (over) return; // already over the cap: keep draining, drop the data
      len += c.length;
      if (max && len > max) {
        // M2: over the cap. Stop buffering and reject, but do NOT destroy the socket here
        // — the caller still needs a live connection to send a 413 response (fail-closed).
        over = true;
        const e = new Error('request body too large'); e.code = 'BODY_TOO_LARGE';
        reject(e);
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => { if (!over) resolve(Buffer.concat(chunks)); });
    req.on('error', reject);
  });
}

function addCounts(acc, c) {
  for (const k of Object.keys(c)) acc[k] = (acc[k] || 0) + c[k];
}

function maskValue(v, counts, ctx) {
  // Generic deep-walk: mask EVERY string leaf in any string/array/object.
  // This uniformly covers text, tool_result.content, tool_use.input, and any future fields.
  if (typeof v === 'string') {
    const r = maskText(v, { alloc: ctx.alloc, denylistTerms: ctx.denylistTerms });
    addCounts(counts, r.counts);
    return r.masked;
  }
  if (Array.isArray(v)) {
    return v.map((item) => maskValue(item, counts, ctx));
  }
  if (v && typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v)) out[k] = maskValue(v[k], counts, ctx);
    return out;
  }
  return v; // numbers, booleans, null
}

function maskRequestBody(json, ctx) {
  const counts = {};
  // v1: only messages/system are scanned (Anthropic Messages API shape). Audit this when adding endpoints whose payloads carry user text in other fields.
  if (!json || (json.messages === undefined && json.system === undefined)) {
    return { json, counts, changed: false };
  }
  if (json.system !== undefined) json.system = maskValue(json.system, counts, ctx);
  if (Array.isArray(json.messages)) {
    json.messages = json.messages.map((m) =>
      (m && m.content !== undefined) ? { ...m, content: maskValue(m.content, counts, ctx) } : m);
  }
  return { json, counts, changed: true };
}

function logDetection(reqUrl, counts) {
  if (!counts || !counts.total) return;
  try {
    const dir = process.env.AI_SAFE_LOG_DIR || path.join(os.homedir(), '.ai-safety', 'logs');
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const file = path.join(dir, 'secret-scan-events.jsonl');
    const ev = {
      ts: new Date().toISOString(),
      user: os.userInfo().username || 'unknown',
      mode: 'mask',
      source: 'ds-gateway',
      path: String(reqUrl || '').split('?')[0],
      total: counts.total || 0,
      counts: {
        openai: counts.openai||0, anthropic: counts.anthropic||0, google: counts.google||0,
        aws: counts.aws||0, github: counts.github||0, slack: counts.slack||0,
        jwt: counts.jwt||0, private_key: counts.private_key||0, generic: counts.generic||0,
        email: counts.email||0, phone: counts.phone||0, postal: counts.postal||0,
        credit_card: counts.credit_card||0, mynumber: counts.mynumber||0, denylist: counts.denylist||0,
      },
    };
    fs.appendFileSync(file, JSON.stringify(ev) + '\n', { mode: 0o600 });
  } catch (_) { /* ログ失敗で送信は止めない */ }
}

async function handleProxy(req, res, upstreamUrl, session) {
  let raw;
  try {
    raw = await readBody(req, session.maxBody);
  } catch (e) {
    if (e && e.code === 'BODY_TOO_LARGE') {
      req.resume(); // drain the rest of the oversized body so the socket can finish cleanly
      if (!res.headersSent) res.writeHead(413, { 'content-type': 'application/json' });
      if (!res.writableEnded) res.end('{"error":"ds-gateway: request body too large; not forwarded (fail-closed)"}');
      return;
    }
    throw e;
  }
  const ct = (req.headers['content-type'] || '').toLowerCase();
  let outBody = raw;
  // RED-A: このリクエストで採番したトークンのみを記録。復元はこの集合に限定し横断 PII 漏えいを封鎖。
  const allocated = new Set();

  // v1: POST bodies must be application/json so we can inspect them.
  // A non-empty POST with a non-JSON content-type is NOT inspectable → fail-closed (415).
  if (req.method === 'POST' && raw.length) {
    if (!ct.includes('application/json')) {
      res.writeHead(415, { 'content-type': 'application/json' });
      res.end('{"error":"ds-gateway: non-JSON POST body not inspectable; not forwarded (fail-closed)"}');
      return;
    }
    let parsed;
    try {
      parsed = JSON.parse(raw.toString('utf8'));
    } catch (e) {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end('{"error":"ds-gateway: unparseable JSON; not forwarded (fail-closed)"}');
      return;
    }
    const alloc = (v, c) => { const t = session.tokenMap.alloc(v, c); allocated.add(t); return t; };
    const ctx = { alloc, denylistTerms: session.denylistTerms };
    const { json, counts, changed } = maskRequestBody(parsed, ctx);
    if (changed) {
      outBody = Buffer.from(JSON.stringify(json), 'utf8');
      logDetection(req.url.split('?')[0], counts);
    }
  }

  forward(req, res, upstreamUrl, outBody, session, allocated);
}

function jsonEscape(s) { const j = JSON.stringify(String(s)); return j.slice(1, -1); }

function makeRestorer(tokenMap, allowed) {
  const TOKEN_RE = /〔R\d+〕/g;
  const OPEN = '〔';
  let carry = '';
  const restore = (s) => s.replace(TOKEN_RE, (t) => {
    if (allowed && !allowed.has(t)) return t; // RED-A: 当該リクエスト採番外のトークンは復元しない
    const orig = tokenMap.getOriginal(t);
    return orig === undefined ? t : jsonEscape(orig);
  });
  return {
    push(chunkStr) {
      let s = carry + chunkStr;
      const lastOpen = s.lastIndexOf(OPEN);
      let safeLen = s.length;
      if (lastOpen !== -1 && s.indexOf('〕', lastOpen) === -1 && (s.length - lastOpen) < 20) safeLen = lastOpen;
      carry = s.slice(safeLen);
      return restore(s.slice(0, safeLen));
    },
    flush() { const out = restore(carry); carry = ''; return out; },
  };
}

function forward(req, res, upstreamUrl, body, session, allocated) {
  const isHttps = upstreamUrl.protocol === 'https:';
  const lib = isHttps ? https : http;
  const headers = { ...req.headers };
  headers.host = upstreamUrl.host;
  headers['content-length'] = Buffer.byteLength(body);
  delete headers['accept-encoding'];
  const HOP_BY_HOP = ['connection','keep-alive','proxy-authenticate','proxy-authorization','te','trailer','transfer-encoding','upgrade'];
  for (const h of HOP_BY_HOP) delete headers[h];
  const basePath = upstreamUrl.pathname.replace(/\/$/, '');
  const reqPath = basePath + req.url;

  const upReq = lib.request(
    { protocol: upstreamUrl.protocol, host: upstreamUrl.hostname, port: upstreamUrl.port || (isHttps ? 443 : 80), method: req.method, path: reqPath, headers },
    (upRes) => {
      const ct = (upRes.headers['content-type'] || '').toLowerCase();
      const transform = (ct.includes('json') || ct.includes('event-stream')) && allocated && allocated.size > 0;
      if (!transform) {
        res.writeHead(upRes.statusCode, upRes.headers);
        upRes.on('error', () => { if (!res.writableEnded) res.end(); });
        upRes.pipe(res);
        return;
      }
      // RED-B: 復元でバイト長が変わるため content-length を外し chunked にする。
      const outHeaders = { ...upRes.headers };
      delete outHeaders['content-length'];
      res.writeHead(upRes.statusCode, outHeaders);
      const restorer = makeRestorer(session.tokenMap, allocated);
      upRes.setEncoding('utf8');
      upRes.on('data', (chunk) => res.write(restorer.push(chunk)));
      upRes.on('end', () => { res.write(restorer.flush()); res.end(); });
      upRes.on('error', () => { if (!res.writableEnded) res.end(); });
    });
  upReq.on('error', () => {
    if (!res.headersSent) { res.writeHead(502, {'content-type':'application/json'}); res.end('{"error":"ds-gateway: upstream unreachable (fail-closed)"}'); }
    else if (!res.writableEnded) res.end();
  });
  upReq.end(body);
}

module.exports = { createGateway, DEFAULT_PORT, DEFAULT_UPSTREAM };

if (require.main === module) {
  createGateway().listen().then((s) => {
    console.log(`listening on 127.0.0.1:${s.address().port}`);
  });
}
