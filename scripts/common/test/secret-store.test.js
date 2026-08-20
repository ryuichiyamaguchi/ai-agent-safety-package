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
