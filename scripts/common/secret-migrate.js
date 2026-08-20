#!/usr/bin/env node
// secret-migrate.js — 旧平文キーを OS 標準の金庫へ移す（受講生の操作ゼロ）。
//
// 設計（secrets-encryption-design.md B-1）:
//   0. ~/.ai-safety を 700、配下の鍵らしきファイルを 600 に是正する。
//      移行が失敗して平文が残っても、まず「他ユーザーから読めない状態」にしてから先へ進む。
//   1. 金庫に既にあれば何もしない
//   2. 無ければ旧平文を探す
//   3. 見つかったら金庫へ書く
//   4. 書いた直後に読み戻して一致を検証（飛ばすと「消したのに入っていない」事故になる）
//   5. 一致したときだけ平文を削除
//   6. 一致しなければ平文を残し、警告を記録して次回再試行
//   7. 結果を日本語1行で表示
//
// 使い方:
//   node secret-migrate.js            移行を実行（既定）
//   node secret-migrate.js --status   移行せず状態だけ JSON で出す（doctor 用）
//   node secret-migrate.js --quiet    画面出力を抑える（ログには残す）
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const store = require('./secret-store.js');

// 移行対象。keepPlaintext=true のものは金庫に入れても平文を消さない。
const TARGETS = [
  { name: 'gemini', label: 'AIコーチ（Gemini）のキー' },
  { name: 'buffer', label: 'Buffer のキー' },
  { name: 'deepseek', label: 'DeepSeek のキー' },
  // パッケージ内に参照が1件も無い。外部ツールが読んでいる可能性があるので削除はしない。
  { name: 'gemini-paid', label: 'Gemini（有料）のキー', keepPlaintext: true },
];

function logDir() {
  return process.env.AI_SAFE_LOG_DIR || path.join(os.homedir(), '.ai-safety', 'logs');
}

function record(event) {
  try {
    const dir = logDir();
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    fs.appendFileSync(path.join(dir, 'secret-migrate-events.jsonl'),
      JSON.stringify(Object.assign({ ts: new Date().toISOString() }, event)) + '\n', { mode: 0o600 });
  } catch { /* ログが書けなくても移行は続ける */ }
}

// 第0ステップ: 権限の是正。~/.ai-safety を 700、鍵らしきファイルを 600 にする。
// gemini-api-key-paid.txt の 644 はここで塞がる。
function hardenPermissions(homeDir = os.homedir()) {
  const fixed = [];
  if (process.platform === 'win32') return fixed; // NTFS ACL は既定でユーザープロファイル配下が保護される
  for (const dirName of ['.ai-safety', '.deepseek-claude']) {
    const dir = path.join(homeDir, dirName);
    let st;
    try { st = fs.statSync(dir); } catch { continue; }
    if (!st.isDirectory()) continue;
    try {
      if ((st.mode & 0o777) !== 0o700) { fs.chmodSync(dir, 0o700); fixed.push(dir); }
    } catch { /* best effort */ }
    let names = [];
    try { names = fs.readdirSync(dir); } catch { continue; }
    for (const n of names) {
      if (!/(api-key|apikey|auth|token|\.dpapi)/i.test(n)) continue;
      const f = path.join(dir, n);
      try {
        const fst = fs.statSync(f);
        if (!fst.isFile()) continue;
        if ((fst.mode & 0o777) !== 0o600) { fs.chmodSync(f, 0o600); fixed.push(f); }
      } catch { /* best effort */ }
    }
  }
  if (fixed.length) record({ event: 'harden', fixed });
  return fixed;
}

// 平文の残骸を数える。環境変数の有無に関係なく必ず見る。
// （1Password 利用者は環境変数で解決するため自動移行が走らず、平文が残り続けるため）
function plaintextLeftovers(homeDir = os.homedir()) {
  const out = [];
  for (const t of TARGETS) {
    for (const p of store.legacyPaths(t.name, homeDir)) {
      let st;
      try { st = fs.statSync(p); } catch { continue; }
      if (!st.isFile() || st.size === 0) continue;
      out.push({
        name: t.name,
        label: t.label,
        file: p,
        mode: '0' + (st.mode & 0o777).toString(8),
        worldReadable: process.platform !== 'win32' && (st.mode & 0o077) !== 0,
        keepPlaintext: !!t.keepPlaintext,
      });
    }
  }
  return out;
}

// doctor 用: 移行せずに状態だけ返す。
function status(homeDir = os.homedir()) {
  const vaultOk = store.available();
  const items = TARGETS.map((t) => {
    const inVault = vaultOk ? store.exists(t.name) : false;
    const envSet = (store.ITEMS[t.name].env || []).some((k) => process.env[k] && String(process.env[k]).trim());
    return { name: t.name, label: t.label, inVault, envSet };
  });
  return { vaultAvailable: vaultOk, items, leftovers: plaintextLeftovers(homeDir) };
}

// 本体。各シークレットごとに冪等。
function migrate({ homeDir = os.homedir(), quiet = false } = {}) {
  const say = (s) => { if (!quiet) process.stdout.write(s + '\n'); };
  const lines = [];
  const fixed = hardenPermissions(homeDir);
  if (fixed.length) say(` 権限を直しました（自分だけ読める状態にしました）: ${fixed.length} 件`);

  if (!store.available()) {
    const msg = ' この PC では OS の金庫を使えませんでした。今までどおりファイルのまま動きます（doctor で状態を確認できます）。';
    say(msg);
    record({ event: 'skip', reason: 'vault unavailable', platform: process.platform });
    return { ok: false, reason: 'vault-unavailable', lines: [msg] };
  }

  for (const t of TARGETS) {
    let inVault = false;
    try { inVault = store.exists(t.name); } catch { inVault = false; }
    if (inVault) continue; // 1. 既にある → 何もしない

    const legacy = store.legacyPaths(t.name, homeDir)
      .map((p) => { try { const v = fs.readFileSync(p, 'utf8').trim(); return v ? { p, v } : null; } catch { return null; } })
      .find(Boolean);
    if (!legacy) continue; // 2. 旧平文も無い → 何もしない（未登録）

    try {
      store.set(t.name, legacy.v);                       // 3. 金庫へ書く
      const back = store.get(t.name);                    // 4. 読み戻して検証
      if (back !== legacy.v) {
        const msg = ` ${t.label}: 金庫へ入れた内容が一致しませんでした。ファイルはそのまま残します（次回もう一度試します）。`;
        say(msg); lines.push(msg);
        record({ event: 'verify-failed', name: t.name, file: legacy.p });
        continue;                                        // 6. 一致しない → 平文を残す
      }
      if (t.keepPlaintext) {
        const msg = ` ${t.label}: 金庫に入れました（このファイルは他のツールが使っている可能性があるため残します）。`;
        say(msg); lines.push(msg);
        record({ event: 'migrated-kept', name: t.name, file: legacy.p });
      } else {
        try { fs.rmSync(legacy.p, { force: true }); } catch { /* 消せなくても金庫にはある */ }  // 5. 平文削除
        const msg = ` ${t.label}: 金庫に入れました（元のファイルは削除しました）。`;
        say(msg); lines.push(msg);
        record({ event: 'migrated', name: t.name, file: legacy.p });
      }
    } catch (e) {
      const msg = ` ${t.label}: 金庫へ入れられませんでした。ファイルのまま動きます。`;
      say(msg); lines.push(msg);
      record({ event: 'error', name: t.name, error: String(e && e.message ? e.message : e) });
    }
  }
  return { ok: true, lines };
}

module.exports = { migrate, status, plaintextLeftovers, hardenPermissions, TARGETS };

if (require.main === module) {
  const args = process.argv.slice(2);
  if (args.includes('--status')) {
    process.stdout.write(JSON.stringify(status(), null, 2) + '\n');
  } else {
    migrate({ quiet: args.includes('--quiet') });
  }
}
