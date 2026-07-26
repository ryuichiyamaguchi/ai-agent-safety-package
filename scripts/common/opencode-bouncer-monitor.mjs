import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const MAX_FIELD = 1200;
const MAX_DETAIL = 12000;

function localDate() {
  const now = new Date();
  const part = (value) => String(value).padStart(2, '0');
  return `${now.getFullYear()}-${part(now.getMonth() + 1)}-${part(now.getDate())}`;
}

function sanitize(value, maxLength = MAX_FIELD) {
  return String(value == null ? '' : value)
    .replace(/\b(?:sk-ant-|sk-proj-|sk-live-|AIza|ghp_|github_pat_)[A-Za-z0-9_.-]{8,}\b/g, '[REDACTED]')
    .replace(/\b(api[_-]?key|token|password|secret)\s*[:=]\s*[^\s,;]+/gi, '$1=[REDACTED]')
    .slice(0, maxLength);
}

function eventProperties(event) {
  return event && typeof event === 'object'
    ? (event.properties || event.data || {})
    : {};
}

function detailFrom(properties) {
  const metadata = properties && typeof properties.metadata === 'object' ? properties.metadata : {};
  for (const key of ['command', 'filePath', 'filepath', 'path', 'url', 'query', 'description']) {
    if (typeof metadata[key] === 'string' && metadata[key].trim()) return sanitize(metadata[key].trim(), MAX_DETAIL);
  }
  const patterns = Array.isArray(properties.patterns)
    ? properties.patterns
    : (Array.isArray(properties.pattern) ? properties.pattern : [properties.pattern]);
  const detail = patterns.filter((item) => typeof item === 'string' && item.trim()).join(' / ');
  return sanitize(detail || properties.permission || properties.type || '内容を取得できない操作', MAX_DETAIL);
}

function writeJsonAtomic(file, value) {
  const temp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
  fs.renameSync(temp, file);
}

function appendAudit(logDir, value) {
  const file = path.join(logDir, `events-${localDate()}.jsonl`);
  fs.appendFileSync(file, `${JSON.stringify(value)}\n`, { encoding: 'utf8', mode: 0o600 });
}

function observed(tool, detail) {
  return JSON.stringify({
    hook_event_name: 'OpenCodePermission',
    tool_name: tool,
    tool_input: { command: detail },
  });
}

export const BouncerApprovalMonitor = async ({ directory }) => {
  const logDir = process.env.AI_SAFE_LOG_DIR || path.join(os.homedir(), '.ai-safety', 'logs');
  const approvalFile = path.join(logDir, 'opencode-approval.json');
  fs.mkdirSync(logDir, { recursive: true, mode: 0o700 });
  writeJsonAtomic(path.join(logDir, 'opencode-monitor-ready.json'), {
    version: 1,
    ts: new Date().toISOString(),
    status: 'ready',
    directory: sanitize(directory),
  });

  return {
    event: async ({ event }) => {
      if (!event || (event.type !== 'permission.asked' && event.type !== 'permission.replied')) return;
      const properties = eventProperties(event);
      const now = new Date().toISOString();

      if (event.type === 'permission.asked') {
        const requestID = sanitize(properties.id || properties.requestID || properties.permissionID || '');
        const tool = sanitize(properties.permission || properties.type || 'unknown');
        const detail = detailFrom(properties);
        writeJsonAtomic(approvalFile, {
          version: 1,
          ts: now,
          status: 'pending',
          requestID,
          tool,
          detail,
          directory: sanitize(directory),
        });
        appendAudit(logDir, {
          ts: now,
          mode: 'opencode-approval',
          decision: 'ask',
          reason: 'OpenCodeの承認待ち',
          observed: observed(tool, detail),
        });
        return;
      }

      let current = {};
      try { current = JSON.parse(fs.readFileSync(approvalFile, 'utf8')); } catch { /* missing card */ }
      const requestID = sanitize(properties.requestID || properties.permissionID || '');
      if (current.requestID && requestID && current.requestID !== requestID) return;
      const reply = sanitize(properties.reply || properties.response || 'unknown');
      const detail = sanitize(current.detail || '承認操作', MAX_DETAIL);
      const tool = sanitize(current.tool || 'unknown');
      writeJsonAtomic(approvalFile, {
        ...current,
        version: 1,
        ts: now,
        status: 'resolved',
        reply,
      });
      const labels = { once: '今回だけ許可', always: '常に許可', reject: '許可しない' };
      appendAudit(logDir, {
        ts: now,
        mode: 'opencode-approval',
        decision: reply === 'reject' ? 'block' : 'allow',
        reason: labels[reply] || 'OpenCodeで回答済み',
        observed: observed(tool, detail),
      });
    },
  };
};
