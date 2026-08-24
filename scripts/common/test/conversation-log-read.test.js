// =============================================================
// conversation-log-read.test.js — 「会話ログは読める／秘密は読めないまま」の回帰テスト
//
// なぜこれがあるか（2026-08-21 の裁定 → 2026-08-24 の緩和で更新）:
//   2026-08-21 は「① 会話ログだけ既定で読める ② 他のホーム配下は確認付き ③ 秘密は読めない」
//   だったが、2026-08-24 のワークスペース外アクセス緩和（依頼者承認済み設計）で
//   ①② が統合された。現在の線引きは:
//     ① 既定でそのまま読める … **ホームを含む PC 全体**（会話ログの置き場を含む）
//     ② 読めないまま         … .env / .ssh / .aws / ... / ~/.ai-safety / 各 CLI の鍵と設定そのもの
//   （書き込み側は緩めていない: ワークスペース外への書き込みは確認制のまま）
//
// ⚠️ このテストが固定しているのは「開けたこと」だけではない。同じ数だけ「閉じたままである
// こと」を固定している。会話ログの置き場を開けても、その**隣**にある鍵の実物
// （~/.codex/auth.json ・ ~/.gemini/oauth_creds.json など）と設定そのもの
// （~/.claude/settings.json など）は読めないままでなければならない。
//
// ⚠️ `..` の踏み台も固定する。会話ログの置き場から親をたどって設定本体・秘密へ回り込む形は
// 3 エンジンとも塞がっていること。
//
// 実行: node --test scripts/common/test/conversation-log-read.test.js
// =============================================================
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const REPO = path.resolve(__dirname, '..', '..', '..');
const POLICY_PATH = path.join(REPO, 'policy', 'safety-policy.json');
const POLICY = JSON.parse(fs.readFileSync(POLICY_PATH, 'utf8'));
const OC = require(path.join(REPO, 'scripts', 'common', 'opencode-config.js'));

const HOME = '/Users/example';

// ① 既定でそのまま読めなければならない会話ログ（実機で存在を確認した置き場だけ）。
const CONVERSATION_LOGS = [
  '{HOME}/.claude/projects/-Users-example-work/6b1f.jsonl',
  '{HOME}/.codex/sessions/2026/08/21/rollout-2026-08-21T09-00-00.jsonl',
  '{HOME}/.codex/archived_sessions/2026/08/old.jsonl',
  '{HOME}/.gemini/tmp/02/logs.json',
  '{HOME}/.gemini/antigravity-cli/conversations/0025582c.db',
  '{HOME}/.local/share/opencode/storage/session_diff/ses_03995d.json',
  '{HOME}/.local/share/opencode/log/2026-08-21T090000.log',
  // 2026-08-21 追補（依頼者裁定「そこも読めた方がいい」）: Codex に打ち込んだ指示の履歴。
  // これだけは「フォルダごと」ではなく「ファイル 1 本」の許可（下の CODEX_NEIGHBORS も参照）。
  '{HOME}/.codex/history.jsonl',
];

// ①' history.jsonl のために ~/.codex/* をフォルダごと開けた代償。**同じフォルダの直下**は
// 1 本も開いてはいけない。ここが緩むと「会話ログを開けたつもりが鍵まで開いた」になる。
const CODEX_NEIGHBORS = [
  '{HOME}/.codex/auth.json',
  '{HOME}/.codex/config.toml',
  '{HOME}/.codex/config.toml.bak',
  '{HOME}/.codex/config.toml.bak-20260528-codex-auto-profile',
  '{HOME}/.codex/auto.config.toml',
  '{HOME}/.codex/lean.config.toml',
  '{HOME}/.codex/gemma-local.config.toml',
  '{HOME}/.codex/hooks.json.bak.driving-mode.20260525-001850',
  '{HOME}/.codex/AGENTS.md',
  '{HOME}/.codex/installation_id',
  '{HOME}/.codex/.codex-global-state.json',
];

// CODEX_NEIGHBORS のうち、シェル経由（`cat ...`）でも止まらなければならないもの＝鍵と設定と控え。
// AGENTS.md や installation_id は「秘密」ではないので guard の決定的 deny には入れていない
// （read 表と external_directory では閉じてある。ここを混同しないこと）。
const CODEX_NEIGHBOR_SECRETS = [
  '{HOME}/.codex/auth.json',
  '{HOME}/.codex/config.toml',
  '{HOME}/.codex/config.toml.bak',
  '{HOME}/.codex/config.toml.bak-20260528-codex-auto-profile',
  '{HOME}/.codex/auto.config.toml',
  '{HOME}/.codex/lean.config.toml',
  '{HOME}/.codex/gemma-local.config.toml',
  '{HOME}/.codex/hooks.json.bak.driving-mode.20260525-001850',
  // 2026-08-22 追加: 実機の ~/.codex を数え直したときに見つかった。名前からは分かりにくいが
  // 中に "secrets" / "secrets_with_domains" と API の認証情報（例: DATAFORSEO_PASSWORD）が
  // 入っている。read 表では CODEX_NEIGHBORS として閉じてあったが、シェル経由
  // （`cat ~/.codex/.codex-global-state.json`）が素通りしていた。控えの .bak は
  // 既存の `.codex/*.bak` の規則で当たる。
  '{HOME}/.codex/.codex-global-state.json',
  '{HOME}/.codex/.codex-global-state.json.bak',
];

// ③ 引き続き読めてはいけないもの（秘密の実体）。
const SECRETS = [
  '{HOME}/.ssh/id_rsa',
  '{HOME}/.env',
  '{HOME}/work/.env.production',
  '{HOME}/.aws/credentials',
  '{HOME}/.azure/accessTokens.json',
  '{HOME}/.gnupg/secring.gpg',
  '{HOME}/.kube/config',
  '{HOME}/.config/gcloud/credentials.db',
  '{HOME}/.docker/config.json',
  '{HOME}/.npmrc',
  '{HOME}/.pypirc',
  '{HOME}/.ai-safety/policy/safety-policy.json',
  '{HOME}/.deepseek-claude/auth',
];

// ③ 会話ログの「隣」にある鍵の実物と設定そのもの（開けた置き場の巻き添えで開いてはいけない）。
const AGENT_SECRETS = [
  '{HOME}/.claude/settings.json',
  '{HOME}/.claude/settings.local.json',
  '{HOME}/.claude.json',
  '{HOME}/.claude/.credentials.json',
  '{HOME}/.codex/config.toml',
  '{HOME}/.codex/auth.json',
  '{HOME}/.gemini/settings.json',
  '{HOME}/.gemini/oauth_creds.json',
  '{HOME}/.gemini/google_accounts.json',
  '{HOME}/.gemini/antigravity-cli/antigravity-oauth-token',
  '{HOME}/.gemini/antigravity-cli/settings.json',
  '{HOME}/.config/opencode/opencode.json',
  '{HOME}/.config/opencode/opencode.jsonc',
  '{HOME}/.local/share/opencode/auth.json',
  '{HOME}/.local/share/opencode/mcp-auth.json',
];

// その他のホーム配下。2026-08-24 の緩和で「確認付き（ask）」から「既定で読める（allow）」へ
// 変わった（読み取りはホームを含む全体を開放。秘密の deny 床だけが残る）。
const HOME_OPEN = [
  '{HOME}/Documents/memo.txt',
  '{HOME}/Desktop/todo.md',
  '{HOME}/.zshrc',
];

// ④ `..` を踏み台にして会話ログの置き場から回り込む形。
const TRAVERSALS = [
  '{HOME}/.claude/projects/../settings.json',
  '{HOME}/.claude/projects/../../.ssh/id_rsa',
  '{HOME}/.codex/sessions/../auth.json',
  '{HOME}/.gemini/tmp/../oauth_creds.json',
  '{HOME}/.local/share/opencode/log/../auth.json',
  '{HOME}/.claude/projects/../../.ai-safety/policy/safety-policy.json',
  // history.jsonl を開けたので、そこを踏み台にする形も足す。
  '{HOME}/.codex/sessions/../config.toml',
  '{HOME}/.codex/prompts/../auth.json',
];

const subst = (list, home = HOME) => list.map((p) => p.replace('{HOME}', home));

// --- 共通: 会話ログの置き場そのもの -------------------------------------------

test('会話ログの置き場は 1 つ以上あり、鍵ファイルを含むフォルダを丸ごと開けていない', () => {
  assert.ok(Array.isArray(OC.CONVERSATION_LOG_DIRS) && OC.CONVERSATION_LOG_DIRS.length > 0,
    '会話ログの置き場が空です（緩和が丸ごと消えています）');
  // OpenCode の external_directory は「対象の親フォルダ + /*」しか見ないため、
  // 鍵の隣のフォルダ（~/.codex ・ ~/.claude ・ ~/.gemini 直下など）を開けてはいけない。
  for (const dir of OC.CONVERSATION_LOG_DIRS) {
    assert.ok(dir.split('/').length >= 2,
      `会話ログの置き場が浅すぎます（鍵の隣まで開きます）: ${dir}`);
  }
});

// --- guard 系（policy/safety-policy.json） -------------------------------------

test('guard: 会話ログの置き場は protectedPathRegex に 1 つも当たらない', () => {
  const compiled = POLICY.protectedPathRegex.map((p) => new RegExp(p, 'i'));
  for (const target of subst(CONVERSATION_LOGS)) {
    const hit = compiled.find((re) => re.test(target));
    assert.ok(!hit, `会話ログが保護パスに当たっています（読めなくなります）: ${target} / ${hit}`);
  }
});

test('guard: 秘密は protectedPathRegex に当たり続けている', () => {
  const compiled = POLICY.protectedPathRegex.map((p) => new RegExp(p, 'i'));
  for (const target of subst(SECRETS)) {
    assert.ok(compiled.some((re) => re.test(target)),
      `秘密が保護パスから漏れています: ${target}`);
  }
});

test('guard: ~/.codex 直下の鍵・設定・控えは protectedPathRegex に当たる（シェル経由も止める）', () => {
  const compiled = POLICY.protectedPathRegex.map((p) => new RegExp(p, 'i'));
  for (const target of subst(CODEX_NEIGHBOR_SECRETS)) {
    assert.ok(compiled.some((re) => re.test(target)),
      `~/.codex の鍵・設定が保護パスから漏れています: ${target}`);
  }
  // 開けた 1 本と、隣の会話ログフォルダは巻き込まない。
  for (const target of subst(CONVERSATION_LOGS)) {
    assert.ok(!compiled.some((re) => re.test(target)),
      `会話ログが保護パスに当たっています（読めなくなります）: ${target}`);
  }
});

function macBashVerdict(command) {
  const payload = JSON.stringify({
    hook_event_name: 'PreToolUse',
    tool_name: 'Bash',
    cwd: path.join(HOME, 'workspace'),
    tool_input: { command },
  });
  const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-convlog-'));
  const result = spawnSync('bash', [path.join(REPO, 'scripts', 'macos', 'guard-bash.sh')], {
    input: payload,
    encoding: 'utf8',
    timeout: 120000,
    env: { ...process.env, AI_SAFE_LOG_DIR: path.join(logDir, 'logs') },
  });
  fs.rmSync(logDir, { recursive: true, force: true });
  if (result.status === 2) return String(result.stderr).includes('FATAL') ? 'fatal' : 'block';
  if (result.status !== 0) return `error(${result.status})`;
  return String(result.stdout).includes('"permissionDecision":"ask"') ? 'ask' : 'pass';
}

test('mac guard-bash: 会話ログは読めて、秘密と `..` 経由は止まる',
  { skip: process.platform !== 'darwin' ? 'macOS 専用' : false }, () => {
    for (const target of subst(CONVERSATION_LOGS)) {
      assert.strictEqual(macBashVerdict(`cat ${target}`), 'pass',
        `会話ログの読み取りが止められました: ${target}`);
    }
    for (const target of [
      ...subst(SECRETS),
      ...subst(CODEX_NEIGHBOR_SECRETS),
      ...subst(TRAVERSALS).filter((t) => /ssh|ai-safety|codex/.test(t)),
    ]) {
      assert.strictEqual(macBashVerdict(`cat ${target}`), 'block',
        `秘密の読み取りが通ってしまいました: ${target}`);
    }
  });

// --- OpenCode（read 表 + external_directory 表） --------------------------------

// OpenCode の権限評価は「最後に一致したルールが勝つ」（1.18.9 実測: evaluate が findLast）。
// パターン側の `~/` は照合前にホームへ展開される（同 LA()）。ここではその 2 点を再現する。
function globToRegExp(pattern) {
  let out = '';
  for (let i = 0; i < pattern.length; i += 1) {
    const c = pattern[i];
    if (c === '*') {
      if (pattern[i + 1] === '*') { out += '.*'; i += 1; if (pattern[i + 1] === '/') i += 1; } else { out += '[^/]*'; }
    } else if (c === '?') {
      out += '[^/]';
    } else {
      out += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    }
  }
  return new RegExp(`^${out}$`);
}

function ocEvaluate(rules, resource, home = HOME) {
  let action = 'ask'; // 何にも当たらなければ ask（1.18.9 実測: evaluate の既定）
  for (const [pattern, value] of Object.entries(rules)) {
    const expanded = pattern.startsWith('~/') ? home + pattern.slice(1) : pattern;
    if (globToRegExp(expanded).test(resource)) action = value;
  }
  return action;
}

// external_directory の照合対象は「対象の親フォルダ + /*」（1.18.9 実測:
// assertExternalDirectory が path.join(path.dirname(filepath), '*') を渡す）。
// パスは opencode 側で canonical に解決済みなので、`..` は残らない。
const externalResource = (file) => `${path.posix.dirname(path.posix.normalize(file))}/*`;

test('OpenCode: external_directory は読み取り開放（会話ログもその他のホーム配下も allow）', () => {
  const ext = OC.enforcedExternalDirectoryRules();
  assert.strictEqual(Object.keys(ext)[0], '*', 'catch-all が先頭にありません');
  // 2026-08-24: 読み取り開放。external_directory は read/write を区別できない単一の関門
  // なので catch-all を allow にし、書き込みの確認は edit 表（'*': ask）、秘密の読み取り
  // 禁止は read 表の deny 床が担う（このテストの後続ケースが固定している）。
  assert.strictEqual(ext['*'], 'allow');
  const keys = Object.keys(ext);
  assert.strictEqual(keys[keys.length - 1], '**/../**', '`..` 封じが末尾にありません');
  assert.strictEqual(ext['**/../**'], 'deny');
  for (const target of [...subst(CONVERSATION_LOGS), ...subst(HOME_OPEN)]) {
    assert.strictEqual(ocEvaluate(ext, externalResource(target)), 'allow',
      `ホーム配下が確認なしで読めません: ${target}`);
  }
  // 道具の置き場（既存の免除）は開いたまま。
  assert.strictEqual(ocEvaluate(ext, `${HOME}/.claude/skills/my-skill/*`), 'allow');
});

test('OpenCode: history.jsonl のために開けた ~/.codex/* は read 表が閉じ直している', () => {
  const read = OC.enforcedReadRules();
  const ext = OC.enforcedExternalDirectoryRules();
  // external_directory では（仕組み上）フォルダごと開いている。
  assert.strictEqual(ext['~/.codex/*'], 'allow',
    '~/.codex/* が開いていません（history.jsonl が読めなくなります）');
  // その代わり read 表で「直下は全部 deny → history.jsonl だけ allow」になっていること。
  assert.strictEqual(ocEvaluate(read, `${HOME}/.codex/history.jsonl`), 'allow',
    'history.jsonl が read 表で止まっています');
  for (const target of subst(CODEX_NEIGHBORS)) {
    assert.strictEqual(ocEvaluate(read, target), 'deny',
      `~/.codex 直下が read 表で開いています: ${target}`);
  }
  // deny → allow の順序（findLast=最後勝ち）が崩れていないこと。
  const keys = Object.keys(read);
  assert.ok(keys.indexOf('~/.codex/*') < keys.indexOf('~/.codex/history.jsonl'),
    '~/.codex/* の deny が history.jsonl の allow より後ろにあります（フォルダごと素通しになります）');
  assert.strictEqual(keys[keys.length - 1], '**/../**',
    '`..` 封じが read 表の末尾にありません（後ろの allow に追い越されます）');
  // ~/.codex の中でも会話ログのフォルダ（sessions / archived_sessions）と道具の置き場は開いたまま。
  for (const target of [
    `${HOME}/.codex/sessions/2026/08/21/rollout.jsonl`,
    `${HOME}/.codex/archived_sessions/2026/08/old.jsonl`,
    `${HOME}/.codex/prompts/my-prompt.md`,
  ]) {
    assert.notStrictEqual(ocEvaluate(read, target), 'deny',
      `~/.codex 配下のフォルダを巻き込んで閉じています: ${target}`);
  }
});

test('OpenCode: 開けた ~/.codex 直下は書き込み（edit 表）でも閉じている', () => {
  for (const longrun of [false, true]) {
    const edit = OC.enforcedEditRules(longrun);
    for (const target of [...subst(CODEX_NEIGHBORS), `${HOME}/.codex/history.jsonl`]) {
      assert.strictEqual(ocEvaluate(edit, target), 'deny',
        `~/.codex 直下への書き込みが開いています(longrun=${longrun}): ${target}`);
    }
    // 道具の置き場は書き込みを巻き込まない。
    assert.notStrictEqual(ocEvaluate(edit, `${HOME}/.codex/skills/my-skill/SKILL.md`), 'deny');
  }
});

test('OpenCode: 秘密と各 CLI の鍵・設定そのものは read 表で deny のまま', () => {
  const read = OC.enforcedReadRules();
  assert.strictEqual(read['*'], 'allow');
  for (const target of [...subst(SECRETS), ...subst(AGENT_SECRETS)]) {
    assert.strictEqual(ocEvaluate(read, target), 'deny',
      `秘密が read 表で止まっていません: ${target}`);
  }
  // 会話ログと教材の見本ファイルは巻き込まない。
  for (const target of [...subst(CONVERSATION_LOGS), `${HOME}/workspace/.env.example`]) {
    assert.notStrictEqual(ocEvaluate(read, target), 'deny',
      `読めてよいものが read 表で止まっています: ${target}`);
  }
});

test('OpenCode: `..` 経由の踏み台は塞がっている（正規化前の形でも deny）', () => {
  const read = OC.enforcedReadRules();
  for (const target of subst(TRAVERSALS)) {
    // 正規化前の生の形: read 表の `**/../**` が受け止める。
    assert.strictEqual(ocEvaluate(read, target), 'deny',
      `\`..\` を含む生パスが read 表で止まっていません: ${target}`);
    // opencode 自身が canonical へ解決した後の形。
    const normalized = path.posix.normalize(target);
    const dir = path.posix.dirname(normalized);
    // 2026-08-24 の読み取り開放後、external_directory は catch-all allow（素通しの関門）。
    // つまりこの層は `..` の生の形（'**/../**' deny）しか止めない。正規化後の実体を止める
    // 責務は read 表の deny 床へ一本化された:
    //   read ツール経路 … opencode は external_directory の後に必ず read 権限も assert する
    //   （1.18.9 実測 ReadTool.execute: J=S.externalDirectory → assert(external) の後に
    //    assert({action:"read", resources:[S.resource]})）。ここで deny になる。
    assert.strictEqual(ocEvaluate(read, normalized), 'deny',
      `正規化後に read 表で止まっていません: ${target} -> ${normalized}`);
    // シェル経路（`cat`）: read 表は効かないので、決定的 deny 床（protectedPathRegex）が
    // 受け止める。~/.codex 直下（history.jsonl のために最初に external を開けた場所）の
    // 鍵・設定・控えは、緩和前から guard 側にも同じ床を敷いてある。
    if (OC.OPENED_DIR_LOCKDOWN.some((d) => dir === `${HOME}/${d}`)) {
      assert.ok(POLICY.protectedPathRegex.some((p) => new RegExp(p, 'i').test(normalized)),
        `~/.codex 直下の鍵・設定が protectedPathRegex で止まっていません: ${normalized}`);
    }
  }
});

test('OpenCode: 生成された設定にも同じ表が載る', () => {
  const config = OC.buildOpenCodeConfig({
    port: 8788, gatewayToken: 'dummy', mcpDir: path.join(os.tmpdir(), 'no-such-mcp-dir'),
  });
  assert.deepStrictEqual(config.permission.external_directory, OC.enforcedExternalDirectoryRules());
  assert.deepStrictEqual(config.permission.read, OC.enforcedReadRules());
});

// --- Claude Code（configs/claude/settings.{mac,windows}.json） -------------------

// Claude Code の評価順は deny → ask → allow で、先に一致した側が勝つ（公式 docs）。
// `~/` はホームに、`./` は作業フォルダに固定され、`**` はディレクトリをまたぐ。
function claudeVerdict(settings, file, home = HOME, cwd = `${HOME}/workspace`) {
  const expand = (spec) => {
    if (spec.startsWith('~/')) return home + spec.slice(1);
    if (spec.startsWith('./')) return `${cwd}/${spec.slice(2)}`;
    if (spec.startsWith('**/')) return `**/${spec.slice(3)}`;
    return spec;
  };
  const match = (spec) => {
    const s = expand(spec);
    if (s.startsWith('**/')) return globToRegExp(`*${s}`).test(file) || globToRegExp(s.slice(3)).test(file);
    return globToRegExp(s).test(file);
  };
  const reads = (list) => list
    .filter((r) => r.startsWith('Read(') && r.endsWith(')'))
    .map((r) => r.slice(5, -1));
  if (reads(settings.permissions.deny).some(match)) return 'deny';
  if (reads(settings.permissions.ask || []).some(match)) return 'ask';
  if (reads(settings.permissions.allow).some(match)) return 'allow';
  // どの規則にも当たらない = 作業フォルダの外なので Claude Code が確認カードを出す。
  return 'ask';
}

for (const file of ['settings.mac.json', 'settings.windows.json']) {
  test(`Claude 設定(${file}): 読み取りはホーム含め開放（allow）、秘密は deny のまま`, () => {
    const settings = JSON.parse(
      fs.readFileSync(path.join(REPO, 'configs', 'claude', file), 'utf8'),
    );
    for (const target of subst(CONVERSATION_LOGS)) {
      assert.strictEqual(claudeVerdict(settings, target), 'allow',
        `会話ログが確認なしで読めません: ${target}`);
    }
    for (const target of [...subst(SECRETS), ...subst(AGENT_SECRETS)]) {
      assert.strictEqual(claudeVerdict(settings, target), 'deny',
        `秘密が deny になっていません: ${target}`);
    }
    // 2026-08-24 の緩和: その他のホーム配下も既定で読める（Read(~/**) と Read(//**) を allow に追加）。
    for (const target of subst(HOME_OPEN)) {
      assert.strictEqual(claudeVerdict(settings, target), 'allow',
        `ホーム配下の読み取りが開放されていません: ${target}`);
    }
    for (const target of subst(TRAVERSALS)) {
      // 生の形は Read(**/../**)、解決後の形は個別の deny が受け止める。
      assert.strictEqual(claudeVerdict(settings, target), 'deny',
        `\`..\` を含む生パスが deny になっていません: ${target}`);
      assert.strictEqual(claudeVerdict(settings, path.posix.normalize(target)), 'deny',
        `正規化後に deny になっていません: ${target}`);
    }
    // history.jsonl の隣にある鍵・設定・控えは deny のまま。それ以外（AGENTS.md ・
    // installation_id など、秘密ではないもの）は 2026-08-24 の緩和で既定で読める。
    for (const target of subst(CODEX_NEIGHBORS)) {
      const verdict = claudeVerdict(settings, target);
      if (subst(CODEX_NEIGHBOR_SECRETS).includes(target)) {
        assert.strictEqual(verdict, 'deny',
          `~/.codex の鍵・設定が deny になっていません: ${target}`);
      } else {
        assert.strictEqual(verdict, 'allow',
          `~/.codex 直下の非秘密が読めません（読み取り開放と矛盾）: ${target}`);
      }
    }
    // 作業フォルダの中はこれまでどおり確認なしで読める（ask を広く書くと壊れる箇所）。
    assert.strictEqual(claudeVerdict(settings, `${HOME}/workspace/src/app.ts`), 'allow',
      '作業フォルダの中の読み取りが確認付きになっています（Read(~/**) を ask に足していませんか）');
  });

  test(`Claude 設定(${file}): Read(~/**) を ask に足していない（足すと作業フォルダ内が壊れる）`, () => {
    const settings = JSON.parse(
      fs.readFileSync(path.join(REPO, 'configs', 'claude', file), 'utf8'),
    );
    for (const rule of settings.permissions.ask || []) {
      assert.ok(!/^Read\(~\/\*\*\)$/.test(rule),
        'Read(~/**) は ask に置けません（deny→ask→allow の順で Read(./**) を追い越します）');
    }
  });

  test(`Claude 設定(${file}): 会話ログの allow は OpenCode 側の SSOT と一致する`, () => {
    const settings = JSON.parse(
      fs.readFileSync(path.join(REPO, 'configs', 'claude', file), 'utf8'),
    );
    for (const dir of OC.CONVERSATION_LOG_DIRS) {
      assert.ok(settings.permissions.allow.includes(`Read(~/${dir}/**)`),
        `会話ログの置き場が Claude 側にありません: ~/${dir}`);
    }
    for (const logFile of OC.CONVERSATION_LOG_FILES) {
      assert.ok(settings.permissions.allow.includes(`Read(~/${logFile})`),
        `ファイル 1 本だけの会話ログが Claude 側にありません: ~/${logFile}`);
    }
    for (const secret of OC.AGENT_SECRET_FILES) {
      assert.ok(settings.permissions.deny.includes(`Read(~/${secret})`),
        `鍵・設定そのものが Claude 側の deny にありません: ~/${secret}`);
    }
  });
}
