'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..', '..', '..');
const serverPath = path.join(root, 'scripts', 'common', 'monitor-server.js');

function waitForUrl(proc) {
  return new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => reject(new Error('monitor-server did not start')), 5000);
    proc.stdout.on('data', (chunk) => {
      output += chunk.toString('utf8');
      const match = output.match(/AI_SAFE_MONITOR_URL=(http:\/\/127[.]0[.]0[.]1:\d+\/\?t=[a-f0-9]+)/);
      if (!match) return;
      clearTimeout(timer);
      resolve(match[1]);
    });
    proc.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`monitor-server exited early (${code})`));
    });
  });
}

test('Bouncer state shows a pending OpenCode approval instead of a stale Claude card', async (t) => {
  const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencode-monitor-server-'));
  t.after(() => fs.rmSync(logDir, { recursive: true, force: true }));

  fs.writeFileSync(path.join(logDir, 'now.html'), [
    '<div class="ctitle">古いClaudeカード</div>',
    '<div class="cmeta">tool=Read ・ risk=low</div>',
    '<div class="action-label">Read</div>',
    '<pre class="action-cmd">stale.txt</pre>',
  ].join('\n'));
  fs.writeFileSync(path.join(logDir, 'opencode-approval.json'), JSON.stringify({
    version: 1,
    ts: new Date().toISOString(),
    status: 'pending',
    requestID: 'approval-1',
    tool: 'bash',
    detail: 'npm install example-package',
    directory: '/work/project',
  }));
  const date = new Date().toLocaleDateString('sv-SE');
  const firstCommand = 'grep -r "mcp\\|image\\|MCP\\|generate_image\\|codex-image" ~/.claude/ --include="*.json" -l 2>/dev/null | head -20';
  const secondCommand = 'git status --short';
  fs.writeFileSync(path.join(logDir, `events-${date}.jsonl`), [
    JSON.stringify({
      ts: new Date().toISOString(),
      mode: 'opencode',
      decision: 'ask',
      reason: 'OpenCodeの承認待ち',
      observed: JSON.stringify({ hook_event_name: 'OpenCodePermission', tool_name: 'bash', tool_input: { command: firstCommand } }),
    }),
    JSON.stringify({
      ts: new Date(Date.now() + 1000).toISOString(),
      mode: 'opencode',
      decision: 'ask',
      reason: 'OpenCodeの承認待ち',
      observed: JSON.stringify({ hook_event_name: 'OpenCodePermission', tool_name: 'bash', tool_input: { command: secondCommand } }),
    }),
  ].join('\n') + '\n');

  const proc = spawn(process.execPath, [serverPath], {
    env: {
      ...process.env,
      AI_SAFE_AGENT: 'opencode',
      AI_SAFE_LOG_DIR: logDir,
      AI_SAFE_MONITOR_INTERVAL: '1',
      GEMINI_API_KEY: '',
      GOOGLE_API_KEY: '',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => proc.kill('SIGTERM'));

  const rawUrl = await waitForUrl(proc);
  const url = new URL(rawUrl);
  const state = await fetch(new URL(`/state${url.search}`, url.origin)).then((res) => res.json());

  assert.equal(state.hasCard, true);
  assert.equal(state.title, 'OpenCode が承認を求めています');
  assert.equal(state.cmd, 'npm install example-package');
  assert.equal(state.profile.agent, 'opencode');
  assert.doesNotMatch(JSON.stringify(state), /古いClaudeカード|stale[.]txt/);
  assert.equal(state.approval.status, 'review');
  assert.equal(state.events.length, 2, '履歴には検知した各コマンドを残す');
  const grepEvent = state.events.find((event) => event.command === firstCommand);
  assert.ok(grepEvent, '履歴APIは省略していない完全なコマンドを返す');
  assert.match(grepEvent.meaning, /[.]claude.*JSON.*検索/, '履歴APIはコマンドの意味も返す');
  assert.match(grepEvent.impact, /変更しません/);
  assert.match(grepEvent.outbound, /送信しません/);

  const page = await fetch(rawUrl).then((res) => res.text());
  assert.match(page, /全コマンドを開いて見返せます/, '履歴の再閲覧機能を案内する');
  assert.match(page, /history-detail/, '各履歴を展開するUIを備える');
});
