#!/usr/bin/env node
'use strict';
// apply-global-opencode.js — この PC の OpenCode 全体設定
// (~/.config/opencode/opencode.json、既存が opencode.jsonc ならそちら) に、
// 最小の permission.bash の deny / ask を反映する。
//
// 目的: 安全ランチャー（oc-safe / 1_AIをまとめて起動）を通さず素の `opencode` を
//       作業フォルダの外で起動しても、rm / sudo / git reset --hard / 他エージェントの
//       裸起動 が止まるようにする。OpenCode は Claude や Codex と違って hook 層を
//       持たないので、グローバルで効かせられるのは permission 表だけ。
//
//   入れる内容（SSOT は opencode-config.js の buildEnforcedPermissionEnv().bash）:
//     deny: rm * / sudo * / git reset --hard* / codex* / claude* / oc-safe*
//     ask : codex-safe* / claude-safe* / git push* / npm publish*
//   ⚠️ 並び順そのものが意味を持つ。OpenCode の permission は「最後に一致したルールが勝つ」ので、
//      codex-safe*(ask) が codex*(deny) より後ろに無いと安全ランチャーが起動できなくなる。
//      だから既存キー → 本パッケージの deny → ask の順に並べ直す（本パッケージ側を必ず後ろへ）。
//
//   入れないもの: external_directory / read / edit の表。素の opencode を「作業フォルダの
//                 外では何も読めない」状態にすると、ホームで普通に使う受講者の体験を壊す。
//                 隔離が要る作業は従来どおりワークスペース＋安全ランチャーで行う。
//                 モデル・プロバイダ・MCP など好みに属する設定も 1 つも変えない。
//
// 既存設定は壊さない（permission.bash 以外のキーには触れない）。書込前に必ずバックアップし、
// 取り消しは記録から復元する。JSON として読めないファイル（コメント付き .jsonc など）は
// 触らずにスキップして案内する（exit 3）。
//
// Usage:
//   node apply-global-opencode.js apply --config-dir <dir> [--target <file>] [--state <path>] [--dry-run]
//   node apply-global-opencode.js uninstall [--config-dir <dir>] [--target <file>] [--state <path>] [--dry-run]
const fs = require('fs');
const path = require('path');
const state = require('./global-guard-state.js');
const { buildEnforcedPermissionEnv } = require('./opencode-config.js');

function fail(msg) { console.error('apply-global-opencode: ' + msg); process.exit(2); }

const argv = process.argv.slice(2);
const mode = argv[0];
if (mode !== 'apply' && mode !== 'uninstall') fail('first arg must be "apply" or "uninstall"');
const opts = {};
for (let i = 1; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--dry-run') { opts.dryRun = true; continue; }
  if (a.startsWith('--')) { opts[a.slice(2)] = argv[++i]; continue; }
}
const statePath = opts.state || state.defaultStatePath();

// 反映先の決定: --target が明示されていればそれ。無ければ設定フォルダの中を見て、
// 既存の opencode.jsonc があればそちらに追従し、無ければ opencode.json を使う。
function resolveTarget() {
  if (opts.target) return opts.target;
  const dir = opts['config-dir'];
  if (!dir) fail('apply requires --config-dir or --target');
  const jsonc = path.join(dir, 'opencode.jsonc');
  if (fs.existsSync(jsonc)) return jsonc;
  return path.join(dir, 'opencode.json');
}

function doApply() {
  const tgtPath = resolveTarget();
  const enforced = buildEnforcedPermissionEnv().bash;

  const existedBefore = fs.existsSync(tgtPath);
  let tgt = {};
  if (existedBefore) {
    const raw = fs.readFileSync(tgtPath, 'utf8');
    if (raw.trim().length) {
      try { tgt = JSON.parse(raw); }
      catch (e) {
        console.error('既存の ' + tgtPath + ' が JSON として読めません（' + e.message + '）。');
        console.error('コメント付きの .jsonc などは自動で書き換えられません。安全のため触らずにスキップしました。');
        console.error('手で permission.bash に次を足してください: ' + JSON.stringify(enforced));
        process.exit(3);
      }
    }
  }
  if (typeof tgt !== 'object' || tgt === null || Array.isArray(tgt)) {
    console.error('既存の ' + tgtPath + ' が JSON オブジェクトではありません。触らずにスキップしました。');
    process.exit(3);
  }

  if (!tgt.permission || typeof tgt.permission !== 'object' || Array.isArray(tgt.permission)) tgt.permission = {};
  // permission.bash が文字列（'ask' 等の一括指定）の場合は、'*' として保存してから表に変換する。
  let existingBash = tgt.permission.bash;
  if (typeof existingBash === 'string') existingBash = { '*': existingBash };
  if (!existingBash || typeof existingBash !== 'object' || Array.isArray(existingBash)) existingBash = {};

  // 既存キーのうち、本パッケージが管理するキーは一旦落として、必ず後ろへ並べ直す。
  const managed = new Set(Object.keys(enforced));
  const kept = {};
  for (const k of Object.keys(existingBash)) { if (!managed.has(k)) kept[k] = existingBash[k]; }
  tgt.permission.bash = { ...kept, ...enforced };

  console.log('target        : ' + tgtPath + (existedBefore ? '' : ' (new)'));
  console.log('permission    : bash ' + Object.keys(enforced).length + ' 件を反映 (既存 ' + Object.keys(kept).length + ' 件は保持)');
  for (const k of Object.keys(enforced)) console.log('  ' + k + ' → ' + enforced[k]);

  if (opts.dryRun) { console.log('[dry-run] no file written'); return; }

  const st = state.loadState(statePath);
  if (!st.opencode) {
    st.opencode = {
      appliedAt: new Date().toISOString(), target: tgtPath,
      originalBackup: existedBefore ? state.backupFile(tgtPath, 'global-opencode') : null,
      targetExistedBefore: existedBefore,
      addedKeys: Object.keys(enforced),
    };
  } else {
    st.opencode.appliedAt = new Date().toISOString();
    st.opencode.target = tgtPath;
    st.opencode.addedKeys = Object.keys(enforced);
  }

  fs.mkdirSync(path.dirname(tgtPath), { recursive: true });
  fs.writeFileSync(tgtPath, JSON.stringify(tgt, null, 2) + '\n', 'utf8');
  state.saveState(statePath, st);
  console.log('backup        : ' + (st.opencode.originalBackup || '(none — target did not exist)'));
  console.log('written       : ' + tgtPath);
  console.log('state         : ' + statePath);
}

function doUninstall() {
  const st = state.loadState(statePath);
  const entry = st.opencode;
  if (!entry) { console.log('OpenCode グローバル適用の記録がありません(既に解除済み or 未適用)。'); return; }
  const tgtPath = entry.target || opts.target || resolveTarget();

  if (opts.dryRun) {
    console.log('[dry-run] would restore: ' + (entry.originalBackup || '(delete — target did not exist before)'));
    return;
  }
  if (fs.existsSync(tgtPath)) state.backupFile(tgtPath, 'global-opencode-preundo');

  if (entry.originalBackup && fs.existsSync(entry.originalBackup)) {
    fs.copyFileSync(entry.originalBackup, tgtPath);
    console.log('restored      : ' + tgtPath + ' ← ' + entry.originalBackup);
  } else if (entry.targetExistedBefore === false) {
    if (fs.existsSync(tgtPath)) fs.unlinkSync(tgtPath);
    console.log('removed       : ' + tgtPath + ' (適用前は存在しなかったため削除)');
  } else {
    // バックアップが失われた場合の外科的フォールバック: 足したキーだけ取り除く。
    let tgt = {};
    try { tgt = JSON.parse(fs.readFileSync(tgtPath, 'utf8')); } catch (_) { tgt = {}; }
    if (tgt.permission && tgt.permission.bash && typeof tgt.permission.bash === 'object') {
      for (const k of (entry.addedKeys || [])) delete tgt.permission.bash[k];
      if (Object.keys(tgt.permission.bash).length === 0) delete tgt.permission.bash;
      if (Object.keys(tgt.permission).length === 0) delete tgt.permission;
    }
    fs.writeFileSync(tgtPath, JSON.stringify(tgt, null, 2) + '\n', 'utf8');
    console.log('surgically reverted (backup missing): ' + tgtPath);
  }

  delete st.opencode;
  state.saveState(statePath, st);
  console.log('state         : ' + statePath + ' (opencode entry removed)');
}

if (mode === 'apply') doApply(); else doUninstall();
