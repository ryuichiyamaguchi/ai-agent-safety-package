#!/usr/bin/env node
// pollinations-image-mcp.js — 依存ゼロの最小 MCP サーバー（stdio）。
//
// 目的:
//   d-claude（DeepSeek 駆動の Claude Code）に「簡単な画像生成」を与える。無料で画像を作れる
//   のは受講者環境では実質 Pollinations だけ（codex 無料枠は usage limit で不可・Gemini 無料
//   API は画像モデルが limit:0）。Pollinations は API キー不要・無登録で叩けるため、受講者は
//   何の設定もせずに 1 つの MCP ツール `generate_image` で画像を作れる。
//
// 品質の割り切り（重要・ツール説明にも明記）:
//   Pollinations の無料モデル（現状 sana）は「文字なしの背景・写真・イラスト」なら十分きれい
//   だが、画像内に日本語などの文字を入れる用途や高精細が必要な用途では品質が足りない（文字は
//   崩れる）。その場合はこのツールを使わず、練り込んだ画像生成プロンプトを出力して有料ツール
//   （gpt-image-2 等）に回す運用にする。判断はモデルに委ね、ツール説明でそれを促す。
//
// 設計方針:
//   - 依存ゼロ（本パッケージの gemini-search-mcp / two-key-judge と同じ純 Node）。
//   - API キー不要（Pollinations は無認証 GET）。受講者は新規登録・キー登録の手間ゼロ。
//   - 生成画像はワークスペース配下 generated-images/ に保存し、保存先パスを返す。
//   - 教室向けに safe=true（NSFW フィルタ）と private=true（公開フィードに出さない）を付与。
//   - どんな失敗も例外で落とさず、MCP のエラー応答として返す（接続を維持する）。
//
// MCP stdio 転送: JSON-RPC 2.0 メッセージを「改行区切り」で送受信（1 行 1 メッセージ）。
//   stdout はプロトコル専用。ログは stderr のみ。
'use strict';

const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const SERVER_NAME = 'pollinations-image';
const SERVER_VERSION = '1.0.0';
const DEFAULT_PROTOCOL = '2025-06-18';
const HOST = process.env.AI_SAFE_IMAGE_HOST || 'image.pollinations.ai';
const REQUEST_TIMEOUT_MS = Number(process.env.AI_SAFE_IMAGE_TIMEOUT || 90000);
const MAX_PROMPT_CHARS = 1500;
const MAX_BYTES = 12 * 1024 * 1024; // 12MiB 上限（肥大化対策）

// 保存先ディレクトリ。既定はカレント（＝ワークスペース）配下 generated-images/。
function outputDir() {
  const base = process.env.AI_SAFE_IMAGE_DIR || path.join(process.cwd(), 'generated-images');
  return base;
}

function clampDim(v, def) {
  const n = Math.round(Number(v));
  if (!Number.isFinite(n)) return def;
  return Math.max(64, Math.min(1536, n));
}

// ファイル名を安全化（英数・ハイフン・アンダースコアのみ）。空なら timestamp ベース。
function safeName(name) {
  let s = String(name == null ? '' : name).trim();
  s = s.replace(/\.(jpe?g|png)$/i, '');
  s = s.replace(/[^A-Za-z0-9_-]/g, '');
  if (!s) s = 'img-' + Date.now();
  return s.slice(0, 60) + '.jpg';
}

// Pollinations の画像 URL を組み立てる。
function buildUrl(prompt, width, height, seed) {
  const enc = encodeURIComponent(String(prompt).slice(0, MAX_PROMPT_CHARS));
  const qs = new URLSearchParams({
    width: String(width),
    height: String(height),
    nologo: 'true',
    safe: 'true',
    private: 'true',
  });
  if (seed != null && Number.isFinite(Number(seed))) qs.set('seed', String(Math.round(Number(seed))));
  return 'https://' + HOST + '/prompt/' + enc + '?' + qs.toString();
}

// URL を取得して Buffer を返す（リダイレクトを最大 3 回追従）。
// 成功: { ok:true, buffer, contentType }  失敗: { ok:false, message }
function fetchImage(urlStr, redirectsLeft) {
  return new Promise((resolve) => {
    let u;
    try { u = new URL(urlStr); } catch { return resolve({ ok: false, message: 'URL の組み立てに失敗しました。' }); }
    const mod = u.protocol === 'http:' ? http : https;
    const req = mod.request({
      hostname: u.hostname,
      path: u.pathname + u.search,
      method: 'GET',
      headers: { 'User-Agent': 'ai-safety-package/1.0 (classroom)', 'Accept': 'image/*' },
      timeout: REQUEST_TIMEOUT_MS,
    }, (res) => {
      // リダイレクト追従
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        if (redirectsLeft <= 0) return resolve({ ok: false, message: 'リダイレクトが多すぎます。' });
        const next = new URL(res.headers.location, u).toString();
        return resolve(fetchImage(next, redirectsLeft - 1));
      }
      if (res.statusCode !== 200) {
        res.resume();
        let msg = '画像生成に失敗しました（HTTP ' + res.statusCode + '）。';
        if (res.statusCode === 429) msg = '混雑のため画像生成が制限されました（HTTP 429）。少し待って再試行してください。';
        return resolve({ ok: false, message: msg });
      }
      const chunks = [];
      let size = 0;
      res.on('data', (c) => {
        size += c.length;
        if (size <= MAX_BYTES) chunks.push(c);
      });
      res.on('end', () => {
        const buffer = Buffer.concat(chunks);
        const ct = String(res.headers['content-type'] || '');
        // 画像でない（safe フィルタのエラーページ等）場合は失敗扱い。
        const looksImage = ct.startsWith('image/') || (buffer.length > 3 && (
          (buffer[0] === 0xff && buffer[1] === 0xd8) || // JPEG
          (buffer[0] === 0x89 && buffer[1] === 0x50)    // PNG
        ));
        if (!looksImage) {
          const head = buffer.toString('utf8', 0, Math.min(200, buffer.length));
          return resolve({ ok: false, message: '画像が返りませんでした（内容フィルタや一時エラーの可能性）。' + (head ? ' 応答: ' + head : '') });
        }
        resolve({ ok: true, buffer, contentType: ct });
      });
    });
    req.on('error', (e) => resolve({ ok: false, message: 'ネットワークエラー: ' + e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ ok: false, message: '画像生成がタイムアウトしました。' }); });
    req.end();
  });
}

// 生成 → 保存。成功: { ok:true, filePath }  失敗: { ok:false, message }
async function generate(args) {
  const prompt = typeof args.prompt === 'string' ? args.prompt.trim() : '';
  if (!prompt) return { ok: false, message: 'prompt が空です。作りたい画像の内容を指定してください。' };
  const width = clampDim(args.width, 1024);
  const height = clampDim(args.height, 1024);
  const url = buildUrl(prompt, width, height, args.seed);

  const r = await fetchImage(url, 3);
  if (!r.ok) return r;

  const dir = outputDir();
  try { fs.mkdirSync(dir, { recursive: true }); } catch (e) { return { ok: false, message: '保存先を作成できませんでした: ' + e.message }; }
  const filePath = path.join(dir, safeName(args.filename));
  try { fs.writeFileSync(filePath, r.buffer); } catch (e) { return { ok: false, message: '画像の保存に失敗しました: ' + e.message }; }
  return { ok: true, filePath, bytes: r.buffer.length, width, height };
}

// ---- MCP (JSON-RPC 2.0 over stdio, newline-delimited) ----------------------
const TOOL = {
  name: 'generate_image',
  description:
    '無料の簡単な画像生成（Pollinations）。文字を含まない背景・写真・イラスト・アイキャッチ向け。'
    + '生成した画像をワークスペースの generated-images/ に保存し、保存先パスを返す。API キー不要。'
    + '【重要】画像内に日本語などの文字を入れる用途、または高精細・正確さが必要な用途では品質が'
    + '足りず文字が崩れる。その場合はこのツールを使わず、練り込んだ画像生成プロンプト（日本語で）'
    + 'を出力してユーザーに渡し、有料の画像ツール（gpt-image-2 等）で作るよう促すこと。',
  inputSchema: {
    type: 'object',
    properties: {
      prompt: { type: 'string', description: '作りたい画像の説明（英語でも日本語でもよい。画像内に入れる文字は崩れるので避ける）。' },
      width: { type: 'integer', description: '幅ピクセル（既定 1024、64〜1536）。' },
      height: { type: 'integer', description: '高さピクセル（既定 1024、64〜1536）。' },
      filename: { type: 'string', description: '保存ファイル名（省略可。英数字。拡張子不要）。' },
    },
    required: ['prompt'],
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
      if (name !== 'generate_image') {
        if (!isNotification) err(id, -32602, 'Unknown tool: ' + name);
        return;
      }
      const r = await generate(args);
      if (!r.ok) {
        return ok(id, { content: [{ type: 'text', text: r.message }], isError: true });
      }
      const text = '画像を生成しました: ' + r.filePath + '（' + r.width + 'x' + r.height + ', ' + r.bytes + ' bytes）';
      return ok(id, { content: [{ type: 'text', text }], isError: false });
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
      Promise.resolve().then(() => handle(msg)).catch((e) => {
        if (msg && msg.id != null) err(msg.id, -32603, 'Internal error: ' + (e && e.message));
      });
    }
  });
  process.stdin.on('end', () => process.exit(0));
  process.stderr.write('[pollinations-image-mcp] ready (host=' + HOST + ')\n');
}

if (require.main === module) main();

module.exports = { generate, buildUrl, safeName, handle, TOOL };
