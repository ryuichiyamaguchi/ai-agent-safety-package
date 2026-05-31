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
    handleProxy(req, res, upstreamUrl);
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
  if (typeof v === 'string') {
    const r = maskSecrets(v);
    addCounts(counts, r.counts);
    return r.masked;
  }
  if (Array.isArray(v)) {
    return v.map((block) => {
      if (block && typeof block === 'object' && typeof block.text === 'string') {
        const r = maskSecrets(block.text);
        addCounts(counts, r.counts);
        return { ...block, text: r.masked };
      }
      return block;
    });
  }
  return v;
}

function maskRequestBody(json) {
  const counts = {};
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
      path: reqUrl,
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

  if (req.method === 'POST' && ct.includes('application/json') && raw.length) {
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
      logDetection(req.url, counts);
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

  const basePath = upstreamUrl.pathname.replace(/\/$/, '');
  const path = basePath + req.url;

  const upReq = lib.request(
    { protocol: upstreamUrl.protocol, host: upstreamUrl.hostname,
      port: upstreamUrl.port || (isHttps ? 443 : 80), method: req.method, path, headers },
    (upRes) => {
      res.writeHead(upRes.statusCode, upRes.headers);
      upRes.pipe(res);
    });
  upReq.on('error', (e) => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'application/json' });
    res.end('{"error":"ds-gateway: upstream unreachable (fail-closed)"}');
  });
  upReq.end(body);
}

module.exports = { createGateway, DEFAULT_PORT, DEFAULT_UPSTREAM };

if (require.main === module) {
  createGateway().listen().then((s) => {
    console.log(`listening on 127.0.0.1:${s.address().port}`);
  });
}
