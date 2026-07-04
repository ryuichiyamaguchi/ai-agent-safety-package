#!/usr/bin/env node
// statusline.mjs — 教室配布用の軽量ステータスライン。
// Claude Code / d-claude(DeepSeek) 共通で「cwd │ model │ [context バー] XX%」を1行表示する。
//
// 設計方針:
//   - stdin の JSON を JSON.parse で確実に読む（grep パースの脆さを避ける）。欠損フィールドでも落ちない。
//   - モデル非依存（Anthropic 固有の rate-limit 等は入れない）ので d-claude でも同じ表示になる。
//   - 依存ゼロ（node 標準のみ）。1 ファイル完結。
//
// Claude Code が statusLine コマンドに渡す JSON の主なフィールド:
//   cwd / workspace.current_dir, model.display_name / model.id,
//   context_window.used_percentage / .context_window_size / .current_usage
import { readFileSync } from 'node:fs';

const R = '\x1b[0m';
const CYAN = '\x1b[36m';
const GREEN = '\x1b[32m';
const YELLOW = '\x1b[33m';
const RED = '\x1b[31m';

function readStdin() {
  try { return readFileSync(0, 'utf8'); }
  catch { return ''; }
}

function shortenCwd(p) {
  if (!p) return '?';
  const home = process.env.HOME || process.env.USERPROFILE || '';
  let s = String(p);
  if (home && s.startsWith(home)) s = '~' + s.slice(home.length);
  const parts = s.split(/[\\/]/).filter(Boolean);
  // 末尾2階層だけ表示して短く保つ（先頭が ~ ならそれも残す）
  if (parts.length > 2) {
    const tail = parts.slice(-2).join('/');
    return (s.startsWith('~') ? '~/…/' : '…/') + tail;
  }
  return s;
}

function shortenModel(name, id) {
  const m = String(name || id || '?').trim();
  return m.length > 22 ? m.slice(0, 21) + '…' : m;
}

function pctColor(pct) {
  if (pct <= 50) return GREEN;
  if (pct <= 80) return YELLOW;
  return RED;
}

function bar(pct, width) {
  const filled = Math.max(0, Math.min(width, Math.round((pct * width) / 100)));
  return '█'.repeat(filled) + '░'.repeat(width - filled);
}

function computePct(d) {
  const cw = d.context_window || {};
  if (typeof cw.used_percentage === 'number') return cw.used_percentage;
  // フォールバック: current_usage / トークン合計から算出
  const size = Number(cw.context_window_size) || 0;
  const cu = cw.current_usage || {};
  let used = Number(cu.total_tokens);
  if (!used && typeof d.total_input_tokens === 'number') used = d.total_input_tokens;
  if (size > 0 && used > 0) return (used * 100) / size;
  return 0;
}

function main() {
  let d = {};
  try { d = JSON.parse(readStdin() || '{}'); } catch { d = {}; }
  if (!d || typeof d !== 'object') d = {};

  const cwd = shortenCwd(d.cwd || (d.workspace && d.workspace.current_dir));
  const model = shortenModel(d.model && d.model.display_name, d.model && d.model.id);
  let pct = computePct(d);
  if (!Number.isFinite(pct) || pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  const p = Math.round(pct);
  const col = pctColor(p);

  // cwd │ model │ [bar] XX%
  const line = `${cwd} ${R}│ ${CYAN}${model}${R} │ ${col}${bar(p, 20)} ${p}%${R}`;
  process.stdout.write(line + '\n');
}

main();
