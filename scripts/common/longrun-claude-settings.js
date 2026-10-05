#!/usr/bin/env node
'use strict';
// longrun-claude-settings.js — 長時間おまかせモード用の Claude Code 一時設定を作る（mac / Windows 共通）。
//
// 使い方: node longrun-claude-settings.js <元の settings.json> <書き出し先> [--wall] [--dclaude]
//
// 恒久的な設定ファイル（作業フォルダの .claude/settings.json）は書き換えない。このモードの差分だけを
// 当てた JSON を書き出し、呼び出し側が `claude --settings <書き出し先>` で渡して、終了時に消す。
//   ・ask に残っていたものは「無人では答えられない」ので deny 側へ寄せる。緩める方向へは動かさない
//   ・全承認（bypassPermissions）は封じたまま（disableBypassPermissionsMode）。このパッケージはどの起動でも
//     全承認を使わない
//   ・--wall（mac で壁＝サンドボックスがあるとき）: 壁を明示的に立て直し、立ち上げられなければ素通しで
//     走らずに失敗させる（failIfUnavailable）。壁がある前提で承認を省く経路なので、宣言だけでなく
//     実起動そのものを条件にする。恒久設定には入れない（通常起動で受講者が詰まないように）
//
//   ・--dclaude（d-claude の長時間おまかせモード。v1.20.0）: 呼び出し側は --permission-mode dontAsk で起動する
//     （確認が要る操作は自動で断り、入力を待って止まらない。Claude Code 公式）。dontAsk で実行されるのは
//     「許可の規則に合うもの」と「フック（ガード）が許可したもの」だけなので:
//       - コマンド: ガードの AI 判定（Gemini）が「通してよい」と言ったものをガードが許可する。判定が
//         「確認」と言ったもの・判定できなかったものはガードが止める（AI_SAFE_LONGRUN=1）
//       - Web 取得と d-claude の補助ツール（検索・画像・画面読み取り・ブラウザ操作）は、ここで許可の規則を
//         足す（ガードは今までどおり、Web 取得の禁止サイトや秘密の混入を止める）
//       - 壁があるときは、壁の外での実行し直しを禁止する（allowUnsandboxedCommands: false）。dontAsk では
//         もともと断られるが、古い Claude Code で acceptEdits に戻ったときに確認で止まらないように
//     Claude（Anthropic）の長時間おまかせモードは Claude Code 公式の判定役に任せる auto モードなので、付けない。
//     v1.20.0 の最初の案では d-claude を全承認にしていたが、ふだんのセッションの AI が長時間モードを呼び出して
//     全承認の AI を立ち上げられる弱点があった（自動セキュリティ確認の指摘）ため、全承認をやめてこの形にした。
//
// 以前は launch-longrun.sh / launch-longrun.ps1 がそれぞれ同じ変換を中に書いていた。d-claude の
// 長時間おまかせモード（v1.19.9）でも使うので、食い違わないようにここへまとめた。
const fs = require('node:fs');

// d-claude の長時間おまかせモードで、確認なしで使えるようにするもの（launch-claude-safe の --mcp-config と同じ名前）。
const DCLAUDE_ALLOW = [
  'WebFetch',
  'mcp__gemini-search',
  'mcp__pollinations-image',
  'mcp__agy-image',
  'mcp__codex-image',
  'mcp__gemini-vision',
  'mcp__playwright',
];

function build(src, { wall = false, dclaude = false } = {}) {
  const s = src && typeof src === 'object' ? src : {};
  const p = s.permissions && typeof s.permissions === 'object' ? s.permissions : (s.permissions = {});
  const ask = Array.isArray(p.ask) ? p.ask : [];
  const deny = Array.isArray(p.deny) ? p.deny.slice() : [];
  for (const rule of ask) if (!deny.includes(rule)) deny.push(rule);
  p.ask = [];
  p.deny = deny;
  p.defaultMode = 'acceptEdits';
  p.disableBypassPermissionsMode = 'disable';
  if (dclaude) {
    const allow = Array.isArray(p.allow) ? p.allow.slice() : [];
    for (const rule of DCLAUDE_ALLOW) if (!allow.includes(rule) && !deny.includes(rule)) allow.push(rule);
    p.allow = allow;
  }
  if (wall) {
    const sb = { enabled: true, autoAllowBashIfSandboxed: true, failIfUnavailable: true };
    if (dclaude) sb.allowUnsandboxedCommands = false;
    s.sandbox = Object.assign({}, s.sandbox, sb);
  }
  return s;
}

function main(argv) {
  const args = argv.filter((a) => a !== '--wall' && a !== '--dclaude');
  const wall = argv.includes('--wall');
  const dclaude = argv.includes('--dclaude');
  const [srcPath, dstPath] = args;
  if (!srcPath || !dstPath || args.length !== 2) {
    process.stderr.write('使い方: node longrun-claude-settings.js <元の settings.json> <書き出し先> [--wall] [--dclaude]\n');
    return 2;
  }
  const src = JSON.parse(fs.readFileSync(srcPath, 'utf8').replace(/^﻿/, ''));
  fs.writeFileSync(dstPath, JSON.stringify(build(src, { wall, dclaude }), null, 2), { mode: 0o600 });
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

module.exports = { build, DCLAUDE_ALLOW };
