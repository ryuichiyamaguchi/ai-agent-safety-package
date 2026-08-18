#!/usr/bin/env node
// playwright-mcp.js — Playwright MCP サーバー（@playwright/mcp）の起動ラッパー。
//
// 目的:
//   OpenCode / d-claude に Playwright（ブラウザ自動操作・UIテスト・スクレイピング）を提供する。
//   Microsoft 公式の @playwright/mcp を stdio モードで起動し、入出力を中継する。
//
// 設計方針:
//   - 依存ゼロ（標準ライブラリの child_process のみ）。
//   - Windows / macOS の両方で npx 経由で @playwright/mcp を実行する。
//   - stdin / stdout をそのままパイプし、stdio MCP として動作させる。
//   - どんな失敗も例外で落とさず適切に終了する。
'use strict';

const { spawn } = require('node:child_process');

const npxCmd = process.platform === 'win32' ? 'npx.cmd' : 'npx';
const args = ['-y', '@playwright/mcp'];

if (process.argv.length > 2) {
  args.push(...process.argv.slice(2));
}

const child = spawn(npxCmd, args, {
  stdio: ['inherit', 'inherit', 'inherit'],
  shell: process.platform === 'win32',
  env: process.env,
});

child.on('error', (err) => {
  process.stderr.write(`[playwright-mcp] Failed to start @playwright/mcp: ${err.message}\n`);
  process.exit(1);
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
  } else {
    process.exit(code ?? 0);
  }
});
