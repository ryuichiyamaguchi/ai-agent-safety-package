#!/usr/bin/env node
// playwright-mcp.js — Playwright MCP サーバー（@playwright/mcp）の起動ラッパー。
//
// 目的:
//   OpenCode / d-claude に Playwright（ブラウザ自動操作・UIテスト・スクレイピング）を提供する。
//   Microsoft 公式の @playwright/mcp を stdio モードで起動し、入出力を中継する。
//
// 起動のしかた（上から順に試す）:
//   1. 事前に入れた版（~/.ai-safety/tools/playwright-mcp）を node で直接起動する。
//      ネットワークを一切使わないので、教室で一斉に起動しても時間切れにならない。
//      事前に入れるのは「AIツールをまとめて入れる」ボタン（playwright-prefetch.js）。
//   2. 事前に入れていなければ npx で起動する。このとき版を固定する（@playwright/mcp@<版>）。
//      版を書かない `npx -y @playwright/mcp` は、ダウンロード済みでも起動のたびに
//      「最新版はどれか」をレジストリへ問い合わせるため、教室の回線で一斉に起動すると
//      MCP の起動待ちを超えて時間切れになる（2026-10 実機で発生）。
//
// ブラウザ:
//   @playwright/mcp は既定で PC に入っている Google Chrome を使う。Windows で Chrome が
//   無い PC は、必ず入っている Microsoft Edge を使う（ブラウザの追加ダウンロードを避ける）。
//
// 設計方針:
//   - 依存ゼロ（標準ライブラリのみ）。
//   - stdin / stdout をそのままパイプし、stdio MCP として動作させる。
//   - どんな失敗も例外で落とさず適切に終了する。
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const PACKAGE = '@playwright/mcp';
// tested-tool-versions.json が読めないときの版（SSOT は tested-tool-versions.json の playwrightMcp）。
const FALLBACK_VERSION = '0.0.83';

// 事前に入れる場所。作業フォルダごとではなく利用者ごとに 1 つ（どの作業フォルダからも使う）。
function toolsDir(home = os.homedir()) {
  return path.join(home, '.ai-safety', 'tools', 'playwright-mcp');
}

// 動作確認済みの版。作業フォルダ配置（.ai-safety/hooks/common → .ai-safety/）と
// リポジトリ直実行（scripts/common → configs/）の両方を探す。
function pinnedVersion(dir = __dirname) {
  const candidates = [
    path.join(dir, '..', '..', 'tested-tool-versions.json'),
    path.join(dir, '..', '..', 'configs', 'tested-tool-versions.json'),
  ];
  for (const f of candidates) {
    try {
      const v = JSON.parse(fs.readFileSync(f, 'utf8')).playwrightMcp;
      if (typeof v === 'string' && /^[0-9][0-9A-Za-z.\-]*$/.test(v)) return v;
    } catch { /* 次の候補へ */ }
  }
  return FALLBACK_VERSION;
}

// 事前に入れた版の cli.js。版が一致しないもの・壊れたもの（途中で失敗した導入）は使わない。
function localCli(version, home = os.homedir()) {
  const pkgDir = path.join(toolsDir(home), 'node_modules', '@playwright', 'mcp');
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(pkgDir, 'package.json'), 'utf8'));
    const cli = path.join(pkgDir, 'cli.js');
    if (pkg.version === version && fs.statSync(cli).isFile()) return cli;
  } catch { /* 未導入 */ }
  return null;
}

function hasChromeOnWindows(env = process.env) {
  const bases = [env.ProgramFiles, env['ProgramFiles(x86)'], env.LOCALAPPDATA].filter(Boolean);
  return bases.some((b) => {
    try { return fs.statSync(path.join(b, 'Google', 'Chrome', 'Application', 'chrome.exe')).isFile(); } catch { return false; }
  });
}

// 利用者が --browser も PLAYWRIGHT_MCP_BROWSER も指定しておらず、Windows で Chrome が無いときだけ Edge にする。
function browserArgs(userArgs, { platform = process.platform, env = process.env, hasChrome } = {}) {
  if (platform !== 'win32') return [];
  if (userArgs.some((a) => a === '--browser' || a.startsWith('--browser='))) return [];
  if (env.PLAYWRIGHT_MCP_BROWSER) return [];
  const chrome = typeof hasChrome === 'boolean' ? hasChrome : hasChromeOnWindows(env);
  return chrome ? [] : ['--browser', 'msedge'];
}

// 起動するコマンドを決める（テストのため副作用なし）。
function plan({ userArgs = [], platform = process.platform, env = process.env, home = os.homedir(), dir = __dirname, hasChrome } = {}) {
  const version = pinnedVersion(dir);
  const extra = [...browserArgs(userArgs, { platform, env, hasChrome }), ...userArgs];
  const cli = localCli(version, home);
  if (cli) {
    return { mode: 'local', version, command: process.execPath, args: [cli, ...extra], shell: false };
  }
  return {
    mode: 'npx',
    version,
    command: platform === 'win32' ? 'npx.cmd' : 'npx',
    args: ['--prefer-offline', '-y', `${PACKAGE}@${version}`, ...extra],
    shell: platform === 'win32',
  };
}

function main() {
  const p = plan({ userArgs: process.argv.slice(2) });
  const child = spawn(p.command, p.args, {
    stdio: ['inherit', 'inherit', 'inherit'],
    shell: p.shell,
    env: process.env,
  });

  child.on('error', (err) => {
    process.stderr.write(`[playwright-mcp] Failed to start ${PACKAGE} (${p.mode}): ${err.message}\n`);
    process.exit(1);
  });

  child.on('exit', (code, signal) => {
    if (signal) {
      process.kill(process.pid, signal);
    } else {
      process.exit(code ?? 0);
    }
  });
}

module.exports = { PACKAGE, FALLBACK_VERSION, toolsDir, pinnedVersion, localCli, browserArgs, plan };

if (require.main === module) {
  main();
}
