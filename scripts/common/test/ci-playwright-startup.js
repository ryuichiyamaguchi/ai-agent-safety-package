#!/usr/bin/env node
// ci-playwright-startup.js — Playwright MCP が「事前に入れた版」で、ネットワーク無しに起動できるかを確かめる。
//
// CI（windows-latest）と手元の両方で使う。教室で一斉に起動すると時間切れになった問題（2026-10）の
// 回帰検知用。手順:
//   1. playwright-prefetch.js --check が「未準備」を返す（まっさらな HOME で実行する前提）
//   2. playwright-prefetch.js で事前に入れる
//   3. --check が「準備済み」を返す
//   4. npm のレジストリを到達不能にした状態で playwright-mcp.js を起動し、MCP initialize に応答すること
// 使い方: node scripts/common/test/ci-playwright-startup.js   （HOME / USERPROFILE は呼び出し側で空の場所に向ける）
'use strict';

const { spawn, spawnSync } = require('node:child_process');
const path = require('node:path');

const common = path.join(__dirname, '..');
const prefetch = path.join(common, 'playwright-prefetch.js');
const wrapper = path.join(common, 'playwright-mcp.js');

function step(name, ok, detail = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ' — ' + detail : ''}`);
  if (!ok) process.exitCode = 1;
  return ok;
}

function run(args) {
  return spawnSync(process.execPath, args, { encoding: 'utf8', env: process.env });
}

function initialize(timeoutMs) {
  return new Promise((resolve) => {
    const env = { ...process.env, npm_config_registry: 'http://127.0.0.1:9/' };
    const child = spawn(process.execPath, [wrapper], { env, stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    let err = '';
    const t0 = Date.now();
    const timer = setTimeout(() => { child.kill(); resolve({ ok: false, ms: Date.now() - t0, out, err: err + ' (timeout)' }); }, timeoutMs);
    child.stdout.on('data', (d) => {
      out += d.toString();
      if (out.includes('"serverInfo"')) {
        clearTimeout(timer);
        child.kill();
        resolve({ ok: true, ms: Date.now() - t0, out, err });
      }
    });
    child.stderr.on('data', (d) => { err += d.toString(); });
    child.on('exit', () => { clearTimeout(timer); resolve({ ok: out.includes('"serverInfo"'), ms: Date.now() - t0, out, err }); });
    child.stdin.write(JSON.stringify({
      jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'ci', version: '1' } },
    }) + '\n');
  });
}

(async () => {
  const pre = run([prefetch, '--check']);
  step('before prefetch: --check reports not installed', pre.status === 1, (pre.stdout || '').trim());

  const t0 = Date.now();
  const pf = run([prefetch]);
  step('prefetch installs the pinned @playwright/mcp', pf.status === 0, `${Date.now() - t0} ms`);
  if (pf.status !== 0) console.log(pf.stdout, pf.stderr);

  const post = run([prefetch, '--check']);
  step('after prefetch: --check reports installed', post.status === 0, (post.stdout || '').trim());

  const r = await initialize(30000);
  step('MCP answers initialize with the registry unreachable (no network)', r.ok, `${r.ms} ms`);
  if (!r.ok) console.log('stdout:', r.out.slice(0, 500), '\nstderr:', r.err.slice(0, 1500));
})();
