// image-refs.js — 画像生成 MCP（agy-image / codex-image）に渡す「参考画像」の検査。
//
// 参考画像は画像生成サービス（Google / OpenAI）へ送られる。AI が「参考画像」と称して
// ~/.ssh や .env などを外へ持ち出せないよう、次をすべて満たすものだけを通す:
//   - 作業フォルダ（MCP の起動フォルダ = process.cwd()）の中にある（.. や絶対パスで外を指せない）
//   - 実体も作業フォルダの中にある（シンボリックリンクで外を指していない。realpath で確認）
//   - 通常のファイルで、拡張子が画像（png / jpg / jpeg / webp / gif）
//   - 先頭のバイトが本当に画像（拡張子だけ画像にしたテキストを弾く）
//   - サイズ上限（既定 20MB）・枚数上限（既定 4 枚）
// 通らないものは理由つきでエラーにする（黙って外さない。何が使われたか分からなくなるため）。
'use strict';

const fs = require('fs');
const path = require('path');

const MAX_REFS = 4;
const MAX_BYTES = 20 * 1024 * 1024;
const EXT_RE = /\.(png|jpe?g|webp|gif)$/i;

function looksLikeImage(buf) {
  if (!buf || buf.length < 12) return false;
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return true; // PNG
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return true; // JPEG
  if (buf.slice(0, 4).toString('ascii') === 'GIF8') return true; // GIF
  if (buf.slice(0, 4).toString('ascii') === 'RIFF' && buf.slice(8, 12).toString('ascii') === 'WEBP') return true; // WebP
  return false;
}

function isInside(base, p) {
  const rel = path.relative(base, p);
  return !!rel && !rel.startsWith('..') && !path.isAbsolute(rel);
}

// 返り値: { ok:true, paths:[絶対パス...] } または { ok:false, message }
function checkReferenceImages(list, cwd = process.cwd()) {
  if (list == null) return { ok: true, paths: [] };
  if (!Array.isArray(list)) list = [list];
  const items = list.map((x) => (typeof x === 'string' ? x.trim() : '')).filter(Boolean);
  if (items.length === 0) return { ok: true, paths: [] };
  if (items.length > MAX_REFS) {
    return { ok: false, message: `参考画像は ${MAX_REFS} 枚までです（${items.length} 枚指定されました）。` };
  }
  let base;
  try { base = fs.realpathSync(cwd); } catch { base = path.resolve(cwd); }
  const out = [];
  for (const item of items) {
    const abs = path.resolve(base, item);
    if (!isInside(base, abs)) {
      return { ok: false, message: `参考画像は作業フォルダの中のファイルだけ使えます: ${item}` };
    }
    if (!EXT_RE.test(abs)) {
      return { ok: false, message: `参考画像は PNG / JPEG / WebP / GIF だけ使えます: ${item}` };
    }
    let real;
    try { real = fs.realpathSync(abs); } catch {
      return { ok: false, message: `参考画像が見つかりません: ${item}` };
    }
    if (!isInside(base, real)) {
      return { ok: false, message: `参考画像が作業フォルダの外を指しています（リンク）: ${item}` };
    }
    let st;
    try { st = fs.statSync(real); } catch { return { ok: false, message: `参考画像を読めません: ${item}` }; }
    if (!st.isFile()) return { ok: false, message: `参考画像がファイルではありません: ${item}` };
    if (st.size > MAX_BYTES) return { ok: false, message: `参考画像が大きすぎます（20MB まで）: ${item}` };
    let head = Buffer.alloc(0);
    try {
      const fd = fs.openSync(real, 'r');
      head = Buffer.alloc(16);
      fs.readSync(fd, head, 0, 16, 0);
      fs.closeSync(fd);
    } catch { return { ok: false, message: `参考画像を読めません: ${item}` }; }
    if (!looksLikeImage(head)) return { ok: false, message: `参考画像の中身が画像ではありません: ${item}` };
    out.push(real);
  }
  return { ok: true, paths: out };
}

// MCP の inputSchema に足す共通の定義。
const SCHEMA = {
  type: 'array',
  items: { type: 'string' },
  description: '参考にする画像（作業フォルダ内のパス。最大 4 枚。例: ["練習/1_genzai.png", "練習/2_sankou.png"]）。'
    + '今のサイトのスクショと参考サイトのスクショを渡して「2 枚目の雰囲気で 1 枚目を作り直す」などに使う。'
    + '画像を言葉で説明し直さず、そのまま渡すこと。',
};

module.exports = { checkReferenceImages, looksLikeImage, MAX_REFS, MAX_BYTES, SCHEMA };
