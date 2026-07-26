import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = path.resolve(import.meta.dirname, '..', '..', '..');
const pluginUrl = pathToFileURL(path.join(root, 'scripts', 'common', 'opencode-bouncer-monitor.mjs')).href;

test('OpenCode permission events create and resolve a Bouncer approval card without leaking secrets', async (t) => {
  const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencode-bouncer-monitor-'));
  t.after(() => fs.rmSync(logDir, { recursive: true, force: true }));

  const previousLogDir = process.env.AI_SAFE_LOG_DIR;
  process.env.AI_SAFE_LOG_DIR = logDir;
  t.after(() => {
    if (previousLogDir === undefined) delete process.env.AI_SAFE_LOG_DIR;
    else process.env.AI_SAFE_LOG_DIR = previousLogDir;
  });

  const { BouncerApprovalMonitor } = await import(pluginUrl);
  const hooks = await BouncerApprovalMonitor({ directory: '/work/customer-project' });
  const ready = JSON.parse(fs.readFileSync(path.join(logDir, 'opencode-monitor-ready.json'), 'utf8'));
  assert.equal(ready.status, 'ready');
  assert.equal(ready.directory, '/work/customer-project');

  await hooks.event({
    event: {
      id: 'evt-asked',
      type: 'permission.asked',
      properties: {
        id: 'permission-123',
        sessionID: 'session-456',
        permission: 'bash',
        patterns: ['npm install example-package --token=private-token-value'],
        metadata: {
          command: 'npm install example-package --token=private-token-value',
          apiKey: 'sk-ant-' + 'A'.repeat(32),
        },
        always: ['npm install *'],
        tool: { messageID: 'message-1', callID: 'call-1' },
      },
    },
  });

  const approvalFile = path.join(logDir, 'opencode-approval.json');
  const pending = JSON.parse(fs.readFileSync(approvalFile, 'utf8'));
  assert.equal(pending.status, 'pending');
  assert.equal(pending.requestID, 'permission-123');
  assert.equal(pending.tool, 'bash');
  assert.equal(pending.detail, 'npm install example-package --token=[REDACTED]');
  assert.equal(pending.directory, '/work/customer-project');
  assert.doesNotMatch(JSON.stringify(pending), /sk-ant-|private-token-value/);
  assert.doesNotMatch(JSON.stringify(pending), /session-456|message-1|call-1/);

  await hooks.event({
    event: {
      id: 'evt-replied',
      type: 'permission.replied',
      properties: {
        sessionID: 'session-456',
        requestID: 'permission-123',
        reply: 'once',
      },
    },
  });

  const resolved = JSON.parse(fs.readFileSync(approvalFile, 'utf8'));
  assert.equal(resolved.status, 'resolved');
  assert.equal(resolved.reply, 'once');

  const audit = fs.readFileSync(path.join(logDir, `events-${new Date().toLocaleDateString('sv-SE')}.jsonl`), 'utf8');
  assert.match(audit, /OpenCodeの承認待ち/);
  assert.match(audit, /今回だけ許可/);
  assert.doesNotMatch(audit, /sk-ant-|private-token-value|session-456|message-1|call-1/);
  const auditRows = audit.trim().split('\n').map((line) => JSON.parse(line));
  const observed = JSON.parse(auditRows[0].observed);
  assert.equal(observed.tool_name, 'bash');
  assert.equal(observed.tool_input.command, 'npm install example-package --token=[REDACTED]');
});

test('OpenCodeの長いコマンドを履歴用に途中で切らない', async (t) => {
  const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencode-bouncer-long-command-'));
  t.after(() => fs.rmSync(logDir, { recursive: true, force: true }));
  const previousLogDir = process.env.AI_SAFE_LOG_DIR;
  process.env.AI_SAFE_LOG_DIR = logDir;
  t.after(() => {
    if (previousLogDir === undefined) delete process.env.AI_SAFE_LOG_DIR;
    else process.env.AI_SAFE_LOG_DIR = previousLogDir;
  });

  const { BouncerApprovalMonitor } = await import(pluginUrl);
  const hooks = await BouncerApprovalMonitor({ directory: '/work/customer-project' });
  const command = `printf '${'x'.repeat(1500)}' LONG_COMMAND_END`;
  await hooks.event({
    event: {
      type: 'permission.asked',
      properties: { id: 'long-command', permission: 'bash', metadata: { command } },
    },
  });

  const pending = JSON.parse(fs.readFileSync(path.join(logDir, 'opencode-approval.json'), 'utf8'));
  assert.equal(pending.detail, command);
  const audit = fs.readFileSync(path.join(logDir, `events-${new Date().toLocaleDateString('sv-SE')}.jsonl`), 'utf8');
  assert.match(audit, /LONG_COMMAND_END/, '履歴にもコマンド末尾を残す');
});
