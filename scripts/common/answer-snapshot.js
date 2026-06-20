#!/usr/bin/env node
// answer-snapshot.js — AI の最終回答をモニター用に保存する best-effort helper。
//
// guard-post-output から stdin に hook JSON を受け取り、AI 回答本文を取れた時だけ
// latest-answer.json に保存する。PostToolUse のツール出力は回答ではないので保存しない。

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const MAX_INPUT = 262144;
const MAX_TEXT = 12000;
const LOG_DIR = process.env.AI_SAFE_LOG_DIR || path.join(os.homedir(), '.ai-safety', 'logs');
const OUT = path.join(LOG_DIR, 'latest-answer.json');
const D_CLAUDE_MARKER_FRESH_MS = 12 * 60 * 60 * 1000;

function readStdin() {
  try {
    const buf = fs.readFileSync(0);
    return buf.toString('utf8').slice(0, MAX_INPUT);
  } catch {
    return '';
  }
}

function parseJson(s) {
  try { return JSON.parse(s); } catch { return null; }
}

function valueAt(o, names) {
  if (!o || typeof o !== 'object') return undefined;
  for (const name of names) {
    if (Object.prototype.hasOwnProperty.call(o, name) && o[name] != null) return o[name];
  }
  return undefined;
}

function eventName(o) {
  return String(valueAt(o, ['hook_event_name', 'hookEventName', 'eventName', 'event', 'type']) || '');
}

function hasToolName(o) {
  return !!valueAt(o, ['tool_name', 'toolName', 'tool_input', 'toolInput']);
}

function shouldCapture(o) {
  const ev = eventName(o).toLowerCase();
  if (hasToolName(o)) return false;
  if (/posttool|aftertool|pretool|beforetool|permissionrequest|userprompt/.test(ev)) return false;
  if (/stop|aftermodel|afteragent/.test(ev)) return true;
  return !!extractDirectText(o);
}

function isDClaudeSession() {
  if (process.env.DS_CLAUDE_MODE === '1') return true;
  try {
    const marker = path.join(LOG_DIR, 'coach-engine');
    const stat = fs.statSync(marker);
    if (Date.now() - stat.mtimeMs > D_CLAUDE_MARKER_FRESH_MS) return false;
    return fs.readFileSync(marker, 'utf8').trim() === 'd-claude';
  } catch {
    return false;
  }
}

function textFromContent(v) {
  if (v == null) return '';
  if (typeof v === 'string') return v;
  if (Array.isArray(v)) return v.map(textFromContent).filter(Boolean).join('\n');
  if (typeof v !== 'object') return '';
  if (typeof v.text === 'string') return v.text;
  if (typeof v.content === 'string') return v.content;
  if (typeof v.output_text === 'string') return v.output_text;
  if (typeof v.value === 'string' && String(v.type || '').toLowerCase() === 'text') return v.value;
  return '';
}

function extractDirectText(o) {
  if (!o || typeof o !== 'object') return '';
  const msg = valueAt(o, ['message', 'response', 'result', 'output']);
  const candidates = [
    valueAt(o, ['content', 'text', 'answer', 'assistant_response', 'assistantResponse', 'final_response', 'last_message']),
    msg && valueAt(msg, ['content', 'text', 'output_text']),
    msg && msg.message && valueAt(msg.message, ['content', 'text']),
  ];
  for (const c of candidates) {
    const text = textFromContent(c).trim();
    if (text) return text;
  }
  return '';
}

function extractAssistantFromRecord(o) {
  if (!o || typeof o !== 'object') return '';
  const role = String(valueAt(o, ['role']) || valueAt(o.message, ['role']) || '').toLowerCase();
  const type = String(valueAt(o, ['type']) || '').toLowerCase();
  if (role && role !== 'assistant') return '';
  if (!role && type && !/assistant/.test(type)) return '';
  return (
    textFromContent(valueAt(o, ['content', 'text'])) ||
    textFromContent(o.message && valueAt(o.message, ['content', 'text'])) ||
    textFromContent(o.response && valueAt(o.response, ['content', 'text', 'output_text']))
  ).trim();
}

function extractTranscriptText(transcriptPath) {
  if (!transcriptPath || typeof transcriptPath !== 'string') return '';
  let data = '';
  try {
    const stat = fs.statSync(transcriptPath);
    if (!stat.isFile() || stat.size > 20 * 1024 * 1024) return '';
    data = fs.readFileSync(transcriptPath, 'utf8');
  } catch {
    return '';
  }

  let latest = '';
  for (const line of data.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const rec = parseJson(line);
    const text = extractAssistantFromRecord(rec);
    if (text) latest = text;
  }
  return latest;
}

function policyPath() {
  const candidates = [];
  if (process.env.AI_SAFE_POLICY) candidates.push(process.env.AI_SAFE_POLICY);
  if (process.env.AI_SAFE_ROOT) candidates.push(path.join(process.env.AI_SAFE_ROOT, 'policy', 'safety-policy.json'));
  candidates.push(path.join(process.cwd(), '.ai-safety', 'policy', 'safety-policy.json'));
  candidates.push(path.join(os.homedir(), '.ai-safety', 'policy', 'safety-policy.json'));
  candidates.push(path.join(__dirname, '..', '..', 'policy', 'safety-policy.json'));
  candidates.push(path.join(__dirname, '..', '..', '..', 'policy', 'safety-policy.json'));
  for (const p of candidates) {
    try { if (p && fs.existsSync(p)) return p; } catch { /* ignore */ }
  }
  return '';
}

function toRegExp(pattern) {
  let flags = 'g';
  let pat = String(pattern || '');
  if (pat.startsWith('(?i)')) {
    flags += 'i';
    pat = pat.slice(4);
  }
  pat = pat
    .replace(/\[\[:space:\]\]/g, '\\s')
    .replace(/\[\[:digit:\]\]/g, '\\d')
    .replace(/\[\[:alpha:\]\]/g, '[A-Za-z]')
    .replace(/\[\[:alnum:\]\]/g, '[A-Za-z0-9]');
  try { return new RegExp(pat, flags); } catch { return null; }
}

function loadSecretPatterns() {
  const p = policyPath();
  if (!p) return [];
  try {
    const policy = JSON.parse(fs.readFileSync(p, 'utf8'));
    return Array.isArray(policy.secretRegex) ? policy.secretRegex : [];
  } catch {
    return [];
  }
}

function redact(text) {
  let out = String(text || '');
  for (const item of loadSecretPatterns()) {
    const re = toRegExp(item && item.pattern);
    if (!re) continue;
    out = out.replace(re, `[REDACTED:${item.name || 'secret'}]`);
  }
  return out.length > MAX_TEXT ? out.slice(0, MAX_TEXT) + '...[truncated]' : out;
}

function writeSnapshot(obj) {
  fs.mkdirSync(LOG_DIR, { recursive: true, mode: 0o700 });
  const tmp = OUT + '.tmp.' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, OUT);
  try { fs.chmodSync(OUT, 0o600); } catch { /* ignore */ }
}

function main() {
  const raw = readStdin();
  const input = parseJson(raw) || {};
  if (!shouldCapture(input)) return;
  if (isDClaudeSession()) return;

  const transcriptPath = valueAt(input, ['transcript_path', 'transcriptPath']);
  const direct = extractDirectText(input);
  const transcript = extractTranscriptText(transcriptPath);
  const text = transcript || direct;

  const base = {
    version: 1,
    ts: new Date().toISOString(),
    source: eventName(input) || 'post-output',
    transcript: !!transcript,
  };

  if (!text.trim()) {
    writeSnapshot({
      ...base,
      available: false,
      reason: 'AI 回答本文を hook 入力または transcript から取得できませんでした。',
      text: '',
    });
    return;
  }

  writeSnapshot({
    ...base,
    available: true,
    reason: '',
    text: redact(text),
  });
}

try { main(); } catch { process.exit(0); }
