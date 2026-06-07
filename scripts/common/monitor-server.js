#!/usr/bin/env node
// monitor-server.js — AI コーチ・モニター（セッション中だけ動くローカルサーバ）
//
// 役割: 見守りモニターを file:// 表示から「双方向の AI コーチ」に拡張する。
//   - GET /        … コーチ UI（現在の操作カード + AI 解説 + 相談チャット）を配信
//   - GET /state   … 直近の操作（now.html から抽出した決定的解説）+ 直近イベントを JSON で返す
//   - POST /explain… 現コマンドを受講者の手元 CLI(claude -p / codex exec)に渡しやさしく解説
//   - POST /ask    … 受講者の自由質問（これ許可して大丈夫? 等）に AI が回答
//
// 安全方針:
//   - 127.0.0.1 のみ・ランダムポート・セッショントークン必須（外部公開しない）
//   - 検査対象コマンドは「データ」として AI プロンプトに埋めるだけ。サーバは絶対に実行しない
//   - AI 呼び出しは execFile（シェルを介さない=注入なし）。タイムアウト/出力上限あり
//   - AI 解説はあくまで「参考」。危険コマンドの自動ブロックと決定的解説（ガード側）は不変
//   - AI 不在/失敗時は決定的解説にフォールバック（モニターは壊れない）
//
// 常駐デーモンにはしない: モニターを開いている間だけ動き、ランチャー終了で止まる。

'use strict';

const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');

const LOG_DIR = process.env.AI_SAFE_LOG_DIR || path.join(os.homedir(), '.ai-safety', 'logs');
const TOKEN = process.env.AI_SAFE_MONITOR_TOKEN || crypto.randomBytes(16).toString('hex');
const HOST = '127.0.0.1';
const MAX_BODY = 16 * 1024;            // POST 本文上限（相談文）
const AI_TIMEOUT_MS = Number(process.env.AI_SAFE_COACH_TIMEOUT || 60000);
const REFRESH_MS = Number(process.env.AI_SAFE_MONITOR_INTERVAL || 1) * 1000;

// ---- AI バックエンド（受講者の手元 CLI を流用。新規キー不要） --------------
const BACKEND_DEFS = {
  claude: { cmd: 'claude', args: (p) => ['-p', p] },
  codex: { cmd: 'codex', args: (p) => ['exec', p] },
};
const BACKEND_ORDER = process.env.AI_SAFE_COACH_BACKEND
  ? [process.env.AI_SAFE_COACH_BACKEND]
  : ['claude', 'codex'];
let cachedBackend; // undefined=未試行, null=見つからない, {cmd,args}=確定

function tryBackend(def, prompt) {
  return new Promise((resolve) => {
    execFile(def.cmd, def.args(prompt), { timeout: AI_TIMEOUT_MS, maxBuffer: 1 << 20 }, (err, stdout) => {
      if (err) {
        if (err.code === 'ENOENT') return resolve({ enoent: true });
        return resolve({ ok: false });
      }
      resolve({ ok: true, text: String(stdout).trim() });
    });
  });
}

async function runAI(prompt) {
  if (cachedBackend) return tryBackend(cachedBackend, prompt);
  if (cachedBackend === null) return { ok: false, noBackend: true };
  for (const name of BACKEND_ORDER) {
    const def = BACKEND_DEFS[name];
    if (!def) continue;
    const r = await tryBackend(def, prompt);
    if (!r.enoent) { cachedBackend = def; return r; }
  }
  cachedBackend = null;
  return { ok: false, noBackend: true };
}

// ---- now.html から決定的解説を取り出す（explainer は一切変更しない） -------
function htmlUnescape(s) {
  return String(s)
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&');
}
function pickOne(html, re) { const m = html.match(re); return m ? htmlUnescape(m[1]).trim() : ''; }
function pickAll(html, re) { return [...html.matchAll(re)].map((m) => htmlUnescape(m[1]).trim()).filter(Boolean); }

function readState() {
  let html = '';
  try { html = fs.readFileSync(path.join(LOG_DIR, 'now.html'), 'utf8'); } catch { /* not yet */ }
  const state = {
    title: pickOne(html, /<div class="ctitle">([\s\S]*?)<\/div>/),
    meta: pickOne(html, /<div class="cmeta">([\s\S]*?)<\/div>/),
    cmd: pickOne(html, /<pre class="action-cmd">([\s\S]*?)<\/pre>/),
    label: pickOne(html, /<div class="action-label">([\s\S]*?)<\/div>/),
    whatdo: pickOne(html, /<p class="whatdo-body">([\s\S]*?)<\/p>/),
    dangers: pickAll(html, /<p class="whatdo-danger">([\s\S]*?)<\/p>/g),
    events: readEvents(8),
    hasCard: html.indexOf('class="action-cmd"') !== -1,
  };
  return state;
}

function localDate() {
  // ガード(audit_log)は `date +%F`＝ローカル日付でファイル名を作るので、それに合わせる。
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}

function readEvents(n) {
  try {
    const f = path.join(LOG_DIR, 'events-' + localDate() + '.jsonl');
    const lines = fs.readFileSync(f, 'utf8').trim().split('\n').filter(Boolean);
    return lines.slice(-n).reverse().map((l) => {
      try { const o = JSON.parse(l); return { ts: o.ts, mode: o.mode, decision: o.decision, reason: o.reason }; }
      catch { return null; }
    }).filter(Boolean);
  } catch { return []; }
}

// ---- プロンプト（やさしい・安全寄り・最終判断は人間） ----------------------
function clip(s, n) { s = String(s || ''); return s.length > n ? s.slice(0, n) + '…' : s; }

function explainPrompt(st) {
  return [
    'あなたはプログラミング初心者向けの、やさしい安全アドバイザーです。',
    '次に AI エージェントが実行しようとしているコマンドについて、専門用語をできるだけ避けて、日本語で短く説明してください。',
    '形式: ①これは何をするコマンドか（1〜2文）②気をつける点があれば一言 ③「許可してよいかの目安」を一言。',
    '重要: あなたの説明は参考情報です。最終判断は利用者本人が行います。安全だと断言して油断させないでください。',
    '',
    'コマンド: ' + clip(st.cmd, 2000),
    '操作の種類: ' + (st.label || '不明'),
    (st.whatdo ? '自動解析の結果: ' + clip(st.whatdo, 500) : ''),
    (st.dangers && st.dangers.length ? '自動検出された注意: ' + clip(st.dangers.join(' / '), 500) : ''),
  ].filter(Boolean).join('\n');
}

function askPrompt(st, question) {
  return [
    'あなたはプログラミング初心者向けの、やさしい安全アドバイザーです。日本語で、短く、専門用語を避けて答えてください。',
    '重要: あなたの回答は参考です。最終判断は利用者本人が行います。「絶対に安全」と断言して油断させないでください。あなたはコマンドを実行できません（説明だけ）。',
    '',
    'いま AI エージェントが実行しようとしているコマンド: ' + clip(st.cmd, 2000),
    '操作の種類: ' + (st.label || '不明'),
    (st.whatdo ? '自動解析の結果: ' + clip(st.whatdo, 500) : ''),
    (st.dangers && st.dangers.length ? '自動検出された注意: ' + clip(st.dangers.join(' / '), 500) : ''),
    '',
    '利用者からの質問: ' + clip(question, 1000),
  ].filter(Boolean).join('\n');
}

const AI_UNAVAILABLE = 'AI に今つながりませんでした（オフライン、または手元に claude / codex が見つかりません）。下の「自動の解説」を見て、不安なら許可しないでください。';

// ---- HTTP ------------------------------------------------------------------
function sendJson(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': body.length });
  res.end(body);
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', (c) => { size += c.length; if (size > MAX_BODY) { reject(new Error('body too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  let url;
  try { url = new URL(req.url, 'http://' + HOST); } catch { return sendJson(res, 400, { error: 'bad url' }); }
  // セッショントークン必須（CSRF/他ローカルプロセス対策）
  if (url.searchParams.get('t') !== TOKEN) { return sendJson(res, 401, { error: 'unauthorized' }); }

  if (req.method === 'GET' && url.pathname === '/') {
    const body = Buffer.from(renderPage(), 'utf8');
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': body.length });
    return res.end(body);
  }
  if (req.method === 'GET' && url.pathname === '/state') {
    return sendJson(res, 200, readState());
  }
  if (req.method === 'POST' && (url.pathname === '/explain' || url.pathname === '/ask')) {
    let payload = {};
    try { payload = JSON.parse(await readBody(req) || '{}'); } catch { return sendJson(res, 400, { error: 'bad json' }); }
    const st = readState();
    if (!st.cmd) return sendJson(res, 200, { ok: true, text: 'いま実行しようとしているコマンドが見つかりません。AI が操作を始めるとここに出ます。' });
    const prompt = url.pathname === '/ask'
      ? askPrompt(st, String(payload.question || '').slice(0, 1000))
      : explainPrompt(st);
    const r = await runAI(prompt);
    if (r.ok) return sendJson(res, 200, { ok: true, text: r.text });
    return sendJson(res, 200, { ok: false, text: AI_UNAVAILABLE });
  }
  return sendJson(res, 404, { error: 'not found' });
});

server.on('error', (e) => {
  console.error('monitor-server: listen failed: ' + (e && e.message ? e.message : e));
  process.exit(1);
});

const URL_FILE = path.join(LOG_DIR, 'monitor-url.txt');
function cleanup() { try { fs.unlinkSync(URL_FILE); } catch { /* ignore */ } }
process.on('SIGINT', () => { cleanup(); process.exit(0); });
process.on('SIGTERM', () => { cleanup(); process.exit(0); });
process.on('exit', cleanup);

server.listen(0, HOST, () => {
  const port = server.address().port;
  const url = 'http://' + HOST + ':' + port + '/?t=' + TOKEN;
  // ランチャーがこの行(または URL_FILE)を読んで URL をブラウザで開く。
  console.log('AI_SAFE_MONITOR_URL=' + url);
  try { fs.mkdirSync(LOG_DIR, { recursive: true }); fs.writeFileSync(URL_FILE, url); } catch { /* ignore */ }
});

// ---- コーチ UI（1ファイル完結。AI 出力は textContent で表示=XSS安全） -----
function renderPage() {
  return `<!DOCTYPE html>
<html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AI コーチ・モニター</title>
<style>
*{box-sizing:border-box}
body{margin:0;padding:16px;font-family:'Yu Gothic','Meiryo',sans-serif;background:#0f1115;color:#e6e6e6;word-break:keep-all;line-height:1.7}
.wrap{max-width:880px;margin:0 auto}
h1.hdr{font-size:18px;margin:0 0 14px;color:#9ad}
.card{border-radius:12px;padding:18px 20px;margin-bottom:16px;border-left:8px solid #3fb950;background:#15241a}
.card.high{border-left-color:#e5534b;background:#2a1718}
.card.medium{border-left-color:#e0b341;background:#2a2417}
.card.wait{border-left-color:#6e7681;background:#1a1d24}
.ctitle{font-size:22px;font-weight:700;margin:0 0 6px}
.cmeta{font-size:12px;opacity:.7;margin-bottom:10px}
.action-cmd{margin:0;font-family:monospace,'Courier New';font-size:14px;color:#f0c080;white-space:pre-wrap;word-break:break-all;overflow-wrap:anywhere;background:#0d0f13;border-radius:8px;padding:10px}
.whatdo{margin-top:10px}
.whatdo .lab{font-weight:700;color:#cfd;font-size:14px}
.danger{color:#ffb3ad}
.coach{border-radius:12px;padding:16px 18px;background:#14171d;border:1px solid #2a2f3a}
.coach h2{font-size:15px;margin:0 0 10px;color:#9ad}
.btns{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px}
button{font-family:inherit;font-size:14px;padding:8px 14px;border-radius:8px;border:1px solid #3a4150;background:#222834;color:#e6e6e6;cursor:pointer}
button:hover{background:#2c3543}
button:disabled{opacity:.5;cursor:default}
.qrow{display:flex;gap:8px}
.qrow input{flex:1;font-family:inherit;font-size:14px;padding:8px 10px;border-radius:8px;border:1px solid #3a4150;background:#0d0f13;color:#e6e6e6}
.answer{margin-top:12px;white-space:pre-wrap;background:#0d0f13;border-radius:8px;padding:12px;min-height:1.5em;border:1px solid #222}
.disclaim{font-size:12px;color:#e0b341;margin-top:10px}
.events{margin-top:16px;font-size:12px;opacity:.8}
.events table{border-collapse:collapse;width:100%}
.events td{border-top:1px solid #222;padding:4px 6px}
.muted{opacity:.6}
</style></head>
<body><div class="wrap">
<h1 class="hdr">🤖 AI コーチ・モニター — いま AI がやろうとしていること</h1>
<div id="card" class="card wait"><div class="ctitle">待機中…</div><div class="cmeta">AI が操作を始めると、ここに内容が出ます。</div></div>

<div class="coach">
  <h2>🧑‍🏫 AI コーチに相談する</h2>
  <div class="btns">
    <button id="b-explain">このコマンドをやさしく説明して</button>
    <button id="b-ok">これ、許可して大丈夫？</button>
  </div>
  <div class="qrow">
    <input id="q" type="text" placeholder="自由に質問（例: これを実行すると何が消える？）" />
    <button id="b-ask">聞く</button>
  </div>
  <div id="answer" class="answer muted">ボタンを押すと、手元の AI が日本語で答えます。</div>
  <div class="disclaim">⚠️ AI の回答は「参考」です。最終的に許可するかは、あなた自身が決めてください。あやしい時は許可しないのが安全です。</div>
</div>

<div class="events"><div class="muted">直近の出来事</div><table id="events"></table></div>
</div>
<script>
const T = new URLSearchParams(location.search).get('t');
const $ = (id) => document.getElementById(id);
let lastCmd = null;

function riskClass(meta){ if(/risk=high/.test(meta))return'high'; if(/risk=medium/.test(meta))return'medium'; return ''; }

async function poll(){
  try{
    const r = await fetch('/state?t='+encodeURIComponent(T));
    if(!r.ok) return;
    const s = await r.json();
    const card = $('card');
    if(!s.hasCard){ card.className='card wait'; card.innerHTML=''; const a=document.createElement('div'); a.className='ctitle'; a.textContent='待機中…'; const b=document.createElement('div'); b.className='cmeta'; b.textContent='AI が操作を始めると、ここに内容が出ます。'; card.append(a,b); }
    else {
      card.className = 'card ' + riskClass(s.meta||'');
      card.innerHTML='';
      const t=document.createElement('div'); t.className='ctitle'; t.textContent=s.title||'操作'; card.append(t);
      const m=document.createElement('div'); m.className='cmeta'; m.textContent=s.meta||''; card.append(m);
      if(s.cmd){ const pre=document.createElement('pre'); pre.className='action-cmd'; pre.textContent=s.cmd; card.append(pre); }
      if(s.whatdo){ const w=document.createElement('div'); w.className='whatdo'; const l=document.createElement('div'); l.className='lab'; l.textContent='📂 これは何をする？（自動解析）'; const p=document.createElement('div'); p.textContent=s.whatdo; w.append(l,p); card.append(w); }
      (s.dangers||[]).forEach(d=>{ const p=document.createElement('div'); p.className='danger'; p.textContent=d; card.append(p); });
    }
    // コマンドが変わったら回答欄をリセット
    if(s.cmd !== lastCmd){ lastCmd=s.cmd; const ans=$('answer'); ans.className='answer muted'; ans.textContent='ボタンを押すと、手元の AI が日本語で答えます。'; }
    // events
    const tb=$('events'); tb.innerHTML='';
    (s.events||[]).forEach(e=>{ const tr=document.createElement('tr'); const icon=e.decision==='block'?'⛔':(e.decision==='allow'?'✅':'•'); [ (e.ts||'').replace('T',' ').replace('Z',''), icon+' '+(e.decision||''), e.mode||'', e.reason||'' ].forEach(v=>{const td=document.createElement('td');td.textContent=v;tr.append(td);}); tb.append(tr); });
  }catch(e){}
}

async function callAI(pathname, body){
  const ans=$('answer'); ans.className='answer'; ans.textContent='🤖 AI に聞いています…';
  [...document.querySelectorAll('button')].forEach(b=>b.disabled=true);
  try{
    const r = await fetch(pathname+'?t='+encodeURIComponent(T), {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body||{})});
    const j = await r.json();
    ans.textContent = j.text || '(応答なし)';
    ans.className = 'answer' + (j.ok===false ? ' danger' : '');
  }catch(e){ ans.textContent='AI 呼び出しに失敗しました。'; ans.className='answer danger'; }
  finally{ [...document.querySelectorAll('button')].forEach(b=>b.disabled=false); }
}

$('b-explain').onclick = ()=>callAI('/explain',{});
$('b-ok').onclick = ()=>callAI('/ask',{question:'このコマンドを許可しても大丈夫ですか？初心者にもわかるように、安全なら理由、危険なら何が起きるかを教えてください。'});
$('b-ask').onclick = ()=>{ const q=$('q').value.trim(); if(q) callAI('/ask',{question:q}); };
$('q').addEventListener('keydown', (e)=>{ if(e.key==='Enter'){ const q=$('q').value.trim(); if(q) callAI('/ask',{question:q}); }});

poll(); setInterval(poll, ${REFRESH_MS});
</script>
</body></html>`;
}
