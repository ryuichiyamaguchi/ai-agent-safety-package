// secret-store / secret-migrate / clipboard-mask の検査。
//
// 金庫のモックは作らない（設計方針）。macOS では本物のキーチェーンを、テスト専用の
// service 接頭辞 "ai-safety-test-<pid>." で使い、必ず後始末する。保存方式は本番と同一。
// macOS 以外では金庫を使うテストを skip する（Windows DPAPI は Windows 実機でのみ検証可能）。
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const PREFIX = `ai-safety-test-${process.pid}.`;
process.env.AI_SAFE_KEYCHAIN_PREFIX = PREFIX;

const store = require('../secret-store.js');
const { maskText } = require('../secret-patterns.js');

const canVault = process.platform === 'darwin' && store.available();
const skipVault = canVault ? false : 'OS の金庫を使えない環境のため skip（Windows DPAPI は Windows 実機で検証）';

function cleanup(names) {
  for (const n of names) { try { store.remove(n); } catch { /* ignore */ } }
}

test('固定表にない名前は受け付けない', () => {
  assert.throws(() => store.get('unknown-secret'), /unknown secret name/);
  assert.throws(() => store.set('unknown-secret', 'x'), /unknown secret name/);
});

test('空の値は保存しない', { skip: skipVault }, () => {
  assert.throws(() => store.set('gemini', ''), /empty value/);
});

test('金庫へ set → get で往復する（ASCII / 非 ASCII / 記号）', { skip: skipVault }, () => {
  const cases = [
    'AIzaSyDUMMY_key-1234567890abcdefg',
    '{"t":"株式会社テスト 東京都","n":"03-1234-5678"}',
    'a"b\'c$d`e|f&g;h',
    // 64 桁の 16 進（封筒が無いと `security` の hex 出力と区別できない値）
    'a'.repeat(64),
  ];
  for (const v of cases) {
    store.set('maskmap', v);
    assert.strictEqual(store.get('maskmap'), v, `round trip failed: ${v.slice(0, 20)}`);
  }
  cleanup(['maskmap']);
});

test('remove すると exists が false になる', { skip: skipVault }, () => {
  store.set('buffer', 'buffer-token-dummy-1234567890');
  assert.strictEqual(store.exists('buffer'), true);
  store.remove('buffer');
  assert.strictEqual(store.exists('buffer'), false);
});

test('resolve の優先順位は 環境変数 → 金庫 → 旧平文', { skip: skipVault }, () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-home-'));
  fs.mkdirSync(path.join(home, '.ai-safety'), { recursive: true });
  fs.writeFileSync(path.join(home, '.ai-safety', 'gemini-api-key.txt'), 'LEGACY-VALUE');
  try {
    cleanup(['gemini']);
    // 1. 旧平文だけ
    let r = store.resolve('gemini', { env: {}, homeDir: home });
    assert.deepStrictEqual([r.value, r.source], ['LEGACY-VALUE', 'legacy']);

    // 2. 金庫があれば金庫が勝つ
    store.set('gemini', 'VAULT-VALUE');
    r = store.resolve('gemini', { env: {}, homeDir: home });
    assert.deepStrictEqual([r.value, r.source], ['VAULT-VALUE', 'vault']);

    // 3. 環境変数があれば環境変数が勝つ（1Password の op run がここで解決する）
    r = store.resolve('gemini', { env: { GEMINI_API_KEY: 'ENV-VALUE' }, homeDir: home });
    assert.deepStrictEqual([r.value, r.source], ['ENV-VALUE', 'env']);

    // 4. どこにも無ければ null
    cleanup(['gemini']);
    fs.rmSync(path.join(home, '.ai-safety', 'gemini-api-key.txt'));
    r = store.resolve('gemini', { env: {}, homeDir: home });
    assert.deepStrictEqual([r.value, r.source], [null, null]);
  } finally {
    cleanup(['gemini']);
    fs.rmSync(home, { recursive: true, force: true });
  }
});

// ---- 自動移行 -------------------------------------------------------------
test('移行: 金庫へ書き→読み戻し一致→平文削除', { skip: skipVault }, () => {
  const migrate = require('../secret-migrate.js');
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-home-'));
  const dir = path.join(home, '.ai-safety');
  fs.mkdirSync(dir, { recursive: true });
  const legacy = path.join(dir, 'gemini-api-key.txt');
  const paid = path.join(dir, 'gemini-api-key-paid.txt');
  fs.writeFileSync(legacy, 'MIGRATE-ME-1234567890');
  fs.writeFileSync(paid, 'PAID-KEY-1234567890');
  fs.chmodSync(paid, 0o644); // 実機で見つかった 644 を再現
  try {
    cleanup(['gemini', 'gemini-paid']);
    const r = migrate.migrate({ homeDir: home, quiet: true });
    assert.strictEqual(r.ok, true);

    // 移行対象は金庫へ入り、平文は消える
    assert.strictEqual(store.get('gemini'), 'MIGRATE-ME-1234567890');
    assert.strictEqual(fs.existsSync(legacy), false);

    // keepPlaintext のものは金庫へ入るが平文は残る。ただし権限は 600 に是正される
    assert.strictEqual(store.get('gemini-paid'), 'PAID-KEY-1234567890');
    assert.strictEqual(fs.existsSync(paid), true);
    assert.strictEqual(fs.statSync(paid).mode & 0o777, 0o600, '644 は 600 に是正される');
    assert.strictEqual(fs.statSync(dir).mode & 0o777, 0o700, 'ディレクトリは 700 に是正される');

    // 2 回目は冪等（何も壊さない）
    migrate.migrate({ homeDir: home, quiet: true });
    assert.strictEqual(store.get('gemini'), 'MIGRATE-ME-1234567890');
  } finally {
    cleanup(['gemini', 'gemini-paid']);
    fs.rmSync(home, { recursive: true, force: true });
  }
});

// v1.17.1 回帰: Windows 実機で「DeepSeek は金庫に入ったのに Gemini の平文だけ残る」が起きた。
// 経路は「金庫へ書くのは成功 → 直後の読み戻しが取りこぼして平文を残す → 以後は
// 『既に金庫にある』分岐に入って二度と片付かない」。金庫の内容と平文が同じなら片付ける。
test('移行: 既に金庫にある鍵の平文が残っていたら片付ける（v1.17.0 で永久に残った経路）', { skip: skipVault }, () => {
  const migrate = require('../secret-migrate.js');
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-home-'));
  const dir = path.join(home, '.ai-safety');
  fs.mkdirSync(dir, { recursive: true });
  const legacy = path.join(dir, 'gemini-api-key.txt');
  try {
    cleanup(['gemini']);
    // 「金庫には入っているが平文も残っている」＝前回の読み戻し失敗のあとの状態を再現する。
    store.set('gemini', 'STUCK-KEY-1234567890');
    fs.writeFileSync(legacy, 'STUCK-KEY-1234567890');

    migrate.migrate({ homeDir: home, quiet: true });
    assert.strictEqual(fs.existsSync(legacy), false, '金庫と同じ中身の平文は片付ける');
    assert.strictEqual(store.get('gemini'), 'STUCK-KEY-1234567890', '金庫の中身は触らない');
  } finally {
    cleanup(['gemini']);
    fs.rmSync(home, { recursive: true, force: true });
  }
});

// Windows で作られた平文は BOM 付き / CRLF になりうる。金庫へ入れる値と読み戻す値が
// そこでズレると検証が通らず平文が残る。BOM も改行も落としてから扱うことを固定する。
test('移行: BOM 付き・CRLF の平文でも金庫へ移り、平文が消える', { skip: skipVault }, () => {
  const migrate = require('../secret-migrate.js');
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-home-'));
  const dir = path.join(home, '.ai-safety');
  fs.mkdirSync(dir, { recursive: true });
  const legacy = path.join(dir, 'gemini-api-key.txt');
  try {
    cleanup(['gemini']);
    // メモ帳 / PowerShell 5.1 の `Set-Content -Encoding utf8` が作る形。
    fs.writeFileSync(legacy, Buffer.concat([
      Buffer.from([0xEF, 0xBB, 0xBF]),
      Buffer.from('AIzaBOM-CRLF-KEY-1234567890\r\n', 'utf8'),
    ]));

    migrate.migrate({ homeDir: home, quiet: true });
    assert.strictEqual(store.get('gemini'), 'AIzaBOM-CRLF-KEY-1234567890', 'BOM と CRLF は落として保存する');
    assert.strictEqual(fs.existsSync(legacy), false, '検証が通れば平文は消える');
  } finally {
    cleanup(['gemini']);
    fs.rmSync(home, { recursive: true, force: true });
  }
});

// 金庫の中身と平文の中身が違うときは、どちらが正しいか機械には決められない。
// 平文を黙って消すのも、金庫を黙って上書きするのも事故なので、両方残して警告する。
test('移行: 金庫と平文の中身が違うときは両方残す', { skip: skipVault }, () => {
  const migrate = require('../secret-migrate.js');
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-home-'));
  const dir = path.join(home, '.ai-safety');
  fs.mkdirSync(dir, { recursive: true });
  const legacy = path.join(dir, 'gemini-api-key.txt');
  try {
    cleanup(['gemini']);
    store.set('gemini', 'VAULT-SIDE-1234567890');
    fs.writeFileSync(legacy, 'PLAINTEXT-SIDE-1234567890');

    const r = migrate.migrate({ homeDir: home, quiet: true });
    assert.strictEqual(fs.existsSync(legacy), true, '違う値の平文は消さない');
    assert.strictEqual(store.get('gemini'), 'VAULT-SIDE-1234567890', '金庫も上書きしない');
    assert.ok(r.lines.some((l) => l.includes('違います')), '食い違いは必ず知らせる');
  } finally {
    cleanup(['gemini']);
    fs.rmSync(home, { recursive: true, force: true });
  }
});

// keepPlaintext（gemini-paid）にだけ「消さない」が効いていること。gemini / deepseek に
// 波及していたら、この 2 本は移行しても平文が残ってしまう。
test('移行: keepPlaintext は gemini-paid だけに効く', () => {
  const migrate = require('../secret-migrate.js');
  const keep = migrate.TARGETS.filter((t) => t.keepPlaintext).map((t) => t.name);
  assert.deepStrictEqual(keep, ['gemini-paid']);
});

// ---- 金庫への「書き込み」が失敗する状況 ------------------------------------
// v1.17.1 の訂正。Windows 実機に `deepseek.dpapi` はあるのに `gemini.dpapi` が無かった
// ＝移行の 1 件目（gemini）は書き込みそのものに失敗していた。旧実装は一発勝負で、
// しかも失敗の理由を捨てていたため原因を追えなかった。
//
// mac で失敗を人工的に作る方法: 制限時間を極端に短くする（AI_SAFE_VAULT_TIMEOUT_MS=1）。
// 子プロセスは 1ms では終われないので必ず時間切れになる。金庫の実装（`security` の呼び方・
// 封筒の形）には一切触れずに「呼び出しが失敗する状況」だけを作れる。
// この環境変数は失敗させる方向にしか働かず、失敗時は平文を残して記録するだけなので、
// 秘密が漏れる向きには使えない。
function withVaultTimeouts(first, retry, fn) {
  const keys = ['AI_SAFE_VAULT_TIMEOUT_MS', 'AI_SAFE_VAULT_TIMEOUT_RETRY_MS'];
  const prev = keys.map((k) => process.env[k]);
  process.env.AI_SAFE_VAULT_TIMEOUT_MS = String(first);
  process.env.AI_SAFE_VAULT_TIMEOUT_RETRY_MS = String(retry);
  // secret-store.js は制限時間を読み込み時に固定するので、読み直させる。
  const storePath = require.resolve('../secret-store.js');
  const migratePath = require.resolve('../secret-migrate.js');
  delete require.cache[storePath];
  delete require.cache[migratePath];
  try {
    return fn(require(migratePath), require(storePath));
  } finally {
    keys.forEach((k, i) => { if (prev[i] === undefined) delete process.env[k]; else process.env[k] = prev[i]; });
    delete require.cache[storePath];
    delete require.cache[migratePath];
    require(storePath);
  }
}

test('金庫へ書けないときは平文を消さず、理由を記録する', { skip: skipVault }, () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-home-'));
  const logs = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-logs-'));
  const dir = path.join(home, '.ai-safety');
  fs.mkdirSync(dir, { recursive: true });
  const legacy = path.join(dir, 'gemini-api-key.txt');
  fs.writeFileSync(legacy, 'MUST-SURVIVE-1234567890');
  const prevLog = process.env.AI_SAFE_LOG_DIR;
  process.env.AI_SAFE_LOG_DIR = logs;
  try {
    cleanup(['gemini']);
    // 1 回目も 2 回目も間に合わない ＝ 書き込みが完全に失敗する状況。
    const r = withVaultTimeouts(1, 1, (migrate) => migrate.migrate({ homeDir: home, quiet: true }));

    assert.strictEqual(fs.existsSync(legacy), true, '金庫へ入っていないのに平文を消してはいけない');
    assert.ok(r.lines.some((l) => l.includes('金庫へ入れられませんでした')), '失敗を利用者に伝えること');

    const log = fs.readFileSync(path.join(logs, 'secret-migrate-events.jsonl'), 'utf8');
    const events = log.split('\n').filter(Boolean).map((l) => JSON.parse(l));
    const failed = events.find((e) => e.event === 'vault-write-failed' && e.name === 'gemini');
    assert.ok(failed, '失敗が記録に残っていない（v1.17.0 はここが空だったので原因を追えなかった）');
    assert.ok(Array.isArray(failed.attempts) && failed.attempts.length === 2,
      `1 回目と 2 回目の両方が記録されること: ${JSON.stringify(failed.attempts)}`);
    for (const a of failed.attempts) {
      assert.ok(typeof a.elapsedMs === 'number', '所要時間を残すこと');
      assert.ok(typeof a.timeoutMs === 'number', '使った制限時間を残すこと');
      assert.ok('status' in a && 'errorCode' in a && 'stderr' in a, '終了コード・原因・stderr を残すこと');
    }
    assert.ok(failed.attempts[0].warmUp, '2 回目の前にウォームアップした記録が残ること');
    // 記録に鍵の値そのものが混ざっていないこと（ログは講師に送られる前提）。
    assert.ok(!log.includes('MUST-SURVIVE-1234567890'), '記録に鍵の値を書いてはいけない');
  } finally {
    if (prevLog === undefined) delete process.env.AI_SAFE_LOG_DIR; else process.env.AI_SAFE_LOG_DIR = prevLog;
    cleanup(['gemini']);
    fs.rmSync(home, { recursive: true, force: true });
    fs.rmSync(logs, { recursive: true, force: true });
  }
});

test('1 回目が間に合わなくても、2 回目で金庫へ入れば平文は消える', { skip: skipVault }, () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-home-'));
  const logs = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-logs-'));
  const dir = path.join(home, '.ai-safety');
  fs.mkdirSync(dir, { recursive: true });
  const legacy = path.join(dir, 'gemini-api-key.txt');
  fs.writeFileSync(legacy, 'RETRY-WINS-1234567890');
  const prevLog = process.env.AI_SAFE_LOG_DIR;
  process.env.AI_SAFE_LOG_DIR = logs;
  try {
    cleanup(['gemini']);
    // 1 回目は必ず時間切れ（1ms）。2 回目は通常どおりの余裕（30 秒）。
    withVaultTimeouts(1, 30000, (migrate, storeReloaded) => {
      migrate.migrate({ homeDir: home, quiet: true });
      assert.strictEqual(storeReloaded.get('gemini'), 'RETRY-WINS-1234567890',
        '再試行で金庫へ入ること（v1.17.0 は 1 回目の失敗でそのまま諦めていた）');
    });
    assert.strictEqual(fs.existsSync(legacy), false, '金庫へ入ったら平文は消える');
  } finally {
    if (prevLog === undefined) delete process.env.AI_SAFE_LOG_DIR; else process.env.AI_SAFE_LOG_DIR = prevLog;
    cleanup(['gemini']);
    fs.rmSync(home, { recursive: true, force: true });
    fs.rmSync(logs, { recursive: true, force: true });
  }
});

test('doctor 用 status は金庫への書き込み失敗を返す', { skip: skipVault }, () => {
  const migrate = require('../secret-migrate.js');
  const logs = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-logs-'));
  const prevLog = process.env.AI_SAFE_LOG_DIR;
  process.env.AI_SAFE_LOG_DIR = logs;
  try {
    fs.writeFileSync(path.join(logs, 'secret-migrate-events.jsonl'), [
      JSON.stringify({ ts: '2026-08-21T00:00:00.000Z', event: 'warmup', ok: true, elapsedMs: 12 }),
      JSON.stringify({ ts: '2026-08-21T00:00:01.000Z', event: 'vault-write-failed', name: 'gemini', attempts: [{ attempt: 1, status: null, errorCode: 'ETIMEDOUT', timeoutMs: 15000, elapsedMs: 15002, stderr: '' }] }),
      'これは壊れた行なので飛ばす',
    ].join('\n') + '\n');
    const st = migrate.status(os.homedir());
    assert.ok(Array.isArray(st.writeFailures), 'status に writeFailures が無い');
    assert.strictEqual(st.writeFailures.length, 1);
    assert.strictEqual(st.writeFailures[0].name, 'gemini');
    assert.strictEqual(st.writeFailures[0].attempts[0].errorCode, 'ETIMEDOUT');
  } finally {
    if (prevLog === undefined) delete process.env.AI_SAFE_LOG_DIR; else process.env.AI_SAFE_LOG_DIR = prevLog;
    fs.rmSync(logs, { recursive: true, force: true });
  }
});

// doctor は自分の診断ログを分けるために AI_SAFE_LOG_DIR を doctor-logs へ差し替えてから
// --status を呼ぶ。移行ログの既定の置き場も併せて見ないと、doctor から呼んだときだけ
// 「失敗は無い」と誤報する（実際に踏んだ）。
test('writeFailures は AI_SAFE_LOG_DIR が差し替えられていても既定の置き場を見る', () => {
  const migrate = require('../secret-migrate.js');
  const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-fakehome-'));
  const elsewhere = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-doctorlogs-'));
  const defaultLogs = path.join(fakeHome, '.ai-safety', 'logs');
  fs.mkdirSync(defaultLogs, { recursive: true });
  fs.writeFileSync(path.join(defaultLogs, 'secret-migrate-events.jsonl'),
    JSON.stringify({ ts: '2026-08-21T01:18:20.000Z', event: 'vault-write-failed', name: 'gemini', attempts: [] }) + '\n');
  const prevLog = process.env.AI_SAFE_LOG_DIR;
  const realHome = os.homedir;
  process.env.AI_SAFE_LOG_DIR = elsewhere; // doctor が差し替えた状態を再現
  os.homedir = () => fakeHome;
  try {
    const found = migrate.writeFailures();
    assert.strictEqual(found.length, 1, 'AI_SAFE_LOG_DIR が別を指していても既定の置き場から拾うこと');
    assert.strictEqual(found[0].name, 'gemini');
    assert.ok(found[0].logFile.startsWith(defaultLogs), 'どのファイルから拾ったかを添えること');
  } finally {
    os.homedir = realHome;
    if (prevLog === undefined) delete process.env.AI_SAFE_LOG_DIR; else process.env.AI_SAFE_LOG_DIR = prevLog;
    fs.rmSync(fakeHome, { recursive: true, force: true });
    fs.rmSync(elsewhere, { recursive: true, force: true });
  }
});

test('ウォームアップは所要時間を返す（この PC の子プロセス起動コストの実測値）', { skip: skipVault }, () => {
  const w = store.warmUp();
  assert.strictEqual(typeof w.elapsedMs, 'number');
  assert.ok(w.elapsedMs >= 0);
  assert.strictEqual(w.ok, true, '金庫が使える環境ならウォームアップも通ること');
});

test('再試行の制限時間は 1 回目より長い', () => {
  assert.ok(store.VAULT_TIMEOUT_RETRY_MS > store.VAULT_TIMEOUT_MS,
    '2 回目は「起動が遅い PC」を救うためのものなので必ず長くする');
  assert.ok(store.VAULT_TIMEOUT_RETRY_MS >= 60000, '起動が数十秒に伸びる環境を想定した長さにする');
});

test('doctor 用 status は環境変数の有無に関係なく平文残骸を報告する', { skip: skipVault }, () => {
  const migrate = require('../secret-migrate.js');
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-home-'));
  fs.mkdirSync(path.join(home, '.ai-safety'), { recursive: true });
  const legacy = path.join(home, '.ai-safety', 'buffer-api-key.txt');
  fs.writeFileSync(legacy, 'LEFTOVER-PLAINTEXT');
  const prev = process.env.BUFFER_ACCESS_TOKEN;
  process.env.BUFFER_ACCESS_TOKEN = 'from-1password';
  try {
    const st = migrate.status(home);
    const hit = st.leftovers.find((l) => l.file === legacy);
    assert.ok(hit, '環境変数があっても平文の残骸は必ず見つける');
    assert.strictEqual(hit.name, 'buffer');
  } finally {
    if (prev === undefined) delete process.env.BUFFER_ACCESS_TOKEN; else process.env.BUFFER_ACCESS_TOKEN = prev;
    fs.rmSync(home, { recursive: true, force: true });
  }
});

// ---- マスキングツール -----------------------------------------------------
const SAMPLE = [
  '田中さん（tanaka@example.co.jp）から連絡がありました。',
  '電話は 090-1234-5678、郵便番号は 〒150-0001 です。',
  '折り返しは sales@example.co.jp へお願いします（tanaka@example.co.jp にも CC）。',
].join('\n');

function maskRoundTrip(text, terms = []) {
  let seq = 0;
  const entries = {};
  const byValue = new Map();
  const alloc = (v) => {
    const s = String(v);
    if (byValue.has(s)) return byValue.get(s);
    seq += 1;
    const t = `__SECRET_${seq}__`;
    byValue.set(s, t); entries[t] = s;
    return t;
  };
  const { masked } = maskText(text, { alloc, denylistTerms: terms, pii: 'strict' });
  const restored = masked.replace(/__SECRET_(\d+)__/g, (m) => (m in entries ? entries[m] : m));
  return { masked, restored, entries };
}

test('マスク→復元で原文が完全に復元される（往復テスト）', () => {
  const { masked, restored, entries } = maskRoundTrip(SAMPLE, ['株式会社テスト']);
  assert.ok(!masked.includes('tanaka@example.co.jp'), 'メールアドレスが残っている');
  assert.ok(!masked.includes('090-1234-5678'), '電話番号が残っている');
  assert.ok(/__SECRET_\d+__/.test(masked), 'トークンが発行されていない');
  assert.strictEqual(restored, SAMPLE, 'マスク→復元で原文に戻らない');
  // 同じ原文には同じトークン（安定したトークン）
  const tokensForTanaka = Object.entries(entries).filter(([, v]) => v === 'tanaka@example.co.jp');
  assert.strictEqual(tokensForTanaka.length, 1, '同じ値には同じトークンを使い回す');
});

test('denylist に登録した語も復元できる', () => {
  const text = '見積書を 田中商事 さんへ送ります。担当は 田中商事 の佐藤さん。';
  const { masked, restored } = maskRoundTrip(text, ['田中商事']);
  assert.ok(!masked.includes('田中商事'));
  assert.strictEqual(restored, text);
});

test('API キーは復元できないマスクにする（トークン化しない）', () => {
  const text = 'キーは sk-ant-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 です。';
  const { masked } = maskRoundTrip(text);
  assert.ok(masked.includes('[MASKED:anthropic]'), 'ハードな秘密は [MASKED:...] のまま');
  assert.ok(!masked.includes('sk-ant-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'));
});

test('v1.17.0 で足した各社キーの形を既定で検出する', () => {
  const samples = {
    // 検体は必ず連結で組み立てる。本物と同じ形の文字列をソースに直書きすると
    // GitHub のプッシュ保護（秘密スキャン）が実際に検体をブロックする（v1.17.0 で遭遇）。
    'Stripe': 'sk_' + 'live_' + 'abcdefghijklmnopqrstuvwx',
    'Google OAuth': 'GOCSPX' + '-' + 'abcdefghijklmnopqrstuvwxyz',
    'SendGrid': 'SG' + '.abcdefghijklmnopqrst.' + 'abcdefghijklmnopqrstuvwx',
    'npm': 'npm_' + 'a'.repeat(36),
    'Hugging Face': 'hf_' + 'a'.repeat(34),
    'Groq': 'gsk_' + 'a'.repeat(44),
    'xAI': 'xai-' + 'a'.repeat(44),
    'GitLab': 'glpat-abcdefghijklmnopqrstu',
    'Supabase': 'sbp_' + 'a'.repeat(40),
    'Linear': 'lin_api_' + 'a'.repeat(40),
    'Telegram': '123456789:' + 'A'.repeat(35),
    'Slack webhook': 'https://hooks.slack.com/services/T0000000/B0000000/abcdefghijklmnop',
  };
  for (const [name, sample] of Object.entries(samples)) {
    const r = maskText(`token = ${sample}`, {});
    assert.ok(!r.masked.includes(sample), `${name} が伏せられていない: ${r.masked}`);
  }
});

test('Authorization ヘッダと URL 埋め込みの資格情報を伏せる', () => {
  const r1 = maskText('Authorization: Bearer abcdefghijklmnopqrstuvwxyz', {});
  assert.ok(r1.masked.includes('[MASKED:bearer]'));
  assert.ok(!r1.masked.includes('abcdefghijklmnopqrstuvwxyz'));

  const r2 = maskText('接続先は https://admin:s3cr3tpassword@db.example.com/app です', {});
  assert.ok(!r2.masked.includes('s3cr3tpassword'));
  assert.ok(!r2.masked.includes('admin:'));
  assert.ok(r2.masked.includes('db.example.com'), 'ホスト名は残す');
});

test('文脈語ゲートの既定は変えない（gateway 経路の挙動は従来どおり）', () => {
  const noCtx = maskText('番号は 090-1234-5678 です', {});
  assert.ok(noCtx.masked.includes('090-1234-5678'), '既定では文脈語なしの電話番号は伏せない');
  const strict = maskText('番号は 090-1234-5678 です', { alloc: (v) => `__SECRET_1__`, pii: 'strict' });
  assert.ok(!strict.masked.includes('090-1234-5678'), 'strict では文脈語なしでも伏せる');
});

test('対応表が平文ファイルに保存されていないこと', { skip: skipVault }, () => {
  const clip = require('../clipboard-mask.js');
  const secret = 'tanaka-unique-probe@example.co.jp';
  clip.saveMap({ seq: 1, entries: { '__SECRET_1__': secret } });
  try {
    // 金庫からは読める
    const loaded = clip.loadMap();
    assert.strictEqual(loaded.entries['__SECRET_1__'], secret);

    // ホーム配下のどのファイルにも原文が書かれていないこと（.ai-safety / .deepseek-claude を走査）
    const roots = [path.join(os.homedir(), '.ai-safety'), path.join(os.homedir(), '.deepseek-claude')];
    for (const root of roots) {
      if (!fs.existsSync(root)) continue;
      const stack = [root];
      while (stack.length) {
        const cur = stack.pop();
        let st;
        try { st = fs.statSync(cur); } catch { continue; }
        if (st.isDirectory()) {
          for (const n of fs.readdirSync(cur)) stack.push(path.join(cur, n));
          continue;
        }
        if (st.size > 4 * 1024 * 1024) continue;
        let body = '';
        try { body = fs.readFileSync(cur, 'utf8'); } catch { continue; }
        assert.ok(!body.includes(secret), `対応表の原文が平文で見つかった: ${cur}`);
      }
    }
  } finally {
    clip.clearMap();
  }
});

test('対応表は有効期限が切れたら使わない', { skip: skipVault }, () => {
  const clip = require('../clipboard-mask.js');
  const prev = process.env.AI_SAFE_MASK_TTL_MIN;
  try {
    // 期限内なら読める
    process.env.AI_SAFE_MASK_TTL_MIN = '60';
    clip.saveMap({ seq: 1, entries: { '__SECRET_1__': 'x@example.com' } });
    assert.ok(clip.loadMap() && !clip.loadMap().expired);
    assert.ok(clip.ttlMs() === 60 * 60 * 1000);

    // 期限切れの対応表は expired として返る（復元側が「期限切れです」と案内して捨てる）。
    // 時計を TTL より先へ進めて再現する。
    const realNow = Date.now;
    try {
      Date.now = () => realNow() + 61 * 60 * 1000;
      assert.deepStrictEqual(clip.loadMap(), { expired: true });
    } finally {
      Date.now = realNow;
    }
  } finally {
    if (prev === undefined) delete process.env.AI_SAFE_MASK_TTL_MIN; else process.env.AI_SAFE_MASK_TTL_MIN = prev;
    clip.clearMap();
  }
});

test('限界を伝える1行が必ず用意されている', () => {
  const clip = require('../clipboard-mask.js');
  assert.match(clip.LIMIT_LINE, /知っている形/);
  assert.match(clip.LIMIT_LINE, /安全、ではありません/);
});

test.after(() => cleanup(['gemini', 'buffer', 'deepseek', 'gemini-paid', 'maskmap']));
