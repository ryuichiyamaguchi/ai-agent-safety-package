#!/usr/bin/env node
// secret-migrate.js — 旧平文キーを OS 標準の金庫へ移す（受講生の操作ゼロ）。
//
// 設計（secrets-encryption-design.md B-1）:
//   0. ~/.ai-safety を 700、配下の鍵らしきファイルを 600 に是正する。
//      移行が失敗して平文が残っても、まず「他ユーザーから読めない状態」にしてから先へ進む。
//   1. 金庫に既にあるなら、残っている旧平文の後片付けだけする
//      （中身が金庫と同じなら削除。違えばどちらも残して警告。ここを「何もしない」にすると、
//       一度でも読み戻しに失敗した鍵の平文が二度と片付かない ← v1.17.0 の実機不具合）
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
  return {
    vaultAvailable: vaultOk,
    items,
    leftovers: plaintextLeftovers(homeDir),
    // 「金庫へ書けなかった」履歴。doctor がこれを出すので、実機で何が起きたのかを
    // ファイル一覧を送ってもらわなくても切り分けられる。
    writeFailures: writeFailures(),
  };
}

// 旧平文を読む。UTF-8 BOM（Windows のメモ帳 / PowerShell 5.1 の Set-Content -Encoding utf8 が
// 付ける）と CRLF を落としてから返す。`.trim()` は仕様上 U+FEFF も落とすが、意図が読み取れないと
// 「BOM のせいで一致しないのでは」という調査が毎回繰り返されるので明示する。
function readLegacyValue(p) {
  try {
    const v = fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '').trim();
    return v ? { p, v } : null;
  } catch { return null; }
}

// 金庫から読み戻す。子プロセスが時間切れになったときの再試行は secret-store.get() の中に
// 入っている（未登録では再試行せず、走り切らなかったときだけ温めて 1 度やり直す）。
// ここは「例外で移行全体を止めない」ためだけの薄い包み。
function safeGet(name) {
  try { return store.get(name); } catch { return null; }
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

  // 1 件目だけが失敗する事故（v1.17.0 の Windows: gemini だけ金庫へ入らなかった）への対策。
  // 金庫の呼び出しは子プロセスなので、1 件目はプロセス起動が温まっておらず不利になる。
  // 本番の書き込みに入る前に 1 度から回しして、全件を同じ条件に揃える。
  // 所要時間も残す＝この PC で子プロセス起動に実際どれだけかかるかの実測値になる。
  const warm = store.warmUp();
  record({ event: 'warmup', ok: warm.ok, elapsedMs: warm.elapsedMs, platform: process.platform });

  for (const t of TARGETS) {
    const legacy = store.legacyPaths(t.name, homeDir).map(readLegacyValue).find(Boolean);

    let vaultValue = null;
    try { vaultValue = safeGet(t.name); } catch { vaultValue = null; }

    // 1. 既に金庫にある。
    //    ここで `continue` だけして終わると、平文が残っていても二度と片付かない。
    //    実際にこれが起きていた: 「金庫へ書く」は成功したのに直後の読み戻しが失敗して
    //    平文を残し、以後は毎回この分岐に入って平文が永久に残る（Windows 実機の
    //    gemini-api-key.txt が残り続けた経路）。金庫の値と平文が同じなら、ここで片付ける。
    if (vaultValue !== null) {
      if (!legacy || t.keepPlaintext) continue;
      if (vaultValue === legacy.v) {
        try { fs.rmSync(legacy.p, { force: true }); } catch { /* 消せなくても金庫にはある */ }
        const msg = ` ${t.label}: 金庫に入っていたので、残っていた元のファイルを削除しました。`;
        say(msg); lines.push(msg);
        record({ event: 'leftover-removed', name: t.name, file: legacy.p });
      } else {
        // 金庫と平文が別物。どちらが正しいか機械には決められないので、上書きも削除もしない。
        const msg = ` ${t.label}: 金庫の中身と元のファイルの中身が違います。安全のためどちらも残します（登録し直すと片付きます）。`;
        say(msg); lines.push(msg);
        record({ event: 'leftover-mismatch', name: t.name, file: legacy.p });
      }
      continue;
    }

    if (!legacy) continue; // 2. 旧平文も無い → 何もしない（未登録）

    try {
      store.set(t.name, legacy.v);                       // 3. 金庫へ書く
      const back = safeGet(t.name);                 // 4. 読み戻して検証（取りこぼしは 1 回だけ再試行）
      if (back !== legacy.v) {
        const msg = ` ${t.label}: 金庫へ入れた内容が一致しませんでした。ファイルはそのまま残します（次回もう一度試します）。`;
        say(msg); lines.push(msg);
        record({
          event: 'verify-failed',
          name: t.name,
          file: legacy.p,
          // 読み戻しが「走らなかった」のか「別の値が返った」のかで原因が全然違う。
          attempts: (store.takeLastFailure() || {}).attempts || null,
          readBackWasNull: back === null,
        });
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
      // ここを「黙って飛ばす」と、実機からファイル一覧をもらうまで原因が分からない
      // （v1.17.0 の Windows で実際にそうなった）。理由を必ず残す。
      // 残すのは終了コード・シグナル・所要時間・stderr の先頭だけで、鍵の値は絶対に出さない。
      const attempts = (e && e.attempts) || (store.takeLastFailure() || {}).attempts || null;
      const msg = ` ${t.label}: 金庫へ入れられませんでした。ファイルのまま動きます（次回もう一度試します）。`;
      say(msg); lines.push(msg);
      record({
        event: 'vault-write-failed',
        name: t.name,
        error: String(e && e.message ? e.message : e),
        attempts,
        logHint: path.join(logDir(), 'secret-migrate-events.jsonl'),
      });
    }
  }
  return { ok: true, lines };
}

// 直近の「金庫へ書けなかった」記録を読み返す（doctor 用）。値は記録していないので出ようがない。
// 壊れた行・読めないファイルは黙って飛ばす（診断が落ちるほうが困る）。
// 探す場所に注意: doctor（doctor.sh / doctor.ps1）は自分の診断ログを分けるために
// AI_SAFE_LOG_DIR を ~/.ai-safety/doctor-logs へ差し替えてから --status を呼ぶ。
// logDir() だけを見ると、doctor から呼んだときに本物の移行ログ（~/.ai-safety/logs）を
// 見失って「失敗は無い」と誤報する。だから既定の置き場も必ず併せて見る。
function migrateLogPaths() {
  const seen = new Set();
  const out = [];
  for (const dir of [logDir(), path.join(os.homedir(), '.ai-safety', 'logs')]) {
    const f = path.join(dir, 'secret-migrate-events.jsonl');
    if (seen.has(f)) continue;
    seen.add(f);
    out.push(f);
  }
  return out;
}

function writeFailures(limit = 5) {
  const out = [];
  for (const file of migrateLogPaths()) {
    let text = '';
    try { text = fs.readFileSync(file, 'utf8'); } catch { continue; }
    for (const line of text.split('\n')) {
      if (!line.trim()) continue;
      let ev;
      try { ev = JSON.parse(line); } catch { continue; }
      if (ev && (ev.event === 'vault-write-failed' || ev.event === 'verify-failed')) {
        out.push(Object.assign({ logFile: file }, ev));
      }
    }
  }
  out.sort((a, b) => String(a.ts || '').localeCompare(String(b.ts || '')));
  return out.slice(-limit);
}

module.exports = { migrate, status, plaintextLeftovers, hardenPermissions, writeFailures, TARGETS };

if (require.main === module) {
  const args = process.argv.slice(2);
  if (args.includes('--status')) {
    process.stdout.write(JSON.stringify(status(), null, 2) + '\n');
  } else {
    migrate({ quiet: args.includes('--quiet') });
  }
}
