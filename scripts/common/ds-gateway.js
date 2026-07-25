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
const { loadDenylistResult } = require('./denylist.js');

const DEFAULT_PORT = Number(process.env.DS_GATEWAY_PORT || 8788);
const DEFAULT_UPSTREAM = process.env.DS_GATEWAY_UPSTREAM || 'https://api.deepseek.com/anthropic';
const DEFAULT_AUTH_FILE = process.env.DS_GATEWAY_AUTH_FILE || '';
const DEFAULT_MAX_BODY = Number(process.env.DS_GATEWAY_MAX_BODY || 10 * 1024 * 1024); // 10MB（M2: ReDoS/メモリ枯渇の上限）

function createGateway({ upstream = DEFAULT_UPSTREAM, port = DEFAULT_PORT,
                        tokenMap = createTokenMap(), denylistTerms = loadDenylistResult(),
                        maxBody = DEFAULT_MAX_BODY,
                        upstreamAuthFile = DEFAULT_AUTH_FILE } = {}) {
  const upstreamUrl = new URL(upstream);
  let upstreamAuthorization = '';
  if (upstreamAuthFile) {
    let key;
    try {
      key = fs.readFileSync(upstreamAuthFile, 'utf8').trim();
    } catch (_) {
      throw new Error('ds-gateway: upstream auth file is unreadable (fail-closed)');
    }
    if (!key || /[\r\n]/.test(key)) {
      throw new Error('ds-gateway: upstream auth file is empty or invalid (fail-closed)');
    }
    upstreamAuthorization = `Bearer ${key}`;
  }
  // F-4: denylist が「設定あり×読込失敗」なら fail-closed sentinel が来る。
  // その場合 denylist 語句が漏れ得るため、当該 gateway は全リクエストを転送拒否する。
  const denylistFailClosed = !!(denylistTerms && denylistTerms.failClosed === true);
  const terms = Array.isArray(denylistTerms) ? denylistTerms : [];
  const session = {
    tokenMap,
    denylistTerms: terms,
    denylistFailClosed,
    maxBody,
    upstreamAuthorization,
  };
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

// Anthropic content block の既知バイナリ MIME ホワイトリスト（module 共有）。
// 用途1: 正規 base64 メディアを secret マスク除外する判定（isLegitimateBase64Source）。
// 用途2: 画像 placeholder に echo してよい media_type かの判定（D・RED-1 修正）。
const BINARY_MIME = new Set([
  'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'application/pdf',
]);

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
    // D (2026-07): d-claude 経路では DeepSeek は画像を見られない（実測=黙殺）のに、base64 画像を
    // そのまま送ると毎ターン全履歴分の巨大トークンを浪費する。ds-gateway は DeepSeek 専用経路
    // （upstream=api.deepseek.com）なので、素の Anthropic 直叩き（claude-safe）には影響しない。
    // 画像 content block を短いテキストプレースホルダに差し替える（Anthropic 互換の text block を
    // 維持＝構造は壊さない）。tool_result.content[] 内の画像も deep-walk 中にここで捕捉される。
    // ※ document(PDF) は対象外（下の base64 保全ロジックへ流す）。data の中身は一切載せない。
    if (v.type === 'image' && v.source && typeof v.source === 'object' && v.source.type === 'base64') {
      // media_type は placeholder に生 echo しない（RED-1 修正）。MIME 形状 regex は
      // "sk-ant-…/png" のようなハイフン込み 40 字以下の秘密を誤って通す（=マスク迂回の回帰）ため、
      // 既知の安全な画像 MIME ホワイトリスト(BINARY_MIME)との完全一致のみ echo し、集合外は「不明」。
      let mime = '不明';
      if (typeof v.source.media_type === 'string') {
        const mt = String(v.source.media_type).split(';')[0].trim();
        if (BINARY_MIME.has(mt)) mime = mt;
      }
      let approxBytes = 0;
      if (typeof v.source.data === 'string') {
        const b = v.source.data.replace(/[^A-Za-z0-9+/]/g, '');
        approxBytes = Math.floor(b.length * 3 / 4);
      }
      return { type: 'text', text: '[画像データは送信していません: ' + mime + ' 約' + approxBytes + 'bytes。DeepSeek は画像を見られません。内容確認は describe_image ツールを使ってください]' };
    }
    // F-7/F-9/F-9fin: Anthropic content block の base64 メディアデータ（image/document 等の source.data）は
    // バイナリを base64 エンコードした文字列であり、secret パターンに偶然一致し得るが
    // 実際には機微情報ではない。ただし除外条件を厳格化して偽装漏洩穴を塞ぐ。
    //
    // data をマスク除外するのは以下をすべて満たす場合のみ（4条件・全て必須）:
    //   1. v.type === 'base64'
    //   2. v.media_type が既知バイナリ MIME ホワイトリストに含まれる（非空文字列だけでは不可）
    //      text/plain 等は除外対象外 → マスクされる
    //   3. v.data が厳格な base64 charset のみ（A-Za-z0-9+/= と空白のみ）
    //      ハイフン・アンダースコアを含む値（sk-ant-... 等）は除外されずマスクされる。
    //      ※ '-' '_' は base64url の拡張。標準 base64 の Anthropic スキーマには現れないため許可しない。
    //   4. v.data.length > 512 — 本物のメディアは圧倒的に大きい。
    //      短い secret 偽装（AKIA系20字等）を弾く。
    // ※ BINARY_MIME は module スコープに hoist 済み（画像 placeholder の media_type 判定と共有）。
    const isLegitimateBase64Source = (
      v.type === 'base64' &&
      typeof v.media_type === 'string' && BINARY_MIME.has(String(v.media_type).split(';')[0].trim()) &&
      typeof v.data === 'string' && /^[A-Za-z0-9+/\s]+=*$/.test(v.data) &&
      v.data.length > 512
    );
    const out = {};
    for (const k of Object.keys(v)) {
      if (isLegitimateBase64Source && k === 'data') {
        out[k] = v[k]; // 正規バイナリ媒体データはそのまま通す（マスクしない）
      } else {
        out[k] = maskValue(v[k], counts, ctx);
      }
    }
    return out;
  }
  return v; // numbers, booleans, null
}

function maskRequestBody(json, ctx) {
  const counts = {};
  // F-1: parsed body 全体を deep-walk して全文字列リーフに generic+PII マスクを適用する。
  // messages/system に限らず metadata/tools/任意トップレベル文字列・非配列 messages も網羅。
  // maskValue は文字列リーフのみ変換し、model 名・数値・真偽値は無傷なので API は壊れない。
  const masked = maskValue(json, counts, ctx);
  return { json: masked, counts, changed: true };
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

// URL クエリ値をマスクして再構築。?key=value の value のみ generic+PII マスク（key 名は保全）。
// マスク不能（パース不可・不正 percent-encoding）なら null を返し、呼び出し側で fail-closed させる。
//
// F-8: URLSearchParams は不正な percent-encoding（例: %E0%A4%A）を黙って U+FFFD に置換する。
// これは「silently rewrite して upstream に届ける」= fail-open と等価なため許容しない。
// 対策: raw query 文字列の各値を decodeURIComponent で直接デコードし、
// 例外（URIError）が出た場合は fail-closed（null を返す）。
function maskUrlQuery(reqUrl, counts, ctx) {
  const qIdx = reqUrl.indexOf('?');
  if (qIdx === -1) return reqUrl;
  const base = reqUrl.slice(0, qIdx);
  const query = reqUrl.slice(qIdx + 1);
  if (!query) return reqUrl;

  // F-8: URLSearchParams のサイレント正規化を避けるため raw query を手動 split。
  // 各トークンを decodeURIComponent して不正 percent-encoding を事前検出する。
  const pairs = query.split('&');
  const out = [];
  for (const pair of pairs) {
    const eqIdx = pair.indexOf('=');
    const rawKey = eqIdx === -1 ? pair : pair.slice(0, eqIdx);
    const rawVal = eqIdx === -1 ? '' : pair.slice(eqIdx + 1);
    // キーと値の両方をデコード試行。失敗 = 不正 percent-encoding → fail-closed。
    try {
      decodeURIComponent(rawKey);
      decodeURIComponent(rawVal);
    } catch (_) {
      return null; // 不正 percent-encoding → fail-closed
    }
    // マスクは URLSearchParams 経由でデコード→マスク→再エンコード。
    let decodedVal;
    try {
      // URLSearchParams で個々のパラメータをパース（+ を空白に変換する挙動も含む）。
      decodedVal = new URLSearchParams(pair).get(rawKey) ?? rawVal;
    } catch (_) {
      return null;
    }
    const maskedVal = maskValue(decodedVal, counts, ctx);
    // 再エンコード: encodeURIComponent で RFC3986 準拠に戻す。
    out.push(rawKey + (eqIdx === -1 ? '' : '=' + encodeURIComponent(maskedVal)));
  }
  const rebuilt = out.join('&');
  return rebuilt ? `${base}?${rebuilt}` : base;
}

async function handleProxy(req, res, upstreamUrl, session) {
  // F-4: denylist が設定あり×読込失敗 → 検査が信頼できないため全リクエスト転送拒否（fail-closed）。
  if (session.denylistFailClosed) {
    req.resume();
    res.writeHead(503, { 'content-type': 'application/json' });
    res.end('{"error":"ds-gateway: denylist configured but unreadable; not forwarded (fail-closed)"}');
    return;
  }

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
  const counts = {};
  const alloc = (v, c) => { const t = session.tokenMap.alloc(v, c); allocated.add(t); return t; };
  const ctx = { alloc, denylistTerms: session.denylistTerms };

  // F-2: body を持つあらゆるメソッド（POST/PUT/PATCH/DELETE 等）の JSON body を検査。
  // 非JSON body は全メソッドで検査不能 → 415 fail-closed。
  if (raw.length) {
    if (!ct.includes('application/json')) {
      res.writeHead(415, { 'content-type': 'application/json' });
      res.end('{"error":"ds-gateway: non-JSON body not inspectable; not forwarded (fail-closed)"}');
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
    const { json, counts: bodyCounts } = maskRequestBody(parsed, ctx);
    addCounts(counts, bodyCounts);
    outBody = Buffer.from(JSON.stringify(json), 'utf8');
  }

  // F-2: URL クエリ値もマスク。マスク不能（パース不可）なら fail-closed。
  let outUrl = req.url;
  if (req.url.indexOf('?') !== -1) {
    const masked = maskUrlQuery(req.url, counts, ctx);
    if (masked === null) {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end('{"error":"ds-gateway: unparseable URL query; not forwarded (fail-closed)"}');
      return;
    }
    outUrl = masked;
  }

  if (counts.total) logDetection(req.url.split('?')[0], counts);

  forward(req, res, upstreamUrl, outBody, session, allocated, outUrl);
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

// F-3: 転送 header 値の PII/secret をマスクする。ただし upstream 認証・転送に必須の
// 標準 header はマスクすると認証/配送が壊れるため保全（ホワイトリスト）。
const HEADER_PRESERVE = new Set([
  'authorization', 'x-api-key', 'api-key', 'content-type', 'content-length',
  'host', 'accept', 'accept-encoding', 'accept-language', 'user-agent',
  'anthropic-version', 'anthropic-beta', 'x-stainless-os', 'x-stainless-lang',
  'x-stainless-package-version', 'x-stainless-runtime', 'x-stainless-runtime-version',
  'x-stainless-arch', 'x-stainless-retry-count',
]);

function maskHeaders(headers, session) {
  // header マスクは可逆トークン化しない（応答 header に header 由来トークンが混ざらないよう、
  // 不可逆の [MASKED:*] 固定で alloc を渡さない）。
  const ctx = { denylistTerms: session.denylistTerms }; // alloc なし → 不可逆
  const out = {};
  for (const k of Object.keys(headers)) {
    const v = headers[k];
    if (HEADER_PRESERVE.has(k.toLowerCase())) { out[k] = v; continue; }
    if (typeof v === 'string') {
      out[k] = maskText(v, ctx).masked;
    } else if (Array.isArray(v)) {
      out[k] = v.map((item) => (typeof item === 'string' ? maskText(item, ctx).masked : item));
    } else {
      out[k] = v;
    }
  }
  return out;
}

function forward(req, res, upstreamUrl, body, session, allocated, outUrl) {
  const isHttps = upstreamUrl.protocol === 'https:';
  const lib = isHttps ? https : http;
  const headers = maskHeaders(req.headers, session);
  if (session.upstreamAuthorization) {
    headers.authorization = session.upstreamAuthorization;
    delete headers['x-api-key'];
    delete headers['api-key'];
  }
  headers.host = upstreamUrl.host;
  headers['content-length'] = Buffer.byteLength(body);
  delete headers['accept-encoding'];
  const HOP_BY_HOP = ['connection','keep-alive','proxy-authenticate','proxy-authorization','te','trailer','transfer-encoding','upgrade'];
  for (const h of HOP_BY_HOP) delete headers[h];
  const basePath = upstreamUrl.pathname.replace(/\/$/, '');
  const reqPath = basePath + (outUrl !== undefined ? outUrl : req.url);

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

module.exports = { createGateway, DEFAULT_PORT, DEFAULT_UPSTREAM, DEFAULT_AUTH_FILE };

if (require.main === module) {
  createGateway().listen().then((s) => {
    console.log(`listening on 127.0.0.1:${s.address().port}`);
  });
}
