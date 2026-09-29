#!/usr/bin/env node
// explainer.js — 見守りモニター用の「いま AI がしようとしていること」解説エンジン（単一実装）。
//
// 位置づけ:
//   以前は同じ解説を bash（scripts/macos/lib/explainer.sh）と PowerShell（scripts/windows/lib/Explainer.ps1）で
//   二重に書いていた（合わせて約 2,300 行）。v1.19.0 でここ 1 本にまとめ、両 OS の見張りはこれを呼ぶだけにした。
//   ★ 危険コマンドを止める「床」（safety_policy.sh / SafetyPolicy.ps1 / opencode-bouncer-monitor.mjs）とは無関係。
//     ここは表示専用で、失敗しても判定は変わらない。Node が無い PC では見張り側が簡易表示に切り替える。
//
// 出力（どちらもログフォルダ。既定 ~/.ai-safety/logs）:
//   now.md   … ターミナル版モニター（monitor.sh）が読む
//   now.html … ブラウザ版モニター・monitor-server.js が読む（クラス名 action-cmd / whatdo-body 等は契約）
//
// 設計原則（旧 bash 版から引き継ぎ）:
//   「証明されない限り安全と言わない」。安心文（見るだけ・書き換えはしません）は、全セグメントが
//   読み取り専用と証明できた単純コマンドのときだけ出す。
//
// CLI:
//   node explainer.js explain --mode <bash|write|webfetch|observe|prompt|post-output> [--log-dir D] [--cards-dir D]
//        stdin = フック入力（JSON 文字列そのまま）。成功時 stdout に "<card_id>\t<risk>" を 1 行出す。
//   node explainer.js placeholder [--log-dir D]
//        now.html がまだ無いときだけ「見守り中です」の待機画面を書く。
//   node explainer.js explain-command [--format parity]
//        stdin = コマンド文字列。stdout = {"whatdo","icon","danger"} の JSON（テスト用）。
//        --format parity は「警告あり\t安心文あり\t本文\t警告」の 1 行（explainer-parity.tsv の検査用）。
//   explain に --force-card <id> を付けると、索引で選ばずにそのカードを使う（テスト用）。
//   node explainer.js render-html --mode M --icon I --title T --risk R --ts TS --card-id C [--body-path P] [--log-dir D]
//        stdin = フック入力。now.html だけを指定の見出しで書く（テスト用）。
// 常に exit 0（表示専用のため。失敗は黙って諦める）。
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// ---------------------------------------------------------------------------
// 小道具
// ---------------------------------------------------------------------------
const SPACE_CLASS = ' \t\n\r\v\f';
function isSpace(c) { return SPACE_CLASS.includes(c); }
function trimSpaces(s) { return String(s).replace(/^[ \t\n\r\v\f]+/, '').replace(/[ \t\n\r\v\f]+$/, ''); }
function lower(s) { return String(s).toLowerCase(); }
function codepoints(s) { return Array.from(String(s)); }

// awk の既定の区切り（空白・タブ）で最初のフィールドを返す。
function awkFields(s) { return String(s).split(/[ \t\n]+/).filter((x) => x !== ''); }
function firstField(s) { return awkFields(s)[0] || ''; }

// awk の split(s, a, /[[:space:]]+/) と同じ分割（先頭・末尾の区切りは空フィールドになる）。
function splitSpaceRe(s) {
  if (s === '') return [];
  return String(s).split(/[ \t\n\r\v\f]+/);
}

// sed は 1 行ずつ処理する。行単位で置換してから改行でつなぎ直す。
function perLine(s, fn) { return String(s).split('\n').map(fn).join('\n'); }

// $() は末尾の改行を削る。bash 版の値の受け渡しと同じ結果にするための再現。
function stripTrailingNewlines(s) { return String(s).replace(/\n+$/, ''); }

function htmlEscape(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// 改行をまとめて空白にし、max 文字（コードポイント単位）を超えたら切って「…（省略）」を付ける。
function limitChars(text, max) {
  const s = String(text).replace(/[\r\n]+/g, ' ');
  const cps = codepoints(s);
  if (cps.length > max) return cps.slice(0, max).join('') + '…（省略）';
  return s;
}

// ---------------------------------------------------------------------------
// フック入力からの取り出し（旧 bash 版と同じく「その名前の最後の出現」を正規表現で拾う）
// ---------------------------------------------------------------------------
function jsonUnescape(s) {
  return String(s).replace(/\\(u[0-9a-fA-F]{4}|["\\/bfnrt])/g, (_m, e) => {
    switch (e) {
      case '"': return '"';
      case '\\': return '\\';
      case '/': return '/';
      case 'b': return '\b';
      case 'f': return '\f';
      case 'n': return '\n';
      case 'r': return '\r';
      case 't': return '\t';
      default: return String.fromCharCode(parseInt(e.slice(1), 16));
    }
  });
}

function escapeRe(s) { return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function extractJsonString(raw, key) {
  const flat = String(raw).replace(/\n/g, ' ');
  const re = new RegExp('"' + escapeRe(key) + '"[ \\t\\n\\r\\v\\f]*:[ \\t\\n\\r\\v\\f]*"((?:\\\\.|[^"\\\\])*)"', 'g');
  let m; let last = null;
  while ((m = re.exec(flat)) !== null) last = m[1];
  if (last === null) return '';
  return jsonUnescape(last);
}

function tryParse(raw) { try { return JSON.parse(raw); } catch { return null; } }

// safety_policy.sh の _extract_json_field と同じ探索順（tool_input → … → ルート → tool_response）。
function structuredField(raw, field) {
  const obj = tryParse(raw);
  if (!obj || typeof obj !== 'object') return '';
  const order = ['tool_input', 'toolInput', 'input', 'parameters', 'args', '', 'tool_response'];
  for (const k of order) {
    const base = k === '' ? obj : obj[k];
    if (base && typeof base === 'object' && typeof base[field] === 'string' && base[field] !== '') return base[field];
  }
  return '';
}

function extractUrl(raw) {
  const v = structuredField(raw, 'url');
  if (v) return v;
  const m = String(raw).split('\n').map((ln) => ln.match(/.*"url"[ \t\n\r\v\f]*:[ \t\n\r\v\f]*"([^"]+)".*/)).find(Boolean);
  return m ? m[1] : '';
}

function extractToolName(raw) {
  return extractJsonString(raw, 'tool_name') || extractJsonString(raw, 'toolName') || extractJsonString(raw, 'name');
}

// observe モード: ツール別に「安全で短い」入力要約（パス・パターン・検索語だけ。本文は出さない）。
function observeInputSummary(raw, tool) {
  const get = (k) => stripTrailingNewlines(extractJsonString(raw, k));
  let s = '';
  switch (tool) {
    case 'Read': case 'NotebookRead': case 'FileRead':
      s = get('file_path') || get('path') || get('notebook_path');
      break;
    case 'Glob': case 'Grep': case 'Search': {
      s = get('pattern');
      const p = get('path');
      if (p) s = `${s} (場所: ${p})`;
      break;
    }
    case 'WebSearch': s = get('query'); break;
    case 'LS': s = get('path'); break;
    case 'Agent': case 'Task': case 'TaskCreate': case 'NotebookEdit':
      s = 'subagent/task 作成';
      break;
    default:
      s = get('file_path') || get('path') || get('pattern') || get('query') || get('url');
  }
  return s;
}

function extractTarget(mode, raw) {
  switch (mode) {
    case 'bash': return stripTrailingNewlines(extractJsonString(raw, 'command'));
    case 'write': return stripTrailingNewlines(extractJsonString(raw, 'file_path'));
    case 'webfetch': {
      const url = extractUrl(raw);
      return lower(url.replace(/^https?:\/\/([^/:?#]+).*$/s, '$1'));
    }
    case 'observe': return extractToolName(raw);
    default: return String(raw);
  }
}

// 「AI が実際にしようとしていること」の文字列。{ text, label, rawCmd }
function extractActionText(mode, raw) {
  let text = '';
  let label = '操作';
  let rawCmd = '';
  switch (mode) {
    case 'bash':
      text = stripTrailingNewlines(extractJsonString(raw, 'command'));
      rawCmd = extractJsonString(raw, 'command');
      label = 'コマンド実行';
      break;
    case 'write': {
      const fp = stripTrailingNewlines(extractJsonString(raw, 'file_path'));
      const content = limitChars(extractJsonString(raw, 'content'), 120);
      text = content ? `${fp} (内容: ${content})` : fp;
      label = 'ファイル書き込み';
      break;
    }
    case 'webfetch': {
      const m = String(raw).split('\n').map((ln) => ln.match(/.*"url"[ \t\n\r\v\f]*:[ \t\n\r\v\f]*"([^"]+)".*/)).find(Boolean);
      text = m ? m[1] : '';
      label = 'Web アクセス';
      break;
    }
    case 'observe': {
      const tool = extractToolName(raw) || '不明なツール';
      text = limitChars(observeInputSummary(raw, tool), 300);
      label = `${tool} を使用`;
      break;
    }
    case 'prompt': case 'post-output':
      text = limitChars(raw, 300);
      label = 'プロンプト';
      break;
    default:
      text = limitChars(raw, 200);
      label = '操作';
  }
  if (!text) text = '（取得できませんでした）';
  text = limitChars(text, 800);
  return { text, label, rawCmd: rawCmd || '' };
}

// ---------------------------------------------------------------------------
// コマンド解説（パターン式・LLM 不要・決定的）
// ---------------------------------------------------------------------------

// | ; && || & 改行 CR で分割し、前後の空白を除いた空でないセグメントを返す。
function splitSegments(full) {
  const out = [];
  let seg = '';
  const flush = () => { const t = trimSpaces(seg); if (t !== '') out.push(t); seg = ''; };
  const s = String(full);
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    const c2 = s.slice(i, i + 2);
    if (c === '\n' || c === '\r') { flush(); continue; }
    if (c === '|' || c === ';') {
      flush();
    } else if (c2 === '&&' || c2 === '||') {
      flush(); i++;
    } else if (c === '&' && c2 !== '&&' && c2 !== '&>') {
      flush();
    } else {
      seg += c;
    }
  }
  flush();
  return out;
}

// 先頭が sudo なら外す（awk の $1="" と同じく、フィールド間の空白は 1 つにまとまる）。
function stripSudo(seg) {
  const f = awkFields(seg);
  if (f.length >= 2 && lower(f[0]) === 'sudo') return f.slice(1).join(' ');
  return seg;
}

function stripQuoted(s) {
  return perLine(s, (ln) => ln.replace(/"[^"]*"/g, ' ').replace(/'[^']*'/g, ' '));
}
function stripSingleQuoted(s) { return perLine(s, (ln) => ln.replace(/'[^']*'/g, ' ')); }

const RE_STDERR = /^2>>?([^>]|$)/;
const RE_REDIR_ALONE = /^[0-9]*>>?$/;
const RE_AMP_ALONE = /^&>>?$/;
const RE_REDIR_JOINED = /^[0-9]*>>?[^>]/;
const RE_AMP_JOINED = /^&>>?[^>]/;
const RE_STDERR_PREFIX = /^2>>?/;

// 標準出力などをファイルへ書くリダイレクト（2> 以外）があるか。引用符の中の > は数えない。
function hasRedir(s) {
  const stripped = stripQuoted(s);
  for (const line of stripped.split('\n')) {
    for (const t of splitSpaceRe(line)) {
      if (RE_STDERR.test(t)) continue;
      if (RE_REDIR_ALONE.test(t) || RE_AMP_ALONE.test(t)) return true;
      if ((RE_REDIR_JOINED.test(t) || RE_AMP_JOINED.test(t)) && !RE_STDERR_PREFIX.test(t)) return true;
    }
  }
  return false;
}

// 引用符を外しながら空白（スペースのみ）区切りでトークンを読む。
function readToken(str, pos) {
  while (pos < str.length && str[pos] === ' ') pos++;
  if (pos >= str.length) return { tok: '', pos, empty: true };
  let t = ''; let q = '';
  while (pos < str.length) {
    const c = str[pos];
    if (q) {
      if (c === q) { q = ''; pos++; continue; }
      t += c; pos++; continue;
    }
    if (c === '"' || c === "'") { q = c; pos++; continue; }
    if (c === ' ') break;
    t += c; pos++;
  }
  return { tok: t, pos, empty: false };
}

// 書き込みリダイレクトの行き先（最初の 1 つ）。
// v1.19.0 で旧 bash 版から改良: `>& file` / `>| file` / `>>& file` の行き先を正しく読み、
// `>&2` や `1>&2` のような出力のつなぎ替え（ファイルに書かない）は行き先として扱わない。
const RE_FD_DUP = /^[0-9]*>>?&([0-9]+-?|-)$/;
const RE_OP_ALONE_EXT = /^[0-9]*>>?[&|]$/;
function redirTarget(full) {
  for (const line of String(full).split('\n')) {
    let pos = 0;
    while (pos < line.length) {
      const r = readToken(line, pos);
      if (r.empty) break;
      pos = r.pos;
      let t = r.tok;
      if (RE_STDERR.test(t)) continue;
      if (RE_FD_DUP.test(t)) continue;
      if (RE_REDIR_ALONE.test(t) || RE_AMP_ALONE.test(t) || RE_OP_ALONE_EXT.test(t)) {
        const n = readToken(line, pos);
        if (!n.empty && n.tok !== '') return n.tok;
        continue;
      }
      if (/^[0-9]*>>?[&|]./.test(t) && !RE_STDERR_PREFIX.test(t)) {
        return t.replace(/^[0-9]*>>?[&|]/, '');
      }
      if ((/^[0-9]+>>?[^>]/.test(t) || RE_AMP_JOINED.test(t)) && !RE_STDERR_PREFIX.test(t)) {
        return t.replace(/^([0-9]+|&)>>?/, '');
      }
      if (/^>>?[^>]/.test(t) && !RE_STDERR_PREFIX.test(t)) {
        t = t.replace(/^>>?/, '');
        return t;
      }
    }
  }
  return '';
}

// 引用符を考慮してトークンに分ける（空白・タブで区切る。引用符の中の空白は区切らない）。
// raw は引用符込みの元の文字列、value は引用符を外した値。
// v1.19.0 で旧 bash 版から改良: 旧版は「引用符を空白にした文字列」と「元の文字列」を別々に分割して
// 番号で対応させていたため、`ls "dir with space"/x` のように引用符の中の空白の数で番号がずれ、
// 対象の場所を途中で切っていた。
function shellTokens(s) {
  const out = [];
  let raw = ''; let value = ''; let q = ''; let has = false;
  const push = () => { if (has) out.push({ raw, value }); raw = ''; value = ''; has = false; };
  for (const c of String(s)) {
    if (q) {
      raw += c;
      if (c === q) q = ''; else value += c;
      continue;
    }
    if (c === '"' || c === "'") { q = c; raw += c; has = true; continue; }
    if (c === ' ' || c === '\t') { push(); continue; }
    raw += c; value += c; has = true;
  }
  push();
  return out;
}

// 対象（パス・URL など）の取り出し。{ target, fromSubst }。
// fromSubst: 対象の位置に $(...) / <(...) があり、場所がそのコマンドの結果で決まる。
function explainTarget(seg, cat) {
  const tk = [null, ...shellTokens(seg)];
  const n = tk.length - 1;
  const raw = (i) => tk[i].raw;
  const val = (i) => tk[i].value;
  const redir = new Set();
  for (let i = 1; i <= n; i++) {
    const t = raw(i);
    if (RE_STDERR.test(t)) { redir.add(i); continue; }
    if (RE_FD_DUP.test(t)) { redir.add(i); continue; }
    if (RE_REDIR_ALONE.test(t) || RE_AMP_ALONE.test(t) || RE_OP_ALONE_EXT.test(t)) { redir.add(i); if (i + 1 <= n) redir.add(i + 1); }
    if ((RE_REDIR_JOINED.test(t) || RE_AMP_JOINED.test(t)) && !RE_STDERR_PREFIX.test(t)) redir.add(i);
    if (/^<<?(>|$)/.test(t) || /^<$/.test(t)) { redir.add(i); if (i + 1 <= n) redir.add(i + 1); }
    if (/^<[^<>(]/.test(t) && !/^\$\(/.test(t) && !/^<\(/.test(t)) redir.add(i);
  }
  for (let i = 1; i <= n; i++) {
    if (redir.has(i)) continue;
    if (/^https?:\/\//.test(val(i))) return { target: val(i), fromSubst: false };
  }
  for (let i = 2; i <= n; i++) {
    if (redir.has(i)) continue;
    const lf = lower(raw(i));
    if (lf === '-path' || lf === '-literalpath' || lf === '-destination' || lf === '-url' || lf === '-uri') {
      for (let j = i + 1; j <= n; j++) if (!redir.has(j)) return { target: val(j), fromSubst: false };
    }
  }
  const skip = (cat === 'grep' || cat === 'findstr' || cat === 'select-string' || cat === 'sls') ? 1 : 0;
  let pos = 0; let depth = 0; let sawSubst = false;
  for (let i = 2; i <= n; i++) {
    if (redir.has(i)) continue;
    const r = raw(i);
    if (/^\$\(/.test(r) || /^<\(/.test(r) || /^`/.test(r)) {
      sawSubst = true;
      const opens = (r.match(/\$\(|<\(/g) || []).length;
      const closes = (r.match(/\)/g) || []).length;
      if (/^`/.test(r)) { if ((r.match(/`/g) || []).length < 2) depth++; } else if (closes < opens) depth++;
      continue;
    }
    if (depth > 0) { if (r.includes(')') || r.includes('`')) depth--; continue; }
    if (r[0] === '-') continue;
    if (cat === 'del' && r[0] === '/') continue;
    if ((cat === 'chmod' || cat === 'chown') && r[0] !== '/' &&
        (/^[0-9]+$/.test(r) || /^[ugoa]*[+\-=][rwxst,ugoa]+$/.test(r))) continue;
    pos++;
    if (pos <= skip) continue;
    return { target: val(i), fromSubst: false };
  }
  return { target: '', fromSubst: sawSubst };
}

const RO_VERBS = new Set(['ls', 'dir', 'get-childitem', 'gci', 'll', 'la', 'cat', 'type', 'get-content', 'gc',
  'head', 'tail', 'wc', 'stat', 'pwd', 'whoami']);
const DELETE_VERBS = new Set(['rm', 'rmdir', 'del', 'erase', 'remove-item', 'ri']);
const WRITE_VERBS = new Set(['touch', 'new-item', 'set-content', 'out-file', 'add-content', 'tee', 'echo', 'printf',
  'mv', 'move', 'move-item', 'cp', 'copy', 'copy-item']);
const EXEC_VERBS = new Set(['bash', 'sh', 'zsh', 'python', 'python3', 'node', 'source', 'invoke-expression', 'iex',
  'start-process', '&']);
const PERM_VERBS = new Set(['chmod', 'chown', 'icacls', 'set-acl', 'set-itemproperty']);

function anyLine(s, re) { return String(s).split('\n').some((ln) => re.test(ln)); }

function scanFlags(full) {
  const f = { sudo: 0, del: 0, delRec: 0, write: 0, exec: 0, perm: 0, anyRedir: 0, subst: 0, ro: 1, compound: 0 };
  if (anyLine(stripTrailingNewlines(stripSingleQuoted(full)), /(\$\(|<\(|`)/)) f.subst = 1;
  const strippedRedir = stripTrailingNewlines(stripQuoted(full));
  if (anyLine(strippedRedir, /(>>?|[0-9]>>?|&>>?|<+)/)) f.anyRedir = 1;
  const segs = splitSegments(full);
  if (segs.length > 1) f.compound = 1;
  if (/[|;&]/.test(strippedRedir)) f.compound = 1;
  if (/[\n\r]/.test(full)) f.compound = 1;
  const fullLc = lower(full);
  for (let seg of segs) {
    seg = stripSudo(seg);
    const verb = lower(firstField(seg));
    const lcSeg = lower(seg);
    if (anyLine(fullLc, /(^|[ \t\n\r\v\f])sudo([ \t\n\r\v\f]|$)/)) f.sudo = 1;
    if (/(runas|-verb[ \t\n\r\v\f]+runas)/.test(lcSeg)) f.sudo = 1;
    if (hasRedir(seg)) f.write = 1;
    if (!RO_VERBS.has(verb)) f.ro = 0;
    if (DELETE_VERBS.has(verb)) {
      f.del = 1;
      if (/(\brm\b.*[ \t\n\r\v\f]-[a-z]*r[a-z]*|remove-item.*[ \t\n\r\v\f]-recurse|\bdel\b.*\/s\b)/.test(lcSeg)) f.delRec = 1;
    } else if (WRITE_VERBS.has(verb)) {
      f.write = 1;
    } else if (EXEC_VERBS.has(verb)) {
      f.exec = 1;
    } else if (PERM_VERBS.has(verb)) {
      f.perm = 1;
    }
    if (verb === 'xargs' && /\bxargs\b[ \t\n\r\v\f]+(-[^ ]+ +)*rm\b/.test(lcSeg)) {
      f.del = 1;
      if (/\bxargs\b[ \t\n\r\v\f]+(-[^ ]+ +)*rm\b.*[ \t\n\r\v\f]-[a-z]*r/.test(lcSeg)) f.delRec = 1;
    }
    if (verb === 'find' && /[ \t\n\r\v\f]-delete\b/.test(lcSeg)) f.del = 1;
    if (verb === 'find' && /[ \t\n\r\v\f]-(exec|execdir|ok|okdir)\b/.test(lcSeg)) f.exec = 1;
  }
  return f;
}

const MORE = '（ほかにも処理が続きます。全文は上のコマンドを確認してください）';

// 公開関数: コマンド文字列 → { whatdo, icon, danger }（danger は改行区切り）。
function explainCommand(full) {
  const res = { whatdo: '', icon: '📂', danger: '' };
  full = String(full == null ? '' : full);
  if (full === '') return res;
  const f = scanFlags(full);
  const firstSeg = stripSudo(splitSegments(full)[0] || '');
  const verb = firstField(firstSeg);
  const verbLc = lower(verb);

  const dangers = [];
  if (f.sudo) dangers.push('⚠️ 管理者権限への昇格を含みます（PC全体に影響する可能性）');
  if (f.delRec) dangers.push('⚠️ フォルダごとの完全削除（復元できません）を含みます');
  else if (f.del) dangers.push('⚠️ ファイル・フォルダの削除を含みます');
  if (f.exec && !f.sudo && !EXEC_VERBS.has(verbLc)) dangers.push('⚠️ スクリプト/プログラムの実行を含みます');
  if (f.subst) dangers.push('（コマンド内に別のコマンドが埋め込まれています。全文を確認してください）');
  res.danger = dangers.join('\n');

  const readonlyAll = !f.sudo && !f.del && !f.write && !f.exec && !f.perm && !f.anyRedir && !f.subst && !f.compound && f.ro;
  const extra = f.compound ? MORE : '';

  const rt = stripTrailingNewlines(redirTarget(full));
  if (rt && hasRedir(full)) {
    res.icon = '✏️';
    const op = anyLine(full, />>/) ? '追記' : '書き込み(上書き)';
    res.whatdo = `${rt} にファイルを${op}しようとしています。` + extra;
    return res;
  }

  const { target, fromSubst } = explainTarget(firstSeg, verbLc);
  const tdisp = target !== '' ? target : (fromSubst ? '（埋め込まれたコマンドの結果の場所）' : '現在のフォルダ');
  let w = '';
  switch (true) {
    case ['ls', 'dir', 'get-childitem', 'gci', 'll', 'la'].includes(verbLc):
      res.icon = '📂';
      w = `${tdisp} の中のファイル・フォルダ一覧を見ようとしています。` + (readonlyAll ? '（中身を見るだけ。削除や書き換えはしません）' : '');
      break;
    case ['cat', 'head', 'tail', 'less', 'more', 'type', 'get-content', 'gc', 'wc', 'file', 'stat', 'pwd', 'whoami', 'date'].includes(verbLc):
      res.icon = '📄';
      w = `${tdisp} の中身を読もうとしています。` + (readonlyAll ? '（読むだけ。書き換えはしません）' : '');
      break;
    case DELETE_VERBS.has(verbLc):
      res.icon = '🗑';
      w = `${tdisp} を削除しようとしています。`;
      break;
    case ['touch', 'new-item', 'set-content', 'out-file', 'add-content', 'tee'].includes(verbLc):
      res.icon = '✏️';
      w = `${tdisp} を作成または書き換えようとしています。`;
      break;
    case ['echo', 'printf'].includes(verbLc):
      res.icon = '📄';
      w = '画面に文字を表示しようとしています。';
      break;
    case ['mv', 'move', 'move-item'].includes(verbLc):
      res.icon = '📦';
      w = `${tdisp} を別の場所に移動しようとしています。`;
      break;
    case ['cp', 'copy', 'copy-item'].includes(verbLc):
      res.icon = '📦';
      w = `${tdisp} を別の場所にコピーしようとしています。`;
      break;
    case ['curl', 'wget', 'invoke-webrequest', 'iwr', 'invoke-restmethod', 'irm', 'nc', 'ncat', 'netcat'].includes(verbLc):
      res.icon = '🌐';
      w = target ? `${target} とインターネット通信（ダウンロードまたは送信）をしようとしています。`
        : 'インターネット通信（ダウンロードまたは送信）をしようとしています。';
      break;
    case ['npm', 'pip', 'pip3', 'winget', 'choco', 'brew', 'apt', 'apt-get', 'yum', 'gem'].includes(verbLc):
      if (/(^|[ \t\n\r\v\f])(install|add|i)([ \t\n\r\v\f]|$)/i.test(firstSeg)) {
        res.icon = '📥';
        const pkg = awkFields(firstSeg).slice(2).find((x) => x[0] !== '-') || 'パッケージ';
        w = `${pkg} をインターネットからインストール（PC に新しいプログラムを追加）しようとしています。`;
      } else {
        res.icon = '⚙️';
        w = `${verb} コマンドを実行しようとしています。`;
      }
      break;
    case EXEC_VERBS.has(verbLc):
      res.icon = '⚙️';
      w = `${tdisp} を実行しようとしています。（別のプログラムやスクリプトを動かします）`;
      break;
    case PERM_VERBS.has(verbLc):
      res.icon = '🔑';
      w = `${tdisp} のアクセス権限や設定を変更しようとしています。`;
      break;
    case ['cd', 'set-location', 'sl', 'pushd'].includes(verbLc):
      res.icon = '📁';
      w = `作業フォルダを ${tdisp} に移動しようとしています。`;
      break;
    case ['grep', 'findstr', 'select-string', 'sls', 'find'].includes(verbLc):
      res.icon = '🔍';
      w = `${tdisp} から文字列やファイルを検索しようとしています。` + (readonlyAll ? '（読むだけ。書き換えはしません）' : '');
      break;
    default:
      w = '';
  }
  if (w && extra) w += extra;
  res.whatdo = w;
  return res;
}

// ---------------------------------------------------------------------------
// 解説カード（configs/safety/cards）
// ---------------------------------------------------------------------------
// POSIX 文字クラスを JS の正規表現へ置き換える（index.tsv は grep -E 向けに書かれている）。
function posixToJs(p) {
  return String(p)
    .replace(/\[\[:space:\]\]/g, '\\s').replace(/\[\[:digit:\]\]/g, '\\d')
    .replace(/\[\[:alpha:\]\]/g, '[A-Za-z]').replace(/\[\[:alnum:\]\]/g, '[A-Za-z0-9]')
    .replace(/\[\[:upper:\]\]/g, '[A-Z]').replace(/\[\[:lower:\]\]/g, '[a-z]');
}

// 上から評価し、最初に一致した行を採る。大文字小文字は区別しない（PowerShell 側の -match に合わせた。
// Windows では invoke-webrequest のように小文字で書かれることが多いため）。
function lookupCard(cardsDir, mode, target) {
  let text;
  try { text = fs.readFileSync(path.join(cardsDir, 'index.tsv'), 'utf8'); } catch { return null; }
  for (const line of text.split(/\r?\n/)) {
    if (line === '' || line.startsWith('#')) continue;
    const [tool, pattern, risk, cardId] = line.split('\t');
    if (tool !== mode || !pattern || !cardId) continue;
    let re;
    try { re = new RegExp(posixToJs(pattern), 'i'); } catch { continue; }
    if (re.test(String(target))) return { cardId, risk: risk || 'low' };
  }
  return null;
}

// カードファイルを { meta, body } に分ける。先頭行が --- のときだけ frontmatter とみなす。
function readCard(file) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return null; }
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  const meta = {};
  if (lines[0] !== '---') return { meta, bodyLines: [] };
  let i = 1;
  for (; i < lines.length; i++) {
    if (lines[i] === '---') break;
    const m = lines[i].match(/^([A-Za-z0-9_-]+)[ \t]*:[ \t]*(.*)$/);
    if (m && !(m[1] in meta)) meta[m[1]] = m[2].replace(/[ \t\n\r\v\f]+$/, '');
  }
  const bodyLines = i < lines.length ? lines.slice(i + 1) : [];
  if (bodyLines.length && bodyLines[bodyLines.length - 1] === '') bodyLines.pop();
  return { meta, bodyLines };
}

// カード本文（markdown）を最小限の HTML に。見出し → h2、箇条書き → ul/li、空行で段落を区切る。
function cardBodyToHtml(bodyLines) {
  const out = [];
  let inList = false;
  const flush = () => { if (inList) { out.push('</ul>'); inList = false; } };
  for (const raw of bodyLines) {
    const line = raw.replace(/[ \t\n\r\v\f]+$/, '');
    if (/^#+[ \t]/.test(line)) { flush(); out.push('<h2>' + htmlEscape(line.replace(/^#+[ \t]+/, '')) + '</h2>'); continue; }
    if (/^[-*][ \t]/.test(line)) {
      if (!inList) { out.push('<ul>'); inList = true; }
      out.push('<li>' + htmlEscape(line.replace(/^[-*][ \t]+/, '')) + '</li>');
      continue;
    }
    if (/^[ \t]*$/.test(line)) { flush(); continue; }
    flush();
    out.push('<p>' + htmlEscape(line) + '</p>');
  }
  flush();
  return out.join('\n');
}

// ---------------------------------------------------------------------------
// 出力（now.md / now.html）
// ---------------------------------------------------------------------------
function pad2(n) { return String(n).padStart(2, '0'); }
function localDate(d = new Date()) { return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`; }
function localStamp(d = new Date()) { return `${localDate(d)} ${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`; }

function defaultLogDir() { return process.env.AI_SAFE_LOG_DIR || path.join(os.homedir(), '.ai-safety', 'logs'); }
function refreshSec() { const r = process.env.AI_SAFE_MONITOR_INTERVAL || '1'; return /^[0-9]+$/.test(r) ? r : '1'; }

function ensureDir(dir) { fs.mkdirSync(dir, { recursive: true, mode: 0o700 }); }

// 同じフォルダに一時ファイルを書いてから rename（ブラウザの再読み込みが半端な内容を読まないように）。
function atomicWrite(file, content) {
  const tmp = `${file}.tmp.${process.pid}`;
  try {
    fs.writeFileSync(tmp, content, { mode: 0o600 });
    fs.renameSync(tmp, file);
    try { fs.chmodSync(file, 0o600); } catch { /* Windows では無視 */ }
    return true;
  } catch {
    try { fs.unlinkSync(tmp); } catch { /* 無視 */ }
    return false;
  }
}

function nowHtmlHead(refresh) {
  return [
    '<!DOCTYPE html>', '<html lang="ja">', '<head>',
    '<meta charset="utf-8">',
    `<meta http-equiv="refresh" content="${refresh}">`,
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    '<title>agent-monitor — AI の動きを見る</title>',
    '<style>',
    '*{box-sizing:border-box}',
    'body{margin:0;padding:16px;font-family:-apple-system,"Hiragino Sans","Yu Gothic",sans-serif;background:#0f1115;color:#e6e6e6;word-break:keep-all;line-height:1.7}',
    '.wrap{max-width:880px;margin:0 auto}',
    'h1.hdr{font-size:18px;margin:0 0 14px;color:#9ad}',
    '.card{border-radius:12px;padding:18px 20px;margin-bottom:20px;border-left:8px solid #888;background:#1a1d24}',
    '.card-high{border-left-color:#e5534b;background:#2a1718}',
    '.card-medium{border-left-color:#e0b341;background:#2a2417}',
    '.card-low{border-left-color:#3fb950;background:#15241a}',
    '.card-wait{border-left-color:#6e7681;background:#1a1d24}',
    '.card .ctitle{font-size:22px;font-weight:700;margin:0 0 6px}',
    '.card .cmeta{font-size:12px;opacity:.7;margin-bottom:10px}',
    '.card h2{font-size:15px;margin:14px 0 6px;color:#cfd}',
    '.card ul{margin:4px 0 4px 1.2em;padding:0}',
    '.card li{margin:3px 0}',
    '.card p{margin:6px 0}',
    '.events h2{font-size:15px;color:#9ad;margin:0 0 8px}',
    'table{width:100%;border-collapse:collapse;font-size:13px}',
    'th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #2a2f3a;vertical-align:top}',
    'th{color:#9aa;font-weight:600}',
    '.ev-ts{white-space:nowrap;opacity:.8}',
    '.ev-mode{white-space:nowrap;opacity:.85}',
    'tr.d-block .ev-dec{color:#ff7b72}',
    'tr.d-allow .ev-dec{color:#56d364}',
    'tr.d-explain .ev-dec{color:#79c0ff}',
    '.empty{opacity:.6;font-size:13px}',
    '.foot{margin-top:18px;font-size:11px;opacity:.5}',
    '.action{background:#12161f;border:1px solid #2a3040;border-radius:8px;padding:12px 14px;margin:10px 0 14px}',
    '.action-label{font-size:12px;color:#8ab;margin-bottom:6px;font-weight:600}',
    '.action-cmd{margin:0;font-family:monospace,"Courier New",Courier;font-size:14px;color:#f0c080;white-space:pre-wrap;word-break:break-all;overflow-wrap:anywhere}',
    '.whatdo{background:#14211a;border:1px solid #2a4030;border-radius:8px;padding:12px 14px;margin:0 0 14px}',
    '.whatdo-label{font-size:13px;color:#7fd6a0;margin-bottom:6px;font-weight:700}',
    '.whatdo-body{margin:0;font-size:15px;color:#e6e6e6;line-height:1.7}',
    '.whatdo-danger{margin:8px 0 0;font-size:14px;color:#ffb4ad;font-weight:700}',
    '</style>',
    '<script>setInterval(function(){ location.reload(); }, 1000);</script>',
    '</head>', '<body>', '<div class="wrap">',
    '<h1 class="hdr">agent-monitor — いま AI がやろうとしていること</h1>',
  ].join('\n') + '\n';
}

function footer(refresh) {
  return `<div class="foot">この画面は ${refresh} 秒ごとに自動更新されます (JS reload + meta refresh フォールバック)。判断はこの画面ではなくターミナル側で行ってください。</div>\n</div>\n</body>\n</html>\n`;
}

const DEC_CLASS = { block: 'd-block', allow: 'd-allow', explain: 'd-explain' };
const DEC_ICON = { block: '⛔', allow: '✅', explain: '💬' };

// 今日の監査ログ（events-YYYY-MM-DD.jsonl）の末尾 N 件を、新しい順の表の行にする。
function eventsRows(logDir) {
  let text;
  try { text = fs.readFileSync(path.join(logDir, `events-${localDate()}.jsonl`), 'utf8'); } catch { return ''; }
  const n = /^[0-9]+$/.test(process.env.AI_SAFE_MONITOR_TAIL || '') ? Number(process.env.AI_SAFE_MONITOR_TAIL) : 12;
  const lines = text.split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  const pick = (ln, key) => { const m = ln.match(new RegExp('.*"' + key + '"[ \\t]*:[ \\t]*"([^"]+)".*')); return m ? m[1] : ''; };
  const rows = [];
  for (const ln of lines.slice(Math.max(0, lines.length - n)).reverse()) {
    if (!ln) continue;
    const ts = pick(ln, 'ts'); const decision = pick(ln, 'decision'); const mode = pick(ln, 'mode'); const reason = pick(ln, 'reason');
    let shortTs = ts.includes('T') ? ts.slice(ts.lastIndexOf('T') + 1) : ts;
    shortTs = shortTs.replace(/Z$/, '');
    if (shortTs.includes('.')) shortTs = shortTs.slice(0, shortTs.lastIndexOf('.'));
    rows.push(`<tr class="${DEC_CLASS[decision] || 'd-other'}"><td class="ev-ts">${htmlEscape(shortTs)}</td><td class="ev-dec">${DEC_ICON[decision] || '•'} ${htmlEscape(decision)}</td><td class="ev-mode">${htmlEscape(mode)}</td><td class="ev-reason">${htmlEscape(reason)}</td></tr>`);
  }
  return rows.join('\n');
}

function renderNowHtml(o) {
  const refresh = refreshSec();
  const cardcls = o.risk === 'high' ? 'card-high' : (o.risk === 'medium' ? 'card-medium' : 'card-low');
  let h = nowHtmlHead(refresh);
  h += `<div class="card ${cardcls}">\n`;
  h += `<div class="ctitle">${htmlEscape(o.icon)} ${htmlEscape(o.title)}</div>\n`;
  h += `<div class="cmeta">${htmlEscape(o.ts)} ・ tool=${htmlEscape(o.mode)} ・ risk=${htmlEscape(o.risk)} ・ card=${htmlEscape(o.cardId)}</div>\n`;
  if (o.action && o.action.text) {
    h += '<div class="action">\n';
    h += `<div class="action-label">🤖 AI がしようとしていること（${htmlEscape(o.action.label)}）</div>\n`;
    h += `<pre class="action-cmd">${htmlEscape(o.action.text)}</pre>\n`;
    h += '</div>\n';
    if (o.mode === 'bash' && o.explained && (o.explained.whatdo || o.explained.danger)) {
      h += '<div class="whatdo">\n';
      if (o.explained.whatdo) {
        h += `<div class="whatdo-label">${htmlEscape(o.explained.icon)} これは何をする？</div>\n`;
        h += `<p class="whatdo-body">${htmlEscape(o.explained.whatdo)}</p>\n`;
      }
      for (const d of o.explained.danger.split('\n')) {
        if (d.trim() !== '') h += `<p class="whatdo-danger">${htmlEscape(d)}</p>\n`;
      }
      h += '</div>\n';
    }
  }
  if (o.bodyLines && o.bodyLines.length) h += cardBodyToHtml(o.bodyLines) + '\n';
  h += '</div>\n';
  h += `<div class="events">\n<h2>直近の出来事 (events-${localDate()}.jsonl)</h2>\n`;
  const rows = eventsRows(o.logDir);
  if (rows) h += '<table>\n<thead><tr><th>時刻</th><th>判定</th><th>種類</th><th>理由</th></tr></thead>\n<tbody>\n' + rows + '\n</tbody>\n</table>\n';
  else h += '<p class="empty">本日の監査ログはまだありません。AI が tool を呼ぶとここに出ます。</p>\n';
  h += '</div>\n';
  h += footer(refresh);
  return h;
}

function renderNowMd(o) {
  let s = `${o.icon} ${o.title}  (risk: ${o.risk})\n`;
  s += '─────────────────────────────────────────\n';
  s += `[${o.ts}  tool=${o.mode}  card=${o.cardId}]\n`;
  if (o.action && o.action.text) {
    s += `\n▶ ${o.action.label}:\n  ${o.action.text}\n`;
    if (o.mode === 'bash' && o.explained) {
      if (o.explained.whatdo) s += `${o.explained.icon} これは何をする？\n  ${o.explained.whatdo}\n`;
      if (o.explained.danger) s += `  ${o.explained.danger}\n`;
    }
  }
  s += '\n';
  if (o.bodyLines && o.bodyLines.length) s += o.bodyLines.join('\n') + '\n';
  return s;
}

// 見張りから呼ばれる本体。{ cardId, risk } を返す（書けなかったら null）。
function explain({ mode, raw, logDir, cardsDir, forceCard }) {
  logDir = logDir || defaultLogDir();
  const target = extractTarget(mode, raw);
  const hit = forceCard ? { cardId: forceCard, risk: 'low' } : (cardsDir ? lookupCard(cardsDir, mode, target) : null);
  let cardId = hit ? hit.cardId : `default-${mode}`;
  const riskDefault = hit ? hit.risk : 'low';
  let card = cardsDir ? readCard(path.join(cardsDir, `${cardId}.md`)) : null;
  if (!card && cardsDir) {
    card = readCard(path.join(cardsDir, `default-${mode}.md`));
  }
  if (!card) return null;
  let title = card.meta.title || '（タイトル未設定）';
  const icon = card.meta.icon || '💡';
  const risk = card.meta.risk || riskDefault;
  if (mode === 'observe') {
    const t = extractToolName(raw);
    if (t) title = `AI が ${t} を使おうとしています`;
  }
  const action = extractActionText(mode, raw);
  const explained = mode === 'bash' ? explainCommand(action.rawCmd || action.text) : null;
  const o = { mode, icon, title, risk, cardId, ts: localStamp(), action, explained, bodyLines: card.bodyLines, logDir };
  try { ensureDir(logDir); } catch { return null; }
  if (!atomicWrite(path.join(logDir, 'now.md'), renderNowMd(o))) return null;
  atomicWrite(path.join(logDir, 'now.html'), renderNowHtml(o));
  return { cardId, risk };
}

function writePlaceholder(logDir) {
  logDir = logDir || defaultLogDir();
  const out = path.join(logDir, 'now.html');
  if (fs.existsSync(out)) return true;
  const refresh = refreshSec();
  try { ensureDir(logDir); } catch { return false; }
  const h = nowHtmlHead(refresh)
    + '<div class="card card-wait">\n'
    + '<div class="ctitle">🟢 見守り中です</div>\n'
    + '<div class="cmeta">まだ承認待ちのアクションはありません</div>\n'
    + '<p>AI が tool（コマンド実行・ファイル書き込みなど）を呼ぶと、ここに「いま何をしようとしているか」が表示されます。</p>\n'
    + '<p>この画面は開いたままにしておいてください。AI が動き出すと自動で切り替わります。</p>\n'
    + '</div>\n'
    + footer(refresh);
  return atomicWrite(out, h);
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
function readStdin() {
  try { return fs.readFileSync(0, 'utf8'); } catch { return ''; }
}

function parseArgs(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) { a[argv[i].slice(2)] = argv[i + 1] !== undefined ? argv[i + 1] : ''; i++; }
  }
  return a;
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const a = parseArgs(rest);
  try {
    if (cmd === 'explain') {
      const r = explain({ mode: a.mode || '', raw: readStdin(), logDir: a['log-dir'], cardsDir: a['cards-dir'], forceCard: a['force-card'] });
      if (r) process.stdout.write(`${r.cardId}\t${r.risk}\n`);
    } else if (cmd === 'placeholder') {
      writePlaceholder(a['log-dir']);
    } else if (cmd === 'explain-command') {
      const e = explainCommand(readStdin());
      if (a.format === 'parity') {
        // テスト用: 「警告があるか」「安心文があるか」「本文」を TAB 区切りで 1 行に。
        const calm = /しません|読むだけ/.test(e.whatdo);
        process.stdout.write(`${e.danger ? 'true' : 'false'}\t${calm ? 'true' : 'false'}\t${e.whatdo}\t${e.danger.replace(/\n/g, ' / ')}\n`);
      } else {
        process.stdout.write(JSON.stringify(e) + '\n');
      }
    } else if (cmd === 'render-html') {
      const mode = a.mode || '';
      const raw = readStdin();
      const logDir = a['log-dir'] || defaultLogDir();
      const action = extractActionText(mode, raw);
      const explained = mode === 'bash' ? explainCommand(action.rawCmd || action.text) : null;
      const card = a['body-path'] ? readCard(a['body-path']) : null;
      ensureDir(logDir);
      atomicWrite(path.join(logDir, 'now.html'), renderNowHtml({
        mode, icon: a.icon || '', title: a.title || '', risk: a.risk || 'low', cardId: a['card-id'] || '',
        ts: a.ts || localStamp(), action, explained, bodyLines: card ? card.bodyLines : [], logDir,
      }));
      process.stdout.write(action.text);
    }
  } catch { /* 表示専用。失敗しても見張りは止めない */ }
  process.exitCode = 0;
}

if (require.main === module) main();

module.exports = {
  explain, explainCommand, extractActionText, extractTarget, lookupCard, readCard, cardBodyToHtml,
  renderNowHtml, renderNowMd, writePlaceholder, splitSegments, limitChars, htmlEscape,
};
