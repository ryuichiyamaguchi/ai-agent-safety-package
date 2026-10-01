#!/usr/bin/env node
// playwright-prefetch.js — Playwright MCP（@playwright/mcp）を事前に入れておく。
//
// なぜ必要か:
//   d-claude / OpenCode は起動のたびに Playwright MCP を立ち上げる。事前に入れていないと
//   最初の起動でダウンロードが走り、教室で一斉に起動すると回線が詰まって MCP の起動待ちを
//   超え、「Playwright が時間切れ」で使えなくなる（2026-10 実機で発生）。
//   「AIツールをまとめて入れる」の時点でここに入れておけば、起動時はネットワークを使わない
//   （playwright-mcp.js が ~/.ai-safety/tools/playwright-mcp を優先して使う）。
//
// 呼ばれる場所: 0_AIツールをまとめて入れる（Mac/Windows）・スタート/2_AIツールをまとめて入れる
// 使い方: node playwright-prefetch.js            （入っていなければ入れる）
//         node playwright-prefetch.js --check    （入っているかだけ確認。終了コード 0=入っている）
//
// 方針:
//   - sudo / 管理者権限は使わない（利用者のホームの下にだけ入れる）。
//   - 失敗しても AI ツール全体の導入は止めない（終了コード 1 と案内だけ出す。
//     その場合も起動時に版を固定した npx で取りに行くので、機能そのものは使える）。
'use strict';

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const pw = require('./playwright-mcp.js');

function main(argv = process.argv.slice(2)) {
  const version = pw.pinnedVersion(__dirname);
  const dir = pw.toolsDir();

  if (pw.localCli(version)) {
    console.log(`Playwright（ブラウザ操作の部品）は準備済みです（${pw.PACKAGE}@${version}）。`);
    return 0;
  }
  if (argv.includes('--check')) {
    console.log(`Playwright（ブラウザ操作の部品）はまだ準備されていません（${pw.PACKAGE}@${version}）。`);
    return 1;
  }

  console.log(`Playwright（ブラウザ操作の部品）を準備します（${pw.PACKAGE}@${version}）…`);
  try {
    fs.mkdirSync(dir, { recursive: true });
  } catch (e) {
    console.log(`【失敗】置き場所を作れませんでした: ${dir}（${e.message}）`);
    return 1;
  }

  const win = process.platform === 'win32';
  const npm = win ? 'npm.cmd' : 'npm';
  // Windows の .cmd は shell 経由でしか起動できない（Node 20 以降）。空白入りのパスに備えて引用する。
  const q = (s) => (win ? `"${s}"` : s);
  const args = ['install', '--prefix', q(dir), '--no-audit', '--no-fund', '--no-update-notifier', '--loglevel=error', `${pw.PACKAGE}@${version}`];
  const r = spawnSync(npm, args, { stdio: 'inherit', shell: win, env: process.env });

  if (r.status === 0 && pw.localCli(version)) {
    console.log('  OK: Playwright を準備しました。d-claude / OpenCode の起動時にダウンロードしません。');
    return 0;
  }
  console.log('  （Playwright の準備に失敗しました。ネット接続を確かめて、もう一度このボタンを押してください。');
  console.log('    このままでも AI は使えます。Playwright は初回の起動時に取りに行きます）');
  return 1;
}

module.exports = { main };

if (require.main === module) {
  process.exitCode = main();
}
