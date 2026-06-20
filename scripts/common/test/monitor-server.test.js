#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const repo = path.resolve(__dirname, '..', '..', '..');
const serverPath = path.join(repo, 'scripts', 'common', 'monitor-server.js');

function waitForUrl(proc) {
  return new Promise((resolve, reject) => {
    let out = '';
    const timer = setTimeout(() => reject(new Error('monitor-server did not print URL')), 5000);
    proc.stdout.on('data', (chunk) => {
      out += chunk.toString('utf8');
      const m = out.match(/AI_SAFE_MONITOR_URL=(http:\/\/127[.]0[.]0[.]1:\d+\/\?t=[a-f0-9]+)/);
      if (m) {
        clearTimeout(timer);
        resolve(m[1]);
      }
    });
    proc.on('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`monitor-server exited before URL (code=${code})`));
    });
  });
}

function requestJson(url, pathname, body) {
  return fetch(new URL(pathname + url.search, url.origin), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
  }).then((res) => res.json());
}

function promptOnlyNowHtml() {
  return [
    '<!doctype html><html><body>',
    '<div class="ctitle">ユーザープロンプト</div>',
    '<div class="cmeta">2026-06-18 10:00:00 ・ tool=prompt ・ risk=low ・ card=default-prompt</div>',
    '<div class="action-label">プロンプト</div>',
    '<pre class="action-cmd">Webで最新情報を調べてください</pre>',
    '</body></html>',
  ].join('\n');
}

function observeNowHtml() {
  return [
    '<!doctype html><html><body>',
    '<div class="ctitle">安全イベント</div>',
    '<div class="cmeta">2026-06-18 10:01:00 ・ tool=observe ・ risk=low ・ card=default-observe</div>',
    '<div class="action-label">Read</div>',
    '<pre class="action-cmd">Read: docs/README.md</pre>',
    '</body></html>',
  ].join('\n');
}

function latestAnswerJson() {
  return JSON.stringify({
    version: 1,
    ts: '2026-06-18T10:02:00.000Z',
    source: 'Stop',
    transcript: true,
    available: true,
    reason: '',
    text: 'この操作は README を確認するだけです。ただし、内容を確認してから進めてください。',
  }, null, 2);
}

async function main() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'monitor-server-test-'));
  const env = {
    ...process.env,
    HOME: tmp,
    AI_SAFE_LOG_DIR: tmp,
    AI_SAFE_MONITOR_INTERVAL: '1',
    GEMINI_API_KEY: '',
    GOOGLE_API_KEY: '',
  };
  const proc = spawn(process.execPath, [serverPath], {
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  try {
    const rawUrl = await waitForUrl(proc);
    const url = new URL(rawUrl);
    const page = await fetch(rawUrl).then((res) => res.text());
    assert.match(page, /安全イベント \/ AI回答モニター/, 'page title should expose both monitor targets');
    assert.match(page, /AI回答/, 'page should include the AI answer tab');
    assert.match(page, /検索や会話の中身は表示されない場合があります/, 'page should disclose monitor coverage limits');

    fs.writeFileSync(path.join(tmp, 'now.html'), promptOnlyNowHtml(), 'utf8');
    const promptState = await fetch(new URL('/state' + url.search, url.origin)).then((res) => res.json());
    assert.equal(promptState.coachable, false, 'prompt-only cards are not coachable');
    const reply = await requestJson(url, '/ask', { question: 'これを許可していい？' });
    assert.equal(reply.ok, true);
    assert.match(reply.text, /この画面では判断材料がありません/, 'prompt-only cards should not call Gemini');
    assert.doesNotMatch(reply.text, /Gemini API キーが未設定/, 'prompt-only cards must not require Gemini');

    fs.writeFileSync(path.join(tmp, 'now.html'), observeNowHtml(), 'utf8');
    const observeState = await fetch(new URL('/state' + url.search, url.origin)).then((res) => res.json());
    assert.equal(observeState.coachable, true, 'concrete safety-event cards should be coachable');

    fs.writeFileSync(path.join(tmp, 'latest-answer.json'), latestAnswerJson(), 'utf8');
    const answerState = await fetch(new URL('/state' + url.search, url.origin)).then((res) => res.json());
    assert.equal(answerState.answer.coachable, true, 'captured AI answers should be coachable');
    assert.match(answerState.answer.text, /README を確認/);

    const answerReply = await requestJson(url, '/ask', { target: 'answer', question: 'この回答で進めていい？' });
    assert.equal(answerReply.ok, false, 'answer target should call Gemini when answer context exists');
    assert.match(answerReply.text, /Gemini API キーが未設定/, 'answer target should reach Gemini key check instead of no-context fallback');
  } finally {
    proc.kill('SIGTERM');
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : err);
  process.exit(1);
});
