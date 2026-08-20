#!/usr/bin/env node
// gemini-vision-mcp.js — 依存ゼロの最小 MCP サーバー（stdio）。
//
// 目的:
//   d-claude（DeepSeek 駆動の Claude Code）に「目」を与える。DeepSeek は画像入力を
//   受け付けない（Anthropic 互換で image コンテンツは黙殺される＝実測確認済み）ので、
//   モデル本体は画像を見られない。そこで「画像を Gemini に見せて内容/文字をテキストで
//   返す」ツール `describe_image` を 1 個公開し、DeepSeek がツール呼び出しで“見て”もらう。
//   画像生成 MCP（pollinations / agy）の逆パターン（画像→テキスト）。
//
// 設計方針:
//   - 依存ゼロ（本パッケージの gemini-search-mcp と同じ純 Node・stdio JSON-RPC）。
//   - キーは既存の安全パッケージ Gemini キーを使い回す（gemini-client.resolveApiKey）。
//     受講者は新規アカウント不要（検索/コーチと同じキー・画像“入力”は無料枠で通る実測済み）。
//   - モデルは gemini-2.5-flash 既定（無料キーで画像読取が返ることを実測）。429 時は
//     gemini-3.1-flash-lite にフォールバック。AI_SAFE_VISION_MODEL で上書き可。
//   - **サブプロセスを一切起動しない**（agy MCP の shell 注入事故を避け、Gemini API を
//     https 直叩きのみ）。宛先は generativelanguage.googleapis.com 固定（任意 URL 不可）。
//   - マジックバイトで PNG/JPEG/GIF/WebP/BMP を判定し、**プレーンな非画像ファイル（.env 等の
//     テキスト）は Google に送らず拒否**する。symlink も拒否。サイズ上限 20MB。
//     ※これは「casual に非画像を送らない」ゲートであり任意データ流出の完全防止ではない
//       （画像コンテナには任意バイトを埋め込めるため）。ただし送信境界は既存の gemini-search
//       MCP と同一（同じ Gemini キー/host へ送る）＝**新しい流出クラスを増やさない**。詳細は
//       detectImageMime の脅威モデル注記を参照。画像は Google に送られる（検索/コーチと同じ境界）。
//   - どんな失敗も例外で落とさず MCP エラー応答として返す（接続を維持）。
//
// MCP stdio 転送: JSON-RPC 2.0 を「改行区切り」で送受信（1 行 1 メッセージ）。
// stdout はプロトコル専用。ログは stderr のみ。
'use strict';

const https = require('https');
const fs = require('fs');
const path = require('path');
let resolveApiKey, GEMINI_HOST;
try {
  ({ resolveApiKey, GEMINI_HOST } = require('./gemini-client.js'));
} catch (_e) {
  // 順序は本体と同じ「環境変数 → OS の金庫 → 旧平文」に揃える（独自順序を持たせない）。
  GEMINI_HOST = 'generativelanguage.googleapis.com';
  const store = require('./secret-store.js');
  resolveApiKey = function () { return store.resolve('gemini').value; };
}

const SERVER_NAME = 'gemini-vision';
const SERVER_VERSION = '1.0.0';
const DEFAULT_PROTOCOL = '2025-06-18';
const VISION_MODEL = process.env.AI_SAFE_VISION_MODEL || 'gemini-2.5-flash';
const FALLBACK_MODEL = process.env.AI_SAFE_VISION_FALLBACK || 'gemini-3.1-flash-lite';
const REQUEST_TIMEOUT_MS = Number(process.env.AI_SAFE_VISION_TIMEOUT || 30000);
const MAX_IMAGE_BYTES = Number(process.env.AI_SAFE_VISION_MAX_BYTES || 20 * 1024 * 1024);
const MAX_RESPONSE_BYTES = Number(process.env.AI_SAFE_VISION_MAX_RESPONSE || 2 * 1024 * 1024);
const MAX_QUESTION_CHARS = 800;
const DEFAULT_QUESTION = 'この画像に何が写っているか、書かれている文字も含めて日本語で詳しく説明してください。';

// ---- 画像タイプ判定（先頭マジックバイト。画像でなければ null → 送信しない） ----
// これは「プレーンな非画像ファイル(.env 等のテキスト)を誤って Google に送らない」ための
// ゲート。**任意データの流出を完全に防ぐものではない**: 画像コンテナ(PNG チャンク/JPEG
// セグメント/BMP/WebP)には仕様上、任意バイトを埋め込めるため、正しい画像に見えるファイルに
// データを内包させることは原理的に防げない(再エンコードしない限り)。
// ★重要(脅威モデル): この MCP の送信境界は既存の gemini-search MCP と同一である
//   ——どちらも「ユーザ/モデルが与えた内容を同じ Google(Gemini) の同じキー/host へ送る」。
//   よって本ツールは**新しい流出クラスを追加しない**。加えて、AI に polyglot を「作らせる」
//   経路は既に塞がれている(保護ファイルの読取は guard-bash が deny・秘密を含むファイル書込は
//   guard-write が deny)。教室 PC は機密を置かない前提(v1.12.0)。以上より magic-byte ゲートで
//   十分と判断し、末尾ジャンク等の構造検証は行わない(正規画像——BMP の bfSize=0・JPEG の EOI
//   後パディング等——を誤拒否し、かつ脅威を止めないため。cycle-2 レビューで撤去)。
function detectImageMime(buf) {
  if (!buf || buf.length < 12) return null;
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return 'image/png';
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
  if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x38) return 'image/gif';
  if (buf[0] === 0x42 && buf[1] === 0x4d) return 'image/bmp';
  if (buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46 &&
      buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50) return 'image/webp';
  return null;
}

// 画像ファイルを安全に読む。成功: {ok:true, mime, b64}。失敗: {ok:false, message}。
function readImage(imagePath) {
  if (!imagePath || typeof imagePath !== 'string') {
    return { ok: false, message: 'image_path が空です。読み取りたい画像ファイルのパスを指定してください。' };
  }
  const abs = path.resolve(imagePath);
  // シンボリックリンクは拒否（symlink 経由で機微ファイルを指す/TOCTOU を避ける）。lstat で
  // リンク自身を見る。通常のスクショ/画像は実体ファイルなので実害はない。
  let lst;
  try { lst = fs.lstatSync(abs); } catch (_e) {
    return { ok: false, message: '画像ファイルが見つかりません: ' + abs };
  }
  if (lst.isSymbolicLink()) {
    return { ok: false, message: 'シンボリックリンクは対象外です（実体の画像ファイルを指定してください）: ' + abs };
  }
  if (!lst.isFile()) return { ok: false, message: 'ファイルではありません: ' + abs };
  if (lst.size > MAX_IMAGE_BYTES) {
    return { ok: false, message: '画像が大きすぎます（' + Math.round(lst.size / 1024 / 1024) + 'MB > 上限 ' + Math.round(MAX_IMAGE_BYTES / 1024 / 1024) + 'MB）。' };
  }
  let buf;
  try { buf = fs.readFileSync(abs); } catch (e) {
    return { ok: false, message: '画像を読み込めませんでした: ' + (e && e.message ? e.message : e) };
  }
  // lstat 後に肥大化した場合（TOCTOU）に備え、実バイト数でも上限を再確認する。
  if (buf.length > MAX_IMAGE_BYTES) {
    return { ok: false, message: '画像が大きすぎます（上限 ' + Math.round(MAX_IMAGE_BYTES / 1024 / 1024) + 'MB）。' };
  }
  const mime = detectImageMime(buf);
  if (!mime) {
    return { ok: false, message: 'これは対応画像ファイル（PNG/JPEG/GIF/WebP/BMP）ではないため送信しません: ' + abs };
  }
  return { ok: true, mime, b64: buf.toString('base64') };
}

// ---- Gemini vision 呼び出し（1 モデル分） -----------------------------------
function callGemini(model, question, mime, b64) {
  return new Promise((resolve) => {
    const key = resolveApiKey();
    if (!key) return resolve({ ok: false, status: 0, message: 'Gemini API キーが未設定です（「7_AIコーチのキーを登録」で登録してください）。' });
    const body = JSON.stringify({
      contents: [{ role: 'user', parts: [
        { text: String(question || DEFAULT_QUESTION).slice(0, MAX_QUESTION_CHARS) },
        { inline_data: { mime_type: mime, data: b64 } },
      ] }],
    });
    const req = https.request({
      hostname: GEMINI_HOST,
      path: '/v1beta/models/' + encodeURIComponent(model) + ':generateContent',
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': key, 'content-length': Buffer.byteLength(body) },
      timeout: REQUEST_TIMEOUT_MS,
    }, (res) => {
      let data = '';
      let aborted = false;
      res.on('data', (c) => {
        if (aborted) return;
        data += c;
        // 応答本文の暴走を防ぐ上限（既存 gemini-client と同思想）。
        if (data.length > MAX_RESPONSE_BYTES) { aborted = true; res.destroy(); }
      });
      res.on('end', () => {
        if (aborted) return resolve({ ok: false, status: res.statusCode, message: 'Gemini 応答が大きすぎます（上限超過）。' });
        let json = null; try { json = JSON.parse(data); } catch { /* below */ }
        if (!json) return resolve({ ok: false, status: res.statusCode, message: 'Gemini 応答を解釈できませんでした（HTTP ' + res.statusCode + '）。' });
        if (json.error) {
          const st = json.error.status || ('HTTP ' + res.statusCode);
          return resolve({ ok: false, status: res.statusCode, gstatus: st, message: 'Gemini 画像読取に失敗しました（' + st + '）。' });
        }
        const cand = (json.candidates && json.candidates[0]) || {};
        const text = ((cand.content && cand.content.parts) || []).map((p) => p.text || '').join('').trim();
        resolve({ ok: true, status: res.statusCode, text });
      });
    });
    req.on('error', (e) => resolve({ ok: false, status: 0, message: 'ネットワークエラー: ' + e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ ok: false, status: 0, message: 'Gemini 画像読取がタイムアウトしました。' }); });
    req.write(body);
    req.end();
  });
}

// 429/RESOURCE_EXHAUSTED は fallback モデルへ 1 回だけ切替。
async function describeImage(imagePath, question) {
  const img = readImage(imagePath);
  if (!img.ok) return { text: img.message, isError: true };
  let r = await callGemini(VISION_MODEL, question, img.mime, img.b64);
  if (!r.ok && (r.status === 429 || r.gstatus === 'RESOURCE_EXHAUSTED') && FALLBACK_MODEL && FALLBACK_MODEL !== VISION_MODEL) {
    r = await callGemini(FALLBACK_MODEL, question, img.mime, img.b64);
  }
  if (!r.ok) {
    let msg = r.message || 'Gemini 画像読取に失敗しました。';
    if (r.status === 429 || r.gstatus === 'RESOURCE_EXHAUSTED') {
      msg = 'Gemini 画像読取の無料クォータを超過しました（RESOURCE_EXHAUSTED）。しばらく時間をおいて再試行してください。';
    }
    return { text: msg, isError: true };
  }
  return { text: r.text || '(画像から読み取れる内容がありませんでした。)', isError: false };
}

// ---- MCP (JSON-RPC 2.0 over stdio, newline-delimited) ----------------------
const TOOL = {
  name: 'describe_image',
  description: '画像/スクリーンショットを Gemini に見せて、写っている内容や書かれている文字を'
    + '日本語テキストで説明・読み取る。d-claude(DeepSeek)は画像を直接見られないので、'
    + '画面のスクショ・図・エラー画面・写真などを「見て」欲しいときはこのツールを使う。'
    + '画像は Google(Gemini) に送信される。対応形式は PNG/JPEG/GIF/WebP/BMP。',
  inputSchema: {
    type: 'object',
    properties: {
      image_path: { type: 'string', description: '読み取りたい画像ファイルのパス（スクショの保存先など）。' },
      question: { type: 'string', description: '画像について特に知りたいこと（省略時は全体を説明）。例: 「エラーメッセージを正確に書き出して」' },
    },
    required: ['image_path'],
  },
};

function send(msg) { try { process.stdout.write(JSON.stringify(msg) + '\n'); } catch (_e) { /* stdout closed */ } }
function ok(id, result) { send({ jsonrpc: '2.0', id, result }); }
function err(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }); }

async function handle(msg) {
  if (!msg || msg.jsonrpc !== '2.0') return;
  const { id, method, params } = msg;
  const isNotification = (id === undefined || id === null);
  switch (method) {
    case 'initialize': {
      const proto = (params && params.protocolVersion) || DEFAULT_PROTOCOL;
      return ok(id, { protocolVersion: proto, capabilities: { tools: {} }, serverInfo: { name: SERVER_NAME, version: SERVER_VERSION } });
    }
    case 'notifications/initialized':
    case 'initialized':
      return;
    case 'ping':
      return ok(id, {});
    case 'tools/list':
      return ok(id, { tools: [TOOL] });
    case 'tools/call': {
      const name = params && params.name;
      const args = (params && params.arguments) || {};
      if (name !== 'describe_image') {
        if (!isNotification) err(id, -32602, 'Unknown tool: ' + name);
        return;
      }
      const imagePath = typeof args.image_path === 'string' ? args.image_path.trim() : '';
      const question = typeof args.question === 'string' ? args.question : '';
      const out = await describeImage(imagePath, question);
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
      try { msg = JSON.parse(line); } catch { continue; }
      Promise.resolve().then(() => handle(msg)).catch((e) => {
        if (msg && msg.id != null) err(msg.id, -32603, 'Internal error: ' + (e && e.message));
      });
    }
  });
  process.stdin.on('end', () => process.exit(0));
  process.stderr.write('[gemini-vision-mcp] ready (model=' + VISION_MODEL + ')\n');
}

if (require.main === module) main();

module.exports = { detectImageMime, readImage, describeImage, handle, TOOL };
