#!/usr/bin/env node
'use strict';
// longrun-claude-settings.js — 長時間おまかせモード用の Claude Code 一時設定を作る（mac / Windows 共通）。
//
// 使い方: node longrun-claude-settings.js <元の settings.json> <書き出し先> [--wall] [--dclaude]
//
// 恒久的な設定ファイル（作業フォルダの .claude/settings.json）は書き換えない。このモードの差分だけを
// 当てた JSON を書き出し、呼び出し側が `claude --settings <書き出し先>` で渡して、終了時に消す。
//   ・確認の規則（ask）は確認のまま残す（v1.20.1）。ふだんの操作は確認なしで進めるが、確認が要る操作は
//     確認を出す。v1.17.1〜v1.20.0 は「無人では答えられない」として deny へ寄せていたが、勝手に断るより
//     聞くほうが分かりやすく安全なため戻した
//   ・全承認（bypassPermissions）は封じたまま（disableBypassPermissionsMode）。このパッケージはどの起動でも
//     全承認を使わない
//   ・--wall（mac で壁＝サンドボックスがあるとき）: 壁を明示的に立て直し、立ち上げられなければ素通しで
//     走らずに失敗させる（failIfUnavailable）。壁がある前提で承認を省く経路なので、宣言だけでなく
//     実起動そのものを条件にする。恒久設定には入れない（通常起動で受講者が詰まないように）
//
//   ・--dclaude（d-claude の長時間おまかせモード。v1.20.0）: コマンドはガードの AI 判定（Gemini）が「通してよい」と
//     言ったものをガードが許可する（確認なし）。そのうえで:
//       - Web 取得と d-claude の補助ツール（検索・画像・画面読み取り・ブラウザ操作）に許可の規則を足す
//         （ガードは今までどおり、Web 取得の禁止サイトや秘密の混入を止める）
//       - 壁があるときは、壁の外での実行し直しを禁止する（allowUnsandboxedCommands: false）。AI 判定が通した
//         コマンドは確認なしで進むので、実行し直しを許すと壁の外へ確認なしで出られてしまうため
//     Claude（Anthropic）の長時間おまかせモードは Claude Code 公式の判定役に任せる auto モードなので、付けない。
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
  const deny = Array.isArray(p.deny) ? p.deny : [];
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
