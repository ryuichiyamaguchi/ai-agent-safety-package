#!/usr/bin/env node
// agy-image-mcp.js — 依存ゼロの最小 MCP サーバー（stdio）。
//
// 目的:
//   d-claude（DeepSeek 駆動の Claude Code）に「日本語文字入り・高品質の画像生成」を与える。
//   Pollinations（sana）は文字なし画像は得意だが日本語文字が崩れる。agy（Antigravity CLI）は
//   受講者自身の Google アカウント OAuth で無料の画像生成（Gemini 系 Nano Banana）が使え、
//   「新発売」等の日本語文字を正しく描ける（実測で確認）。生の Gemini API キーは画像 limit:0
//   だが、agy の OAuth 経路は別枠で無料枠がアカウントごとに付く（13 人同時でも取り合いにならない）。
//
// 仕組み:
//   agy にはヘッドレスの単発実行モード `agy -p "<prompt>"` がある。これを子プロセスで実行すると
//   agy が画像を ~/.gemini/antigravity-cli/brain/<conv>/ に保存する。呼び出し前の時刻を記録して
//   おき、実行後にその時刻より新しい画像を brain から拾ってワークスペースへ回収する（mac の
//   zshrc ラッパーがやっている回収を MCP 内で行う）。tmux も常駐 TUI も不要。
//
// 設計方針:
//   - 依存ゼロ（純 Node）。API キー不要（agy は Google アカウントでログイン済み前提）。
//   - agy 未ログイン / 生成失敗 / タイムアウトは例外で落とさず MCP のエラー応答として返す。
//   - 生成画像はワークスペース配下 generated-images/ に保存し、保存先パスを返す。
//   - Pollinations の generate_image と役割分担: 文字なし＝Pollinations（速い）、
//     日本語文字入り・ポスター・図解＝この generate_image_agy（品質高いが 1 枚 20 秒前後）。
//
// MCP stdio 転送: JSON-RPC 2.0 メッセージを「改行区切り」で送受信（1 行 1 メッセージ）。
'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const SERVER_NAME = 'agy-image';
const SERVER_VERSION = '1.0.0';
const DEFAULT_PROTOCOL = '2025-06-18';
const IS_WIN = process.platform === 'win32';
const AGY_TIMEOUT_MS = Number(process.env.AI_SAFE_AGY_TIMEOUT || 180000);
const MAX_PROMPT_CHARS = 1500;

function brainDir() {
  return process.env.AI_SAFE_AGY_BRAIN || path.join(os.homedir(), '.gemini', 'antigravity-cli', 'brain');
}
function outputDir() {
  return process.env.AI_SAFE_IMAGE_DIR || path.join(process.cwd(), 'generated-images');
}

function safeName(name) {
  let s = String(name == null ? '' : name).trim();
  s = s.replace(/\.(jpe?g|png|webp|gif)$/i, '');
  s = s.replace(/[^A-Za-z0-9_-]/g, '');
  if (!s) s = 'agy-' + process.pid;
  return s.slice(0, 60);
}

// brain ディレクトリ配下を再帰的に走査し、mtime が since 以降の画像ファイルを集める。
// 依存を避けるため readdirSync の手動再帰（古い Node でも動く）。
const IMG_RE = /\.(png|jpe?g|webp|gif)$/i;
function findImagesSince(dir, sinceMs, acc, depth) {
  if (depth > 6) return; // 念のため深さ制限
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    try {
      if (e.isDirectory()) {
        findImagesSince(full, sinceMs, acc, depth + 1);
      } else if (e.isFile() && IMG_RE.test(e.name)) {
        const st = fs.statSync(full);
        if (st.mtimeMs >= sinceMs) acc.push({ path: full, mtimeMs: st.mtimeMs });
      }
    } catch { /* 消えた/権限等はスキップ */ }
  }
}

// agy 実行ファイルを解決する。env 上書き優先。既定は PATH 上の 'agy'（Windows は agy.exe を探す）。
function resolveAgyBin() {
  if (process.env.AI_SAFE_AGY_BIN) return process.env.AI_SAFE_AGY_BIN;
  const pathVar = process.env.PATH || process.env.Path || '';
  const dirs = pathVar.split(IS_WIN ? ';' : ':').filter(Boolean);
  const names = IS_WIN ? ['agy.exe', 'agy.cmd', 'agy.bat', 'agy'] : ['agy'];
  for (const d of dirs) {
    for (const n of names) {
      const p = path.join(d, n);
      try { if (fs.statSync(p).isFile()) return p; } catch { /* next */ }
    }
  }
  return 'agy'; // 見つからなければ PATH 解決に任せる
}

// Windows の .cmd/.bat を shell:true 無しで安全に起動するためのエスケープ。shell:true は引数を
// 無エスケープで連結するため & や | でコマンドインジェクションになる（DEP0190 / CVE-2024-27980）。
// 2 層エスケープ（argv 解析用の \ と " 処理 → cmd.exe メタ文字を ^ で無害化。.cmd/.bat は %* 経由で
// 二重解釈されるので二重エスケープ）で、& や | を含む日本語プロンプトも 1 引数として agy に渡る。
// cross-spawn と同一手法。
const WIN_META_RE = /([()[\]%!^"`<>&|;, *?])/g;
function winEscapeCommand(cmd) {
  return String(cmd).replace(WIN_META_RE, '^$1');
}
function winEscapeArgument(arg, doubleEscape) {
  arg = String(arg);
  arg = arg.replace(/(\\*)"/g, '$1$1\\"'); // " の前の \ 列を倍化して " をエスケープ
  arg = arg.replace(/(\\*)$/, '$1$1');      // 末尾の \ 列を倍化
  arg = '"' + arg + '"';                     // 全体を " で囲む
  arg = arg.replace(WIN_META_RE, '^$1');     // cmd.exe メタ文字を ^ で無害化
  if (doubleEscape) arg = arg.replace(WIN_META_RE, '^$1');
  return arg;
}

// agy -p を子プロセスで実行。プロンプトは引数で渡す（stdin 非対応を実測済み）。
// 返り値: { ok, code, stderr }
function runAgy(agyPrompt) {
  return new Promise((resolve) => {
    const bin = resolveAgyBin();
    // .cmd/.bat は CreateProcess で直接起動できず cmd.exe が要るが、shell:true は使わない（上記の
    // インジェクション対策）。エスケープ済みコマンド行を cmd.exe に渡し windowsVerbatimArguments で
    // 二重処理を防ぐ。exe/ネイティブ（mac 含む）は shell なしで直接起動（libuv が引数を安全に quoting）。
    const isBatch = IS_WIN && /\.(cmd|bat)$/i.test(bin);
    let file, spawnArgs, spawnOpts;
    if (isBatch) {
      const line = [winEscapeCommand(bin), winEscapeArgument('-p', true), winEscapeArgument(agyPrompt, true)].join(' ');
      file = process.env.ComSpec || process.env.COMSPEC || 'cmd.exe';
      spawnArgs = ['/d', '/s', '/c', '"' + line + '"'];
      spawnOpts = { shell: false, windowsVerbatimArguments: true, windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] };
    } else {
      file = bin;
      spawnArgs = ['-p', agyPrompt];
      spawnOpts = { shell: false, windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] };
    }
    let child;
    try {
      child = spawn(file, spawnArgs, spawnOpts);
    } catch (e) {
      return resolve({ ok: false, code: -1, stderr: 'agy を起動できませんでした: ' + e.message });
    }
    let stderr = '';
    let done = false;
    const finish = (r) => { if (!done) { done = true; resolve(r); } };
    const timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch { /* */ }
      finish({ ok: false, code: -2, stderr: 'agy がタイムアウトしました（' + Math.round(AGY_TIMEOUT_MS / 1000) + '秒）。' });
    }, AGY_TIMEOUT_MS);
    if (child.stderr) child.stderr.on('data', (c) => { if (stderr.length < 8192) stderr += c.toString('utf8'); });
    child.on('error', (e) => { clearTimeout(timer); finish({ ok: false, code: -1, stderr: 'agy 実行エラー: ' + e.message }); });
    child.on('close', (code) => { clearTimeout(timer); finish({ ok: code === 0, code, stderr }); });
  });
}

// 生成 → 回収 → 保存。成功: { ok:true, filePath, bytes }  失敗: { ok:false, message }
async function generate(args) {
  const prompt = typeof args.prompt === 'string' ? args.prompt.trim() : '';
  if (!prompt) return { ok: false, message: 'prompt が空です。作りたい画像の内容を指定してください。' };

  // agy に「画像を 1 枚生成する」ことを明示。文字は指定どおり正確にと促す。
  const agyPrompt = '次の内容の画像を1枚だけ生成してください（画像生成ツールを使い、指定された文字は正確に描く）。'
    + '画像以外の作業はしないでください。内容: ' + prompt.slice(0, MAX_PROMPT_CHARS);

  // 呼び出し前時刻（数秒のスキュー余裕を引く）。この時刻以降の新規画像を回収対象にする。
  const sinceMs = Date.now() - 3000;
  const r = await runAgy(agyPrompt);

  // 実行が非 0 でも、画像が生成されていれば拾う（agy は補足メッセージを stderr に出すことがある）。
  const found = [];
  findImagesSince(brainDir(), sinceMs, found, 0);
  if (found.length === 0) {
    let msg = 'agy が画像を生成しませんでした。';
    if (!r.ok && r.stderr) {
      msg += ' 詳細: ' + r.stderr.trim().slice(0, 300);
    }
    msg += '（agy に未ログインの可能性があります。一度 agy-safe を起動してログインしてください。）';
    return { ok: false, message: msg };
  }
  // 最新（mtime 最大）を採用。
  found.sort((a, b) => b.mtimeMs - a.mtimeMs);
  const src = found[0].path;

  const dir = outputDir();
  try { fs.mkdirSync(dir, { recursive: true }); } catch (e) { return { ok: false, message: '保存先を作成できませんでした: ' + e.message }; }
  const ext = (path.extname(src) || '.jpg').toLowerCase();
  const dest = path.join(dir, safeName(args.filename) + ext);
  try { fs.copyFileSync(src, dest); } catch (e) { return { ok: false, message: '画像の保存に失敗しました: ' + e.message }; }
  let bytes = 0;
  try { bytes = fs.statSync(dest).size; } catch { /* */ }
  return { ok: true, filePath: dest, bytes };
}

// ---- MCP (JSON-RPC 2.0 over stdio, newline-delimited) ----------------------
const TOOL = {
  name: 'generate_image_agy',
  description:
    '日本語などの文字入り・高品質の画像生成（agy / Gemini 画像）。ポスター・告知物・図解・'
    + 'バナーなど「画像内に文字を正しく入れたい」ときや高品質が必要なときに使う。生成画像を'
    + 'ワークスペースの generated-images/ に保存しパスを返す。受講者自身の Google アカウントで'
    + '無料。1 枚 20 秒前後かかる。文字が不要な背景・写真・イラストを速く作るだけなら '
    + 'generate_image（Pollinations）の方が速い。',
  inputSchema: {
    type: 'object',
    properties: {
      prompt: { type: 'string', description: '作りたい画像の説明。画像内に入れたい文字（日本語可）も具体的に書く。' },
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
      return;
    case 'ping':
      return ok(id, {});
    case 'tools/list':
      return ok(id, { tools: [TOOL] });
    case 'tools/call': {
      const name = params && params.name;
      const args = (params && params.arguments) || {};
      if (name !== 'generate_image_agy') {
        if (!isNotification) err(id, -32602, 'Unknown tool: ' + name);
        return;
      }
      const r = await generate(args);
      if (!r.ok) {
        return ok(id, { content: [{ type: 'text', text: r.message }], isError: true });
      }
      const text = '画像を生成しました: ' + r.filePath + '（' + r.bytes + ' bytes, agy/Gemini・日本語文字対応）';
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
      try { msg = JSON.parse(line); } catch { continue; }
      Promise.resolve().then(() => handle(msg)).catch((e) => {
        if (msg && msg.id != null) err(msg.id, -32603, 'Internal error: ' + (e && e.message));
      });
    }
  });
  process.stdin.on('end', () => process.exit(0));
  process.stderr.write('[agy-image-mcp] ready (brain=' + brainDir() + ')\n');
}

if (require.main === module) main();

module.exports = { generate, runAgy, resolveAgyBin, winEscapeCommand, winEscapeArgument, findImagesSince, safeName, handle, TOOL };
