#!/usr/bin/env node
// codex-image-mcp.js — 依存ゼロの最小 MCP サーバー（stdio）。
//
// 目的:
//   OpenCode / d-claude に「GPT-Image-2 による高品質の画像生成」を与える。
//   同梱の agy-image（実体は Gemini 系 Nano Banana）より画質が良いという実測にもとづく追加で、
//   agy-image を置き換えるものではない（用途で選べるように 3 本並べる）。
//
// 仕組み（agy-image-mcp.js と同じ作り。呼ぶ相手が agy → codex に変わるだけ）:
//   Codex CLI には非対話の単発実行 `codex exec "<prompt>"` があり、`--enable image_generation`
//   を付けると内蔵の画像生成ツール（gpt-image-2）が使える。生成物は Codex 側の
//   ~/.codex/generated_images/<セッションID>/ に保存されるので、呼び出し前の時刻を記録して
//   おき、実行後にその時刻より新しい画像を拾ってワークスペースへ回収する。
//
// 設計方針:
//   - 依存ゼロ（純 Node）。**API キー不要**（codex は ChatGPT のサブスクリプションでログイン済み前提）。
//   - codex 未ログイン / 生成失敗 / タイムアウトは例外で落とさず MCP のエラー応答として返す。
//   - 生成画像はワークスペース配下 generated-images/ に保存し、保存先パスを返す。
//     保存先は必ずこのフォルダ配下に閉じる（ファイル名に .. や / が来ても外へ書けない）。
//   - codex は `--sandbox read-only` で起動する。画像生成は Codex 本体（ホスト側）が行うので
//     read-only でも成立し、万一モデルがシェルを使おうとしても書き込みが一切できない。
//
// 安全上の注意（docs/90_守れる-守れない.md に明記）:
//   プロンプトは Codex 経由でそのまま OpenAI へ送られる。**DeepSeek 向けの送信検査 Gateway は
//   通らない**（gemini-search / gemini-vision / pollinations-image / agy-image / buffer と同じ構造）。
//
// codex-safe シムを経由しない理由:
//   codex-safe（= launch-codex-safe.sh / .ps1）は対話 TUI を開く起動口で、標準入出力を MCP の
//   JSON-RPC に使うこの経路からは呼べない（TUI が stdio を奪う）。そのかわり、この MCP は
//   codex-safe と同じ「壁」を自前で明示する: --sandbox read-only（codex-safe は workspace-write
//   なので、こちらのほうが狭い）+ 作業フォルダの外へは 1 バイトも書かない回収処理。
//
// MCP stdio 転送: JSON-RPC 2.0 メッセージを「改行区切り」で送受信（1 行 1 メッセージ）。
'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const SERVER_NAME = 'codex-image';
const SERVER_VERSION = '1.0.0';
const DEFAULT_PROTOCOL = '2025-06-18';
const IS_WIN = process.platform === 'win32';
// 1 枚あたり実測 50 秒前後（推論の設定次第でもっとかかる）。agy-image（180 秒）より長めに取る。
const CODEX_TIMEOUT_MS = Number(process.env.AI_SAFE_CODEX_IMAGE_TIMEOUT || 240000);
const MAX_PROMPT_CHARS = 1500;

// Codex が生成画像を置く場所。CODEX_HOME を尊重する（既定は ~/.codex）。
function generatedImagesDir() {
  if (process.env.AI_SAFE_CODEX_IMAGE_HOME) return process.env.AI_SAFE_CODEX_IMAGE_HOME;
  const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
  return path.join(codexHome, 'generated_images');
}
function outputDir() {
  return process.env.AI_SAFE_IMAGE_DIR || path.join(process.cwd(), 'generated-images');
}

function safeName(name) {
  let s = String(name == null ? '' : name).trim();
  s = s.replace(/\.(jpe?g|png|webp|gif)$/i, '');
  s = s.replace(/[^A-Za-z0-9_-]/g, '');
  if (!s) s = 'gpt-image-' + process.pid;
  return s.slice(0, 60);
}

// 生成画像の置き場を再帰的に走査し、mtime が since 以降の画像ファイルを集める。
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

// codex 実行ファイルを解決する。env 上書き優先。既定は PATH 上の 'codex'（Windows は .cmd 等も探す）。
function resolveCodexBin() {
  if (process.env.AI_SAFE_CODEX_BIN) return process.env.AI_SAFE_CODEX_BIN;
  const pathVar = process.env.PATH || process.env.Path || '';
  const dirs = pathVar.split(IS_WIN ? ';' : ':').filter(Boolean);
  const names = IS_WIN ? ['codex.exe', 'codex.cmd', 'codex.bat', 'codex'] : ['codex'];
  for (const d of dirs) {
    for (const n of names) {
      const p = path.join(d, n);
      try { if (fs.statSync(p).isFile()) return p; } catch { /* next */ }
    }
  }
  return 'codex'; // 見つからなければ PATH 解決に任せる
}

// Windows の .cmd/.bat を shell:true 無しで安全に起動するためのエスケープ。shell:true は引数を
// 無エスケープで連結するため & や | でコマンドインジェクションになる（DEP0190 / CVE-2024-27980）。
// 2 層エスケープ（argv 解析用の \ と " 処理 → cmd.exe メタ文字を ^ で無害化。.cmd/.bat は %* 経由で
// 二重解釈されるので二重エスケープ）で、& や | を含む日本語プロンプトも 1 引数として codex に渡る。
// cross-spawn と同一手法。agy-image-mcp.js と同じ実装を、この MCP 1 本だけで完結させるために
// 意図的に持っている（1 本消えても他が壊れないという「MCP は各自で完結」の作りを崩さない）。
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

// codex exec に渡す固定の引数（プロンプト以外）。
//   exec                     非対話の単発実行（TUI を開かない）
//   --enable image_generation 画像生成ツールを明示的に有効化（学習者の設定に依存しない）
//   --skip-git-repo-check    git 管理下でない作業フォルダでも動かす
//   -s read-only             モデルが動かすシェルには一切書かせない（画像生成はホスト側の機能）
//   -C <cwd>                 作業フォルダを固定する
function codexArgs(prompt, cwd) {
  return ['exec', '--enable', 'image_generation', '--skip-git-repo-check', '-s', 'read-only', '-C', cwd, prompt];
}

// codex exec を子プロセスで実行。返り値: { ok, code, stderr }
function runCodex(prompt, cwd) {
  return new Promise((resolve) => {
    const bin = resolveCodexBin();
    // .cmd/.bat は CreateProcess で直接起動できず cmd.exe が要るが、shell:true は使わない（上記の
    // インジェクション対策）。エスケープ済みコマンド行を cmd.exe に渡し windowsVerbatimArguments で
    // 二重処理を防ぐ。exe/ネイティブ（mac 含む）は shell なしで直接起動（libuv が引数を安全に quoting）。
    const isBatch = IS_WIN && /\.(cmd|bat)$/i.test(bin);
    const argv = codexArgs(prompt, cwd);
    let file, spawnArgs, spawnOpts;
    if (isBatch) {
      const line = [winEscapeCommand(bin)]
        .concat(argv.map((a) => winEscapeArgument(a, true)))
        .join(' ');
      file = process.env.ComSpec || process.env.COMSPEC || 'cmd.exe';
      spawnArgs = ['/d', '/s', '/c', '"' + line + '"'];
      spawnOpts = { shell: false, windowsVerbatimArguments: true, windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] };
    } else {
      file = bin;
      spawnArgs = argv;
      spawnOpts = { shell: false, windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] };
    }
    let child;
    try {
      child = spawn(file, spawnArgs, spawnOpts);
    } catch (e) {
      return resolve({ ok: false, code: -1, stderr: 'codex を起動できませんでした: ' + e.message });
    }
    let stderr = '';
    let done = false;
    const finish = (r) => { if (!done) { done = true; resolve(r); } };
    const timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch { /* */ }
      finish({ ok: false, code: -2, stderr: 'codex がタイムアウトしました（' + Math.round(CODEX_TIMEOUT_MS / 1000) + '秒）。' });
    }, CODEX_TIMEOUT_MS);
    if (child.stderr) child.stderr.on('data', (c) => { if (stderr.length < 8192) stderr += c.toString('utf8'); });
    child.on('error', (e) => { clearTimeout(timer); finish({ ok: false, code: -1, stderr: 'codex 実行エラー: ' + e.message }); });
    child.on('close', (code) => { clearTimeout(timer); finish({ ok: code === 0, code, stderr }); });
  });
}

// 保存先が必ず出力フォルダの中に収まることを確かめる（.. や絶対パスを混ぜられても外へ出さない）。
// safeName() が英数 _ - 以外を落とすので二重の防御だが、保存先の決定はここ 1 箇所に閉じる。
function resolveDest(dir, name, ext) {
  const base = path.resolve(dir);
  const dest = path.resolve(base, safeName(name) + ext);
  const rel = path.relative(base, dest);
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) {
    throw new Error('保存先が作業フォルダの外を指しています');
  }
  return dest;
}

// 生成 → 回収 → 保存。成功: { ok:true, filePath, bytes }  失敗: { ok:false, message }
async function generate(args) {
  const prompt = typeof args.prompt === 'string' ? args.prompt.trim() : '';
  if (!prompt) return { ok: false, message: 'prompt が空です。作りたい画像の内容を指定してください。' };

  // codex に「画像を 1 枚生成する」ことを明示。文字は指定どおり正確にと促す。
  const codexPrompt = '次の内容の画像を1枚だけ生成してください（画像生成ツールを使い、指定された文字は正確に描く）。'
    + '画像以外の作業はしないでください（ファイルの作成・編集・コマンド実行は不要です）。内容: '
    + prompt.slice(0, MAX_PROMPT_CHARS);

  // 呼び出し前時刻（数秒のスキュー余裕を引く）。この時刻以降の新規画像を回収対象にする。
  const sinceMs = Date.now() - 3000;
  const r = await runCodex(codexPrompt, process.cwd());

  // 実行が非 0 でも、画像が生成されていれば拾う（codex は補足メッセージを stderr に出すことがある）。
  const found = [];
  findImagesSince(generatedImagesDir(), sinceMs, found, 0);
  if (found.length === 0) {
    let msg = 'codex が画像を生成しませんでした。';
    if (!r.ok && r.stderr) {
      msg += ' 詳細: ' + r.stderr.trim().slice(0, 300);
    }
    msg += '（codex に未ログインの可能性があります。一度 codex-safe を起動して ChatGPT でログインしてください。）';
    return { ok: false, message: msg };
  }
  // 最新（mtime 最大）を採用。
  found.sort((a, b) => b.mtimeMs - a.mtimeMs);
  const src = found[0].path;

  const dir = outputDir();
  try { fs.mkdirSync(dir, { recursive: true }); } catch (e) { return { ok: false, message: '保存先を作成できませんでした: ' + e.message }; }
  const ext = (path.extname(src) || '.png').toLowerCase();
  let dest;
  try { dest = resolveDest(dir, args.filename, ext); } catch (e) { return { ok: false, message: e.message }; }
  try { fs.copyFileSync(src, dest); } catch (e) { return { ok: false, message: '画像の保存に失敗しました: ' + e.message }; }
  let bytes = 0;
  try { bytes = fs.statSync(dest).size; } catch { /* */ }
  return { ok: true, filePath: dest, bytes };
}

// ---- MCP (JSON-RPC 2.0 over stdio, newline-delimited) ----------------------
const TOOL = {
  name: 'generate_image_gpt',
  description:
    '高品質の画像生成（GPT-Image-2 / Codex 経由）。同梱の画像生成 3 本のうち一番きれいに'
    + '仕上がる。ポスター・告知物・図解・バナーなど仕上がりの質を優先したいときに使う。'
    + '生成画像をワークスペースの generated-images/ に保存しパスを返す。'
    + 'ChatGPT のサブスクリプションを使うので API キーは不要。1 枚 1 分前後かかる。'
    + '速さ優先で文字の要らない画像なら generate_image（Pollinations）、'
    + 'Google アカウントの無料枠で作るなら generate_image_agy を使う。'
    + '【送信先の注意】プロンプトはそのまま OpenAI へ送られる（DeepSeek 向けの送信検査は通らない）。'
    + '【重要・トークン節約】生成後に画像ファイルを Read ツールで開かないこと（base64 として'
    + 'ローカルのコンテキストに載りトークンを大量消費する。d-claude では gateway が DeepSeek 送信前に'
    + '画像を捨てるうえ DeepSeek は画像を見られないため、Read した分は完全な無駄になる）。'
    + '内容を確認したいときは describe_image を使う。',
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
      if (name !== 'generate_image_gpt') {
        if (!isNotification) err(id, -32602, 'Unknown tool: ' + name);
        return;
      }
      const r = await generate(args);
      if (!r.ok) {
        return ok(id, { content: [{ type: 'text', text: r.message }], isError: true });
      }
      const text = '画像を生成しました: ' + r.filePath + '（' + r.bytes + ' bytes, GPT-Image-2 / Codex）';
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
  process.stderr.write('[codex-image-mcp] ready (images=' + generatedImagesDir() + ')\n');
}

if (require.main === module) main();

module.exports = {
  generate, runCodex, resolveCodexBin, codexArgs, resolveDest,
  winEscapeCommand, winEscapeArgument, findImagesSince, safeName, handle, TOOL,
  generatedImagesDir, outputDir,
};
