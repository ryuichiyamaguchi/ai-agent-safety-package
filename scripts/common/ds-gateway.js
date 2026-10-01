// DeepSeek 送信検査 Gateway（loopback 専用・依存ゼロ）
'use strict';
const http = require('node:http');
const https = require('node:https');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { URL } = require('node:url');
const { maskText } = require('./secret-patterns.js');
const { createTokenMap } = require('./token-map.js');
const { loadDenylistResult } = require('./denylist.js');
const { recordGatewayStart } = require('./gateway-token.js');

const DEFAULT_PORT = Number(process.env.DS_GATEWAY_PORT || 8788);
const DEFAULT_UPSTREAM = process.env.DS_GATEWAY_UPSTREAM || 'https://api.deepseek.com/anthropic';
const DEFAULT_AUTH_FILE = process.env.DS_GATEWAY_AUTH_FILE || '';
// ランチャーが解決済みの実キーを渡してくる口（この行だけの環境変数として渡される）。
// 解決の順序（環境変数 → OS の金庫 → 旧平文）はランチャー側の責務。
const DEFAULT_UPSTREAM_KEY = process.env.DEEPSEEK_API_KEY || '';
// 呼び出し元認証トークン。ランチャーが起動ごとに乱数で採番して環境変数で渡す。
const DEFAULT_TOKEN = process.env.DS_GATEWAY_TOKEN || '';
const DEFAULT_MAX_BODY = Number(process.env.DS_GATEWAY_MAX_BODY || 10 * 1024 * 1024); // 10MB（M2: ReDoS/メモリ枯渇の上限）
const DEFAULT_WORKSPACE = process.env.DS_GATEWAY_WORKSPACE || process.cwd();
const DEEPSEEK_V4_LIMIT = { context: 1048576, output: 393216 };
const STATUS_IDLE = {
  version: 1,
  status: 'idle',
  request_status: 'idle',
  model: 'unknown',
  cwd: DEFAULT_WORKSPACE,
  thinking: 'unknown',
  endpoint: '',
  started_at: '',
  first_output_at: '',
  updated_at: '',
  duration_ms: 0,
  active_requests: 0,
  context: {
    limit: DEEPSEEK_V4_LIMIT.context,
    used: 0,
    remaining: DEEPSEEK_V4_LIMIT.context,
    used_pct: 0,
    remaining_pct: 100,
    source: 'estimate',
  },
  tokens: { input: 0, output: 0, total: 0, source: 'estimate' },
  speed: { output_tokens_per_sec: 0, source: 'estimate' },
};

// M-7（呼び出し元認証）: gateway は 127.0.0.1 で待ち受け、受け取った Authorization を
// 検証せずに実キーへ差し替えて転送していた。そのため同一 PC の任意プロセス（受講者が
// 拾ってきたスクリプト等）や DNS リバインディングを踏んだブラウザが、受講者の DeepSeek
// キーで API を叩けてしまう。ランチャーが起動ごとに採番する乱数トークンを必須にして塞ぐ。
// 突合は sha256 で 32 バイト固定長にしてから timingSafeEqual（長さ差で throw させない・
// 一致バイト数から値を推測されない）。
function sha256(value) {
  return crypto.createHash('sha256').update(String(value), 'utf8').digest();
}

// Authorization / x-api-key / api-key から提示トークン候補を取り出す。
// Authorization は "Bearer <token>" 形式（Claude Code）と生値の両方を受ける。
function presentedTokens(headers) {
  const out = [];
  const auth = headers.authorization;
  if (typeof auth === 'string' && auth.trim()) {
    const value = auth.trim();
    const bearer = /^Bearer[ \t]+(.+)$/i.exec(value);
    out.push(bearer ? bearer[1].trim() : value);
  }
  for (const name of ['x-api-key', 'api-key']) {
    const value = headers[name];
    if (typeof value === 'string' && value.trim()) out.push(value.trim());
  }
  return out;
}

function isAuthorizedCaller(headers, expectedHash) {
  let ok = false;
  // 途中 return しない（どの候補で一致したかを応答時間から推測させない）。
  for (const candidate of presentedTokens(headers)) {
    if (crypto.timingSafeEqual(sha256(candidate), expectedHash)) ok = true;
  }
  return ok;
}

// 401（呼び出し元の合言葉が合わない）を記録する。
//
// もとは 401 をどこにも残していなかったため、「受講者の画面に Unauthorized が出た」以外の
// 手がかりが無く、原因（合言葉を持たない別プロセスなのか、古い合言葉のまま残った窓なのか、
// gateway が立て直されたのか）を実機で切り分けられなかった。ここで最低限の素性だけ残す。
//
// 合言葉そのものは絶対に書かない。書くのは sha256 の先頭 8 桁（指紋）だけで、
// 「提示された合言葉と、こちらが期待している合言葉が同じか違うか」を突き合わせるのに使う。
const UNAUTHORIZED_LOG_WINDOW_MS = 10000;
const unauthorizedLogState = new Map();

// gateway の出来事を 1 本の追記ファイルに残す。Windows の Start-Process は標準出力の
// リダイレクトが毎回上書きになり「何回・いつ立ち上がったか」が追えなかったため、
// OS に依存しないこちらへ寄せる（起動の記録と 401 の記録が同じ時系列で並ぶ）。
function gatewayEventLogPath() {
  const dir = process.env.AI_SAFE_LOG_DIR || path.join(os.homedir(), '.ai-safety', 'logs');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return path.join(dir, 'ds-gateway-events.jsonl');
}

function logGatewayEvent(event, extra) {
  try {
    const ev = {
      ts: new Date().toISOString(),
      event,
      source: 'ds-gateway',
      gateway_pid: process.pid,
      ...(extra || {}),
    };
    fs.appendFileSync(gatewayEventLogPath(), `${JSON.stringify(ev)}\n`, { mode: 0o600 });
  } catch (_) { /* ログ失敗で起動は止めない */ }
}

function fingerprintOf(value) {
  return sha256(value).toString('hex').slice(0, 8);
}

function logUnauthorized(req, expectedHash, gatewayStartedAt) {
  try {
    const headers = req.headers || {};
    const presented = presentedTokens(headers);
    const presentedFp = presented.length ? fingerprintOf(presented[0]) : '';
    const reqPath = String(req.url || '').split('?')[0];
    const key = `${presentedFp}|${reqPath}`;
    const now = Date.now();
    const prev = unauthorizedLogState.get(key);
    // 同じ相手が同じ場所を叩き続けるとログが膨らむので間引く。
    // 抑制した件数は次に書くときに載せるので、頻度は失われない。
    if (prev && now - prev.at < UNAUTHORIZED_LOG_WINDOW_MS) {
      prev.suppressed += 1;
      return;
    }
    const suppressed = prev ? prev.suppressed : 0;
    unauthorizedLogState.set(key, { at: now, suppressed: 0 });

    const ev = {
      ts: new Date().toISOString(),
      event: 'unauthorized_caller',
      source: 'ds-gateway',
      method: String(req.method || ''),
      path: reqPath,
      has_authorization: typeof headers.authorization === 'string' && !!headers.authorization.trim(),
      has_x_api_key: typeof headers['x-api-key'] === 'string' && !!headers['x-api-key'].trim(),
      has_api_key: typeof headers['api-key'] === 'string' && !!headers['api-key'].trim(),
      presented_fp: presentedFp,
      expected_fp: expectedHash.toString('hex').slice(0, 8),
      user_agent: String(headers['user-agent'] || '').slice(0, 64),
      gateway_pid: process.pid,
      gateway_started_at: gatewayStartedAt || '',
      suppressed_since_last: suppressed,
    };
    fs.appendFileSync(gatewayEventLogPath(), `${JSON.stringify(ev)}\n`, { mode: 0o600 });
  } catch (_) { /* ログ失敗で応答は止めない */ }
}

function cloneStatus(value) {
  return JSON.parse(JSON.stringify(value));
}

function modelId(value) {
  const raw = String(value || '').trim();
  if (!raw) return 'unknown';
  const tail = raw.split('/').pop().replace(/\[[^\]]+\]$/, '');
  return tail || raw;
}

function modelLimit(value) {
  const id = modelId(value);
  if (/^deepseek-(?:flash|v4-(?:pro|flash))$/i.test(id)) return { ...DEEPSEEK_V4_LIMIT };
  return { ...DEEPSEEK_V4_LIMIT };
}

function asNumber(...values) {
  for (const value of values) {
    const n = Number(value);
    if (Number.isFinite(n) && n >= 0) return n;
  }
  return 0;
}

function addStringLengths(value) {
  if (typeof value === 'string') return value.length;
  if (Array.isArray(value)) return value.reduce((sum, item) => sum + addStringLengths(item), 0);
  if (value && typeof value === 'object') {
    return Object.values(value).reduce((sum, item) => sum + addStringLengths(item), 0);
  }
  return 0;
}

function approxTokensFromChars(chars) {
  const n = Number(chars) || 0;
  if (n <= 0) return 0;
  return Math.max(1, Math.ceil(n / 4));
}

function requestTokenEstimate(json) {
  return approxTokensFromChars(addStringLengths(json));
}

function normalizeUsage(usage) {
  if (!usage || typeof usage !== 'object') return null;
  const input = asNumber(
    usage.prompt_tokens,
    usage.input_tokens,
    usage.promptTokens,
    usage.inputTokens,
  );
  const output = asNumber(
    usage.completion_tokens,
    usage.output_tokens,
    usage.completionTokens,
    usage.outputTokens,
  );
  const total = asNumber(
    usage.total_tokens,
    usage.totalTokens,
    input + output,
  );
  if (!input && !output && !total) return null;
  return { input, output, total: total || input + output, source: 'usage' };
}

function thinkingLabel(json, model) {
  const extra = json && (json.extra_body || json.extraBody || {});
  const thinking = (json && json.thinking) || extra.thinking || {};
  const type = String(thinking.type || '').trim().toLowerCase();
  if (type === 'disabled') return 'disabled';
  const effort = String(
    (json && (json.reasoning_effort || json.reasoningEffort)) ||
    extra.reasoning_effort ||
    extra.reasoningEffort ||
    (json && json.output_config && json.output_config.effort) ||
    (extra.output_config && extra.output_config.effort) ||
    '',
  ).trim();
  if (effort) return effort;
  return /^deepseek-(?:flash$|v4-)/i.test(modelId(model)) ? 'auto(max)' : 'unknown';
}

function updateDerivedStatus(status) {
  const limits = modelLimit(status.model);
  const tokens = status.tokens || { input: 0, output: 0, total: 0, source: 'estimate' };
  const used = asNumber(tokens.total, tokens.input + tokens.output);
  const remaining = Math.max(0, limits.context - used);
  const usedPct = limits.context ? Math.min(100, (used / limits.context) * 100) : 0;
  status.context = {
    limit: limits.context,
    used,
    remaining,
    used_pct: Number(usedPct.toFixed(2)),
    remaining_pct: Number(Math.max(0, 100 - usedPct).toFixed(2)),
    source: tokens.source || 'estimate',
  };
  const start = Date.parse(status.started_at || '');
  const speedStart = Date.parse(status.first_output_at || status.started_at || '');
  const end = status.request_status === 'streaming' ? Date.now() : Date.parse(status.updated_at || '');
  const elapsedMs = start && end && end >= start ? Math.max(0, end - start) : 0;
  const outputElapsedMs = speedStart && end && end >= speedStart ? Math.max(0, end - speedStart) : elapsedMs;
  status.duration_ms = elapsedMs;
  const seconds = outputElapsedMs / 1000;
  const output = asNumber(tokens.output);
  status.speed = {
    output_tokens_per_sec: seconds > 0 && output > 0 ? Number((output / seconds).toFixed(2)) : 0,
    source: tokens.source || 'estimate',
  };
  return status;
}

function createActivity(workspace) {
  const state = cloneStatus({ ...STATUS_IDLE, cwd: workspace || DEFAULT_WORKSPACE });
  let seq = 0;
  const active = new Set();
  const byId = new Map();

  function publish(record) {
    const now = new Date().toISOString();
    state.version = 1;
    state.status = record.request_status === 'streaming' ? 'streaming' : record.request_status;
    state.request_status = record.request_status;
    state.model = record.model;
    state.cwd = record.cwd;
    state.thinking = record.thinking;
    state.endpoint = record.endpoint;
    state.started_at = record.started_at;
    state.first_output_at = record.first_output_at || '';
    state.updated_at = now;
    state.active_requests = active.size;
    const exact = record.usage || null;
    const outputEstimate = approxTokensFromChars(record.output_chars || 0);
    const input = exact ? exact.input : record.estimated_input_tokens;
    const output = exact ? exact.output : outputEstimate;
    const total = exact ? exact.total : input + output;
    state.tokens = {
      input,
      output,
      total,
      source: exact ? 'usage' : 'estimate',
    };
    updateDerivedStatus(state);
  }

  return {
    start(meta) {
      const id = ++seq;
      const now = new Date().toISOString();
      const record = {
        id,
        request_status: 'streaming',
        model: meta.model || 'unknown',
        cwd: workspace || DEFAULT_WORKSPACE,
        thinking: meta.thinking || 'unknown',
        endpoint: meta.endpoint || '',
        started_at: now,
        first_output_at: '',
        output_chars: 0,
        estimated_input_tokens: meta.inputTokens || 0,
        usage: null,
      };
      active.add(id);
      byId.set(id, record);
      publish(record);
      return id;
    },
    observe(id, data) {
      const record = byId.get(id);
      if (!record) return;
      if (data && data.usage) record.usage = data.usage;
      if (data && data.outputChars) {
        record.output_chars += data.outputChars;
        if (!record.first_output_at) record.first_output_at = new Date().toISOString();
      }
      publish(record);
    },
    finish(id, status) {
      const record = byId.get(id);
      if (!record) return;
      record.request_status = status || 'completed';
      active.delete(id);
      publish(record);
    },
    snapshot() {
      state.active_requests = active.size;
      if (state.request_status === 'streaming') updateDerivedStatus(state);
      return cloneStatus(state);
    },
  };
}

function requestMetaFromJson(json, req) {
  const model = json && json.model ? String(json.model) : 'unknown';
  return {
    model,
    thinking: thinkingLabel(json || {}, model),
    inputTokens: requestTokenEstimate(json || {}),
    endpoint: `${req.method || 'POST'} ${String(req.url || '').split('?')[0]}`,
  };
}

function createGateway({ upstream = DEFAULT_UPSTREAM, port = DEFAULT_PORT,
                        tokenMap = createTokenMap(), denylistTerms = loadDenylistResult(),
                        maxBody = DEFAULT_MAX_BODY,
                        upstreamAuthFile = DEFAULT_AUTH_FILE,
                        upstreamKey = DEFAULT_UPSTREAM_KEY,
                        authToken = DEFAULT_TOKEN,
                        workspace = DEFAULT_WORKSPACE } = {}) {
  const upstreamUrl = new URL(upstream);
  // 無認証モードは用意しない（後方互換で穴が残ると意味がないため fail-closed で起動拒否）。
  const callerToken = String(authToken || '').trim();
  if (!callerToken) {
    throw new Error('ds-gateway: DS_GATEWAY_TOKEN is not set; refusing to start without caller auth (fail-closed)');
  }
  const authTokenHash = sha256(callerToken);
  // DeepSeek の実キーの受け取り方。
  //   ・秘密の解決（環境変数 → OS の金庫 → 旧平文）は「ランチャー側」で行う。gateway は
  //     解決済みの値を DEEPSEEK_API_KEY として受け取るだけにする。鍵が金庫に移っても
  //     gateway のコードは変わらない、という役割分担。
  //   ・gateway 自身にホームの平文や金庫を探させてはいけない。この関数はテストや他の
  //     ツールからライブラリとして呼ばれるため、周囲にある本物の鍵を勝手に拾って
  //     upstream へ送ってしまう（実際に F-3 の回帰として検出された）。
  //   ・DS_GATEWAY_AUTH_FILE は旧構成との互換のために残す（明示指定が最優先）。
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
  } else if (upstreamKey) {
    const key = String(upstreamKey).trim();
    if (!key || /[\r\n]/.test(key)) {
      throw new Error('ds-gateway: upstream key is empty or invalid (fail-closed)');
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
    authTokenHash,
    // 401 のログに載せる。「どの gateway が拒否したか」を、立て直しをまたいで見分けるため。
    startedAt: new Date().toISOString(),
    activity: createActivity(workspace),
  };
  const server = http.createServer((req, res) => {
    // /healthz は無認証のまま残す。ランチャーは「トークンを持つ自分」だけでなく
    // 「gateway が listen 済みか」を起動待ちで確かめる必要があり、この応答は
    // 固定文字列 {"status":"ok"} だけで秘密も設定も一切返さないため。
    if (req.method === 'GET' && req.url === '/healthz') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{"status":"ok"}');
      return;
    }
    if (req.method === 'GET' && req.url === '/status') {
      const status = session.activity.snapshot();
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ status: 'ok', activity: status }));
      return;
    }
    // 転送経路は全て呼び出し元認証を通す（欠落・不一致は 401・upstream へは出さない）。
    if (!isAuthorizedCaller(req.headers, session.authTokenHash)) {
      logUnauthorized(req, session.authTokenHash, session.startedAt);
      req.resume();
      res.writeHead(401, { 'content-type': 'application/json' });
      res.end('{"error":"ds-gateway: unauthorized caller; not forwarded (fail-closed)"}');
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
const VISION_MIME_EXT = {
  'image/png': '.png',
  'image/jpeg': '.jpg',
  'image/gif': '.gif',
  'image/webp': '.webp',
};

// 画像をそのまま上流へ通してよいモデルか（2026-10-02）。
// DeepSeek の Anthropic 互換 API は image（base64: jpeg/png/gif/webp）に対応し、deepseek-flash
// （V4.1 Flash）は実測で画像を正しく読んだ（赤背景の「7」を正答）。deepseek-v4-pro は同じ画像に
// 「見えない」と答えたので通さない（従来どおりパス付きの案内に差し替えて describe_image へ回す）。
// AI_SAFE_DS_PASS_IMAGES=0 で全モデル従来どおり（画像を送らない）に戻せる。
// 先頭のバイトが本当に画像か（PNG / JPEG / GIF / WebP）。gateway の依存を増やさないため
// image-refs.js の同名関数と同じ判定をここに持つ（gateway は必要最小のファイルだけで動く）。
function looksLikeImage(buf) {
  if (!buf || buf.length < 12) return false;
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return true;
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return true;
  if (buf.slice(0, 4).toString('ascii') === 'GIF8') return true;
  if (buf.slice(0, 4).toString('ascii') === 'RIFF' && buf.slice(8, 12).toString('ascii') === 'WEBP') return true;
  return false;
}
const IMAGE_PASS_MAX_BYTES = 5 * 1024 * 1024; // Anthropic 互換 API の 1 枚あたり上限に合わせる
function visionCapableModel(model) {
  if (process.env.AI_SAFE_DS_PASS_IMAGES === '0') return false;
  const m = String(model || '').trim().toLowerCase();
  return /^deepseek-(v4(\.1)?-)?flash($|-)/.test(m);
}

function visionCacheDir() {
  const d = process.env.AI_SAFE_VISION_CACHE_DIR;
  if (d && String(d).trim()) return String(d).trim();
  return path.join(os.homedir(), '.ai-safety', 'tmp', 'vision');
}

function sweepVisionCache(dir) {
  const maxAgeMs = 48 * 3600 * 1000;
  let names;
  try { names = fs.readdirSync(dir); } catch { return; }
  const now = Date.now();
  for (const name of names) {
    const p = path.join(dir, name);
    try {
      const st = fs.statSync(p);
      if (st.isFile() && (now - st.mtimeMs) > maxAgeMs) fs.unlinkSync(p);
    } catch { /* 掃除は best-effort */ }
  }
}

// 会話に添付された画像をディスクへ落とし、describe_image が読めるパスを返す。
// DeepSeek は画像ブロックを見られないので、gateway がパス付きの案内に差し替える。
// 同じ画像は sha256 先頭で同じファイル名にし、履歴再送のたびに増殖しない。
function materializeVisionImage(mediaType, b64) {
  const ext = VISION_MIME_EXT[mediaType];
  if (!ext) return null;
  if (typeof b64 !== 'string' || !b64) return null;
  let buf;
  try { buf = Buffer.from(b64.replace(/\s/g, ''), 'base64'); } catch { return null; }
  if (!buf || buf.length < 12) return null;
  const dir = visionCacheDir();
  fs.mkdirSync(dir, { recursive: true });
  try { fs.chmodSync(dir, 0o700); } catch { /* Windows 等では無視 */ }
  const hash = crypto.createHash('sha256').update(buf).digest('hex').slice(0, 16);
  const file = path.join(dir, hash + ext);
  if (!fs.existsSync(file)) {
    fs.writeFileSync(file, buf, { mode: 0o600 });
    sweepVisionCache(dir);
  }
  return file;
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
    // D (2026-07): 当時の d-claude 経路では DeepSeek は画像を見られなかった（実測=黙殺）のに、base64 画像を
    // そのまま送ると毎ターン全履歴分の巨大トークンを浪費する。ds-gateway は DeepSeek 専用経路
    // （upstream=api.deepseek.com）なので、素の Anthropic 直叩き（claude-safe）には影響しない。
    // 画像 content block を短いテキストプレースホルダに差し替える（Anthropic 互換の text block を
    // 維持＝構造は壊さない）。tool_result.content[] 内の画像も deep-walk 中にここで捕捉される。
    // ※ document(PDF) は対象外（下の base64 保全ロジックへ流す）。data の中身は一切載せない。
    if (v.type === 'image' && v.source && typeof v.source === 'object' && v.source.type === 'base64') {
      // 画像を読めるモデル宛てで、本物の画像で大きすぎないものだけはそのまま通す。
      // 判定: MIME が既知の画像と完全一致・base64 の文字だけ・デコードした先頭が本当に画像
      // （PNG/JPEG/GIF/WebP のマジックバイト）・5MB 以下。短い秘密を「画像」と偽って送らせる手口は、
      // デコードしても画像の先頭にならないのでここで弾ける。1 つでも外れたら下の差し替え（送らない）。
      if (ctx.passImages) {
        const mt = typeof v.source.media_type === 'string' ? String(v.source.media_type).split(';')[0].trim() : '';
        const data = typeof v.source.data === 'string' ? v.source.data : '';
        const strictB64 = /^[A-Za-z0-9+/\s]+=*$/.test(data);
        const bytes = Math.floor(data.replace(/\s/g, '').length * 3 / 4);
        let realImage = false;
        if (strictB64) {
          try { realImage = looksLikeImage(Buffer.from(data.replace(/\s/g, '').slice(0, 64), 'base64')); } catch { realImage = false; }
        }
        if (VISION_MIME_EXT[mt] && strictB64 && realImage && bytes <= IMAGE_PASS_MAX_BYTES) {
          counts.images_passed = (counts.images_passed || 0) + 1;
          const out = { type: 'image', source: { type: 'base64', media_type: mt, data } };
          if (v.cache_control && typeof v.cache_control === 'object' && v.cache_control.type === 'ephemeral') {
            out.cache_control = { type: 'ephemeral' };
          }
          return out;
        }
      }
      // media_type は placeholder に生 echo しない（RED-1 修正）。MIME 形状 regex は
      // "sk-ant-…/png" のようなハイフン込み 40 字以下の秘密を誤って通す（=マスク迂回の回帰）ため、
      // 既知の安全な画像 MIME ホワイトリスト(BINARY_MIME)との完全一致のみ echo し、集合外は「不明」。
      let mime = '不明';
      if (typeof v.source.media_type === 'string') {
        const mt = String(v.source.media_type).split(';')[0].trim();
        if (BINARY_MIME.has(mt)) mime = mt;
      }
      let approxBytes = 0;
      let saved = null;
      if (typeof v.source.data === 'string') {
        const b = v.source.data.replace(/[^A-Za-z0-9+/]/g, '');
        approxBytes = Math.floor(b.length * 3 / 4);
        if (mime !== '不明') {
          try { saved = materializeVisionImage(mime, v.source.data); } catch { saved = null; }
        }
      }
      let text = '[画像データは送信していません: ' + mime + ' 約' + approxBytes + 'bytes。'
        + (ctx.passImages ? '形式または大きさ（5MB まで）の条件を満たさないため送っていません。' : 'いまのモデルは画像を見られません。');
      if (saved) {
        text += '内容確認は describe_image ツールに image_path として次のパスを渡してください: ' + saved + ']';
      } else {
        text += '内容確認は describe_image ツールを使ってください]';
      }
      return { type: 'text', text };
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
  let requestMeta = requestMetaFromJson({}, req);

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
    ctx.passImages = visionCapableModel(parsed && parsed.model);
    const { json, counts: bodyCounts } = maskRequestBody(parsed, ctx);
    addCounts(counts, bodyCounts);
    requestMeta = requestMetaFromJson(json, req);
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

  forward(req, res, upstreamUrl, outBody, session, allocated, outUrl, requestMeta);
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

function deltaTextLength(obj) {
  if (!obj || typeof obj !== 'object') return 0;
  let chars = 0;
  const choices = Array.isArray(obj.choices) ? obj.choices : [];
  for (const choice of choices) {
    const delta = choice && typeof choice.delta === 'object' ? choice.delta : {};
    const message = choice && typeof choice.message === 'object' ? choice.message : {};
    for (const source of [delta, message]) {
      if (typeof source.content === 'string') chars += source.content.length;
      if (typeof source.reasoning_content === 'string') chars += source.reasoning_content.length;
      if (typeof source.reasoningContent === 'string') chars += source.reasoningContent.length;
    }
  }
  if (!choices.length && typeof obj.content === 'string') chars += obj.content.length;
  return chars;
}

function createResponseObserver(activity, id, contentType) {
  const ct = String(contentType || '').toLowerCase();
  const isSse = ct.includes('event-stream');
  const isJson = ct.includes('json');
  let carry = '';
  let jsonText = '';
  let jsonTooLarge = false;

  function observeJsonValue(value) {
    const usage = normalizeUsage(value && value.usage);
    const outputChars = deltaTextLength(value);
    if (usage || outputChars) activity.observe(id, { usage, outputChars });
  }

  function processSseText(text, flush = false) {
    carry += text;
    const lines = carry.split(/\r?\n/);
    const tail = lines.pop() || '';
    carry = flush ? '' : tail;
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      const payload = trimmed.slice(5).trim();
      if (!payload || payload === '[DONE]') continue;
      try {
        observeJsonValue(JSON.parse(payload));
      } catch { /* malformed stream fragments are ignored for metrics only */ }
    }
    if (flush && tail.trim()) {
      const trimmed = tail.trim();
      if (trimmed.startsWith('data:')) {
        const payload = trimmed.slice(5).trim();
        if (payload && payload !== '[DONE]') {
          try { observeJsonValue(JSON.parse(payload)); } catch { /* metrics only */ }
        }
      }
    }
  }

  return {
    chunk(chunk) {
      if (isSse) {
        processSseText(typeof chunk === 'string' ? chunk : chunk.toString('utf8'));
        return;
      }
      if (isJson && !jsonTooLarge) {
        jsonText += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
        if (jsonText.length > 2 * 1024 * 1024) {
          jsonTooLarge = true;
          jsonText = '';
        }
      }
    },
    end() {
      if (isSse) processSseText('', true);
      if (isJson && jsonText) {
        try { observeJsonValue(JSON.parse(jsonText)); } catch { /* metrics only */ }
      }
    },
  };
}

// upstream が 4xx/5xx を返したときだけ、その素性をログと画面に残す。
// 目的は「Claude Code の画面に出るメッセージが原因を指していない」事故を無くすこと。
// 実測（2026-08-21・mac 実機）: POST /v1/messages が 404 を返すと、Claude Code は本文の形に
// 関係なく「There's an issue with the selected model (…). It may not exist or you may not have
// access to it.」と表示する。401 では出ない。つまりこのメッセージは「モデル名が悪い」ではなく
// 「送り先が 404 を返した」の意味なので、実際の status と本文をここに残さないと切り分けられない。
// 本文は上流のエラー文なので、他の転送経路と同じ不可逆マスク（alloc なし）を通してから
// 先頭 300 文字だけ残す。
function logUpstreamError(session, { status, method, path: reqPath, bodySnippet }) {
  let snippet = '';
  try {
    const ctx = { denylistTerms: session.denylistTerms }; // alloc なし → 不可逆マスク
    snippet = maskText(String(bodySnippet || ''), ctx).masked.slice(0, 300);
  } catch (_) { snippet = ''; }
  logGatewayEvent('upstream_error', { status, method, path: reqPath, body: snippet });
  if (status === 404) {
    console.error(`ds-gateway: upstream returned 404 for ${method} ${reqPath}. `
      + 'Claude Code はこれを「モデルが存在しない」と表示しますが、実際は送り先が 404 を返しています。'
      + `上流応答: ${snippet}`);
  } else {
    console.error(`ds-gateway: upstream returned ${status} for ${method} ${reqPath}: ${snippet}`);
  }
}

function forward(req, res, upstreamUrl, body, session, allocated, outUrl, requestMeta) {
  const isHttps = upstreamUrl.protocol === 'https:';
  const lib = isHttps ? https : http;
  const headers = maskHeaders(req.headers, session);
  // 呼び出し元が提示したのはこの gateway 専用のローカル認証トークン（起動ごとの乱数）であり、
  // upstream には何の意味も持たない local-only の秘密。素通しすると DeepSeek 側のログに
  // 残るだけなので、upstream キーを載せる/載せないに関わらず必ず落とす。
  delete headers.authorization;
  delete headers['x-api-key'];
  delete headers['api-key'];
  if (session.upstreamAuthorization) {
    headers.authorization = session.upstreamAuthorization;
  }
  headers.host = upstreamUrl.host;
  headers['content-length'] = Buffer.byteLength(body);
  delete headers['accept-encoding'];
  const HOP_BY_HOP = ['connection','keep-alive','proxy-authenticate','proxy-authorization','te','trailer','transfer-encoding','upgrade'];
  for (const h of HOP_BY_HOP) delete headers[h];
  const basePath = upstreamUrl.pathname.replace(/\/$/, '');
  const reqPath = basePath + (outUrl !== undefined ? outUrl : req.url);
  const activityId = session.activity.start(requestMeta || requestMetaFromJson({}, req));

  const upReq = lib.request(
    { protocol: upstreamUrl.protocol, host: upstreamUrl.hostname, port: upstreamUrl.port || (isHttps ? 443 : 80), method: req.method, path: reqPath, headers },
    (upRes) => {
      const ct = (upRes.headers['content-type'] || '').toLowerCase();
      const observer = createResponseObserver(session.activity, activityId, ct);
      const isUpstreamError = upRes.statusCode >= 400;
      let errSnippet = '';
      const keepErr = (chunk) => {
        if (!isUpstreamError || errSnippet.length >= 512) return;
        try { errSnippet += Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk); } catch (_) { /* 無視 */ }
      };
      const reportErr = () => {
        if (!isUpstreamError) return;
        logUpstreamError(session, {
          status: upRes.statusCode,
          method: String(req.method || ''),
          path: String(reqPath || '').split('?')[0],
          bodySnippet: errSnippet,
        });
      };
      const transform = (ct.includes('json') || ct.includes('event-stream')) && allocated && allocated.size > 0;
      if (!transform) {
        res.writeHead(upRes.statusCode, upRes.headers);
        upRes.on('data', (chunk) => { observer.chunk(chunk); keepErr(chunk); res.write(chunk); });
        upRes.on('end', () => {
          observer.end();
          reportErr();
          session.activity.finish(activityId, upRes.statusCode >= 400 ? 'error' : 'completed');
          res.end();
        });
        upRes.on('error', () => {
          session.activity.finish(activityId, 'error');
          if (!res.writableEnded) res.end();
        });
        return;
      }
      // RED-B: 復元でバイト長が変わるため content-length を外し chunked にする。
      const outHeaders = { ...upRes.headers };
      delete outHeaders['content-length'];
      res.writeHead(upRes.statusCode, outHeaders);
      const restorer = makeRestorer(session.tokenMap, allocated);
      upRes.setEncoding('utf8');
      upRes.on('data', (chunk) => {
        observer.chunk(chunk);
        keepErr(chunk);
        res.write(restorer.push(chunk));
      });
      upRes.on('end', () => {
        observer.end();
        reportErr();
        session.activity.finish(activityId, upRes.statusCode >= 400 ? 'error' : 'completed');
        res.write(restorer.flush());
        res.end();
      });
      upRes.on('error', () => {
        session.activity.finish(activityId, 'error');
        if (!res.writableEnded) res.end();
      });
    });
  upReq.on('error', () => {
    session.activity.finish(activityId, 'error');
    if (!res.headersSent) { res.writeHead(502, {'content-type':'application/json'}); res.end('{"error":"ds-gateway: upstream unreachable (fail-closed)"}'); }
    else if (!res.writableEnded) res.end();
  });
  upReq.end(body);
}

module.exports = {
  createGateway, DEFAULT_PORT, DEFAULT_UPSTREAM, DEFAULT_AUTH_FILE,
  materializeVisionImage, visionCacheDir, visionCapableModel,
};

if (require.main === module) {
  let gateway;
  try {
    gateway = createGateway();
  } catch (e) {
    // DS_GATEWAY_TOKEN 未設定・upstream キー読取失敗などはここで落とす。ランチャーは
    // health 応答が来ないことで検知し「送信検査なしでは起動しない」に倒す。
    console.error(`ds-gateway: ${e && e.message ? e.message : e}`);
    process.exit(1);
  }
  gateway.listen().then((s) => {
    const boundPort = s.address().port;
    // 「今 listen している gateway の素性（合言葉・本体の指紋・PID・ポート・起動時刻）」を
    // 共有ファイルに残す。次に起動するランチャーはこれを見て、生きている gateway を
    // そのまま使う（＝合言葉を作り直して立て直さない）判断ができる。
    logGatewayEvent('gateway_started', { port: boundPort, upstream: String(DEFAULT_UPSTREAM || '') });
    try {
      recordGatewayStart({ gatewayPath: __filename, port: boundPort, pid: process.pid });
    } catch (e) {
      // 記録に失敗しても検査そのものは働くので起動は止めない（次の起動が立て直すだけ）。
      console.error(`ds-gateway: could not record gateway info: ${e && e.message ? e.message : e}`);
    }
    console.log(`listening on 127.0.0.1:${boundPort} pid=${process.pid} started=${new Date().toISOString()}`);
  });
}
