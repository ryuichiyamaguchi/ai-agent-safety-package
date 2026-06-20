#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const repo = path.resolve(__dirname, '..', '..', '..');
const helper = path.join(repo, 'scripts', 'common', 'answer-snapshot.js');
const policy = path.join(repo, 'policy', 'safety-policy.json');

function run(input, logDir) {
  return spawnSync(process.execPath, [helper], {
    input: JSON.stringify(input),
    encoding: 'utf8',
    env: {
      ...process.env,
      AI_SAFE_LOG_DIR: logDir,
      AI_SAFE_POLICY: policy,
    },
  });
}

function readSnapshot(logDir) {
  return JSON.parse(fs.readFileSync(path.join(logDir, 'latest-answer.json'), 'utf8'));
}

function main() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'answer-snapshot-test-'));
  const logDir = path.join(tmp, 'logs');
  fs.mkdirSync(logDir, { recursive: true });

  try {
    const tool = run({
      hook_event_name: 'PostToolUse',
      tool_name: 'Bash',
      content: 'tool output is not an assistant answer',
    }, logDir);
    assert.equal(tool.status, 0);
    assert.equal(fs.existsSync(path.join(logDir, 'latest-answer.json')), false, 'PostToolUse tool output must not become AI answer');

    const direct = run({
      hook_event_name: 'AfterModel',
      name: 'gemini-model-response',
      content: '回答です。api_key: "your-placeholder-value-here"',
    }, logDir);
    assert.equal(direct.status, 0);
    const directSnapshot = readSnapshot(logDir);
    assert.equal(directSnapshot.available, true);
    assert.match(directSnapshot.text, /回答です/);
    assert.match(directSnapshot.text, /\[REDACTED:Generic sensitive assignment\]/, 'saved answer should be redacted');

    const transcript = path.join(tmp, 'transcript.jsonl');
    fs.writeFileSync(transcript, [
      JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: '古い回答' }] } }),
      JSON.stringify({ type: 'user', message: { content: '質問' } }),
      JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: '新しい回答です' }] } }),
      '',
    ].join('\n'), 'utf8');
    const fromTranscript = run({ hook_event_name: 'Stop', transcript_path: transcript }, logDir);
    assert.equal(fromTranscript.status, 0);
    const transcriptSnapshot = readSnapshot(logDir);
    assert.equal(transcriptSnapshot.available, true);
    assert.equal(transcriptSnapshot.transcript, true);
    assert.match(transcriptSnapshot.text, /新しい回答です/);
    assert.doesNotMatch(transcriptSnapshot.text, /古い回答/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

main();
