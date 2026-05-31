// DeepSeek 送信検査 Gateway（loopback 専用・依存ゼロ）
'use strict';
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { URL } = require('node:url');
const { maskSecrets } = require('./secret-patterns.js');

const DEFAULT_PORT = Number(process.env.DS_GATEWAY_PORT || 8788);
const DEFAULT_UPSTREAM = process.env.DS_GATEWAY_UPSTREAM || 'https://api.deepseek.com/anthropic';

function createGateway({ upstream = DEFAULT_UPSTREAM, port = DEFAULT_PORT } = {}) {
  const upstreamUrl = new URL(upstream);
  const server = http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/healthz') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{"status":"ok"}');
      return;
    }
    handleProxy(req, res, upstreamUrl).catch(() => {
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

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function addCounts(acc, c) {
  for (const k of Object.keys(c)) acc[k] = (acc[k] || 0) + c[k];
}

function maskValue(v, counts) {
  // Generic deep-walk: mask EVERY string leaf in any string/array/object.
  // This uniformly covers text, tool_result.content, tool_use.input, and any future fields.
  if (typeof v === 'string') {
    const r = maskSecrets(v);
    addCounts(counts, r.counts);
    return r.masked;
  }
  if (Array.isArray(v)) {
    return v.map((item) => maskValue(item, counts));
  }
  if (v && typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v)) out[k] = maskValue(v[k], counts);
    return out;
  }
  return v; // numbers, booleans, null
}

function maskRequestBody(json) {
  const counts = {};
  // v1: only messages/system are scanned (Anthropic Messages API shape). Audit this when adding endpoints whose payloads carry user text in other fields.
  if (!json || (json.messages === undefined && json.system === undefined)) {
    return { json, counts, changed: false };
  }
  if (json.system !== undefined) json.system = maskValue(json.system, counts);
  if (Array.isArray(json.messages)) {
    json.messages = json.messages.map((m) =>
      (m && m.content !== undefined) ? { ...m, content: maskValue(m.content, counts) } : m);
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
      },
    };
    fs.appendFileSync(file, JSON.stringify(ev) + '\n', { mode: 0o600 });
  } catch (_) { /* ログ失敗で送信は止めない */ }
}

async function handleProxy(req, res, upstreamUrl) {
  const raw = await readBody(req);
  const ct = (req.headers['content-type'] || '').toLowerCase();
  let outBody = raw;

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
    const { json, counts, changed } = maskRequestBody(parsed);
    if (changed) {
      outBody = Buffer.from(JSON.stringify(json), 'utf8');
      logDetection(req.url.split('?')[0], counts);
    }
  }

  forward(req, res, upstreamUrl, outBody);
}

function forward(req, res, upstreamUrl, body) {
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
    { protocol: upstreamUrl.protocol, host: upstreamUrl.hostname,
      port: upstreamUrl.port || (isHttps ? 443 : 80), method: req.method, path: reqPath, headers },
    (upRes) => {
      res.writeHead(upRes.statusCode, upRes.headers);
      upRes.on('error', () => { if (!res.writableEnded) res.end(); });
      upRes.pipe(res);
    });
  upReq.on('error', () => {
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'application/json' });
      res.end('{"error":"ds-gateway: upstream unreachable (fail-closed)"}');
    } else if (!res.writableEnded) {
      res.end();
    }
  });
  upReq.end(body);
}

module.exports = { createGateway, DEFAULT_PORT, DEFAULT_UPSTREAM };

if (require.main === module) {
  createGateway().listen().then((s) => {
    console.log(`listening on 127.0.0.1:${s.address().port}`);
  });
}
