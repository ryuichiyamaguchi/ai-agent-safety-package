'use strict';
// モデル自由選択モード（--free / -Free・2026-08-24 依頼者裁定）の検査。
// 「無料モデル利用時は送信検査 Gateway を通らないことを許容する。ただし deny 床
// （permission 表・edit 表・秘密読取保護・.ai-safety 書込禁止・external_directory）は維持する」
// という裁定どおりに設定が生成されることを固定する。
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('node:path');

// この検査は「鍵が未登録なら MCP に載せない」系の生成にも触れる。opencode-config は
// OS の金庫も参照するので、検査専用の接頭辞へ逃がして実機の登録状態から切り離す。
process.env.AI_SAFE_KEYCHAIN_PREFIX = 'ai-safety-test-opencode-free.';
const {
  buildOpenCodeConfig,
  verifyResolvedConfig,
} = require('../opencode-config.js');

const MONITOR_PLUGIN = '/opt/bouncer/opencode-bouncer-monitor.mjs';
const TEST_TOKEN = 'test-gateway-token-0123456789abcdef';

function deepseekConfig(options = {}) {
  return buildOpenCodeConfig({
    monitorPlugin: MONITOR_PLUGIN,
    gatewayToken: TEST_TOKEN,
    env: {},
    ...options,
  });
}

function freeConfig(options = {}) {
  return buildOpenCodeConfig({
    monitorPlugin: MONITOR_PLUGIN,
    free: true,
    env: {},
    ...options,
  });
}

test('free モードは provider / モデル固定を一切注入しない', () => {
  const config = freeConfig();
  assert.ok(!('provider' in config), 'free なのに provider が注入されている');
  assert.ok(!('enabled_providers' in config), 'free なのに enabled_providers で絞っている');
  assert.ok(!('model' in config), 'free なのにモデルが固定されている');
  assert.ok(!('small_model' in config), 'free なのに small_model が固定されている');
  assert.strictEqual(config.agent.bouncer.model, undefined, 'free なのに bouncer のモデルが固定されている');
  assert.strictEqual(config.agent['bouncer-helper'].model, undefined, 'free なのに helper のモデルが固定されている');
  assert.ok(!JSON.stringify(config).includes('bouncer-deepseek'), 'free なのに DeepSeek 経路が残っている');
});

test('free モードは gateway 合言葉なしでも生成できる（DeepSeek 経路は従来どおり拒否）', () => {
  const saved = process.env.DS_GATEWAY_TOKEN;
  delete process.env.DS_GATEWAY_TOKEN;
  try {
    // free は合言葉不要（Gateway を使わない）。
    assert.doesNotThrow(() => buildOpenCodeConfig({ monitorPlugin: MONITOR_PLUGIN, free: true, env: {} }));
    // DeepSeek 経路の fail-closed（合言葉なしの設定生成拒否）は 1 mm も緩めない。
    assert.throws(() => buildOpenCodeConfig({ monitorPlugin: MONITOR_PLUGIN, env: {} }),
      /DS_GATEWAY_TOKEN/);
  } finally {
    if (saved !== undefined) process.env.DS_GATEWAY_TOKEN = saved;
  }
});

test('free モードの permission 表は DeepSeek 版と並び順まで含めて同一', () => {
  const ds = deepseekConfig();
  const free = freeConfig();
  // JSON.stringify はキーの並び順を保つ。OpenCode の権限評価は「最後に一致したルールが
  // 勝つ」ので、並び順まで一致していないと安全性の同一とは言えない。
  assert.strictEqual(JSON.stringify(free.permission), JSON.stringify(ds.permission),
    'free の permission 表が DeepSeek 版と一致しない');
});

test('free モードでも share 無効・自動更新無効・安全プラグイン・ハーネスは同一', () => {
  const ds = deepseekConfig();
  const free = freeConfig();
  assert.strictEqual(free.share, 'disabled');
  assert.strictEqual(free.autoupdate, false);
  assert.deepStrictEqual(free.instructions, ds.instructions);
  assert.deepStrictEqual(free.plugin, ds.plugin);
  assert.strictEqual(free.default_agent, 'bouncer');
  // 組み込み primary（build / plan）の無効化も共通（task 制限の迂回口を残さない）。
  assert.deepStrictEqual(free.agent.build, { disable: true });
  assert.deepStrictEqual(free.agent.plan, { disable: true });
  assert.deepStrictEqual(free.agent.bouncer.permission, ds.agent.bouncer.permission);
});

test('free モードの設定も起動前検査（deny 床の検証）をそのまま通る', () => {
  assert.deepStrictEqual(verifyResolvedConfig(freeConfig()), []);
  // longrun との組み合わせでも床の検証が成立する（メニューからは到達しないが CLI では可能）。
  assert.deepStrictEqual(
    verifyResolvedConfig(freeConfig({ longrun: true }), { longrun: true }), []);
});

test('free + longrun でも permission 表は DeepSeek 版 longrun と同一', () => {
  const ds = deepseekConfig({ longrun: true });
  const free = freeConfig({ longrun: true });
  assert.strictEqual(JSON.stringify(free.permission), JSON.stringify(ds.permission));
});

test('CLI は --free で合言葉なしでも設定を出し、provider を含めない', () => {
  const { execFileSync } = require('node:child_process');
  const script = path.join(__dirname, '..', 'opencode-config.js');
  const output = execFileSync(process.execPath,
    [script, '--free', '--monitor-plugin', MONITOR_PLUGIN],
    { encoding: 'utf8', env: { ...process.env, DS_GATEWAY_TOKEN: '' } });
  const config = JSON.parse(output);
  assert.ok(!('provider' in config));
  assert.ok(!('model' in config));
  assert.ok(!JSON.stringify(config).includes('bouncer-deepseek'));
  // 床の表は載っていること（--free が permission を痩せさせない）。
  assert.strictEqual(config.permission.bash['rm *'], 'deny');
  assert.strictEqual(config.permission.bash['sudo *'], 'deny');
  assert.strictEqual(config.permission.edit['**/.ai-safety/**'], 'deny');
});

// --- ランチャー側の配線（ソース照合） ------------------------------------------------

const fs = require('node:fs');
const root = path.join(__dirname, '..', '..', '..');
function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}

test('mac ランチャーは --free を受け、鍵と Gateway を free では要求しない', () => {
  const sh = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  assert.match(sh, /--free\) FREE="--free"/, '--free フラグを受けること');
  assert.match(sh, /if \[ -z "\$FREE" \]; then\n  DS_KEY=/, 'free では DeepSeek キーを要求しないこと');
  assert.match(sh, /CONFIG_ARGS=\(--free --monitor-plugin "\$MONITOR_PLUGIN"\)/,
    'free では opencode-config.js に --free を渡すこと');
  // 表示の正直さ（送信検査が無いことを起動時に伝える）。
  assert.match(sh, /送信検査（伏せる人）: なし/);
  assert.match(sh, /opencode-free/, 'coach マーカーは free 専用の値にすること');
});

test('Windows ランチャーは -Free を受け、鍵と Gateway を free では要求しない', () => {
  const ps = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');
  assert.match(ps, /\[switch\]\$Free/, '-Free パラメータを受けること');
  assert.match(ps, /if \(-not \$Free\) \{\r?\n    \$dsKey = Read-AiSafeSecret/,
    'free では DeepSeek キーを要求しないこと');
  assert.match(ps, /@\(\$configJs, '--free', '--monitor-plugin', \$monitorPlugin\)/,
    'free では opencode-config.js に --free を渡すこと');
  assert.match(ps, /送信検査（伏せる人）: なし/);
  assert.match(ps, /opencode-free/, 'coach マーカーは free 専用の値にすること');
});

test('統合ランチャーのメニュー 1 番が --free / -Free で OpenCode を起動する', () => {
  const mac = read('scripts/macos/launch-integrated.sh');
  assert.match(mac, /1\) OpenCode（無料モデルを自分で選ぶ）.*完全無課金/);
  assert.match(mac, /1\) agent="opencode"; profile="standard"; choose_project; extra="--free"/);
  const win = read('scripts/windows/launch-integrated.ps1');
  assert.match(win, /1\) OpenCode（無料モデルを自分で選ぶ）.*完全無課金/);
  assert.match(win, /'1'  \{ \$Agent = 'opencode'; \$SafetyProfile = 'standard'; \$Free = \$true; \$Project = Select-ProjectFolder \}/);
});
