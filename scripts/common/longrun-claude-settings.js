#!/usr/bin/env node
'use strict';
// longrun-claude-settings.js — 長時間おまかせモード用の Claude Code 一時設定を作る（mac / Windows 共通）。
//
// 使い方: node longrun-claude-settings.js <元の settings.json> <書き出し先> [--wall]
//
// 恒久的な設定ファイル（作業フォルダの .claude/settings.json）は書き換えない。このモードの差分だけを
// 当てた JSON を書き出し、呼び出し側が `claude --settings <書き出し先>` で渡して、終了時に消す。
//   ・ask に残っていたものは「無人では答えられない」ので deny 側へ寄せる。緩める方向へは動かさない
//   ・承認は自動で通す（defaultMode: acceptEdits）が「全部素通し」ではない。bypassPermissions は封じたまま
//   ・--wall（mac で壁＝サンドボックスがあるとき）: 壁を明示的に立て直し、立ち上げられなければ素通しで
//     走らずに失敗させる（failIfUnavailable）。壁がある前提で承認を省く経路なので、宣言だけでなく
//     実起動そのものを条件にする。恒久設定には入れない（通常起動で受講者が詰まないように）
//
// 以前は launch-longrun.sh / launch-longrun.ps1 がそれぞれ同じ変換を中に書いていた。d-claude の
// 長時間おまかせモード（v1.19.9）でも使うので、食い違わないようにここへまとめた。
const fs = require('node:fs');

function build(src, { wall = false } = {}) {
  const s = src && typeof src === 'object' ? src : {};
  const p = s.permissions && typeof s.permissions === 'object' ? s.permissions : (s.permissions = {});
  const ask = Array.isArray(p.ask) ? p.ask : [];
  const deny = Array.isArray(p.deny) ? p.deny.slice() : [];
  for (const rule of ask) if (!deny.includes(rule)) deny.push(rule);
  p.ask = [];
  p.deny = deny;
  p.defaultMode = 'acceptEdits';
  p.disableBypassPermissionsMode = 'disable';
  if (wall) {
    s.sandbox = Object.assign({}, s.sandbox, {
      enabled: true,
      autoAllowBashIfSandboxed: true,
      failIfUnavailable: true,
    });
  }
  return s;
}

function main(argv) {
  const args = argv.filter((a) => a !== '--wall');
  const wall = argv.includes('--wall');
  const [srcPath, dstPath] = args;
  if (!srcPath || !dstPath) {
    process.stderr.write('使い方: node longrun-claude-settings.js <元の settings.json> <書き出し先> [--wall]\n');
    return 2;
  }
  const src = JSON.parse(fs.readFileSync(srcPath, 'utf8').replace(/^﻿/, ''));
  fs.writeFileSync(dstPath, JSON.stringify(build(src, { wall }), null, 2), { mode: 0o600 });
  return 0;
}

if (require.main === module) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write('長時間おまかせモード用の設定を作れませんでした: ' + (e && e.message ? e.message : String(e)) + '\n');
    process.exitCode = 1;
  }
}

module.exports = { build };
