'use strict';
// フック入力の読み取りが OS 差で失敗し、AI がまったく使えなくなる事故の回帰テスト。
//
// 何が起きたか（受講者の実機・macOS 14.8.7 Sonoma）:
//   ガードはフック入力(JSON)を `plutil -p` で読む。ところが Sonoma では **-p が JSON を
//   受け付けず必ず失敗する**（"Unexpected character { at line 1"。ファイル指定でも標準入力でも
//   同じで、通るのは `plutil -convert` だけ）。読めない＝検査できないので設計どおり
//   fail-closed になり、無害なプロンプトまで含めて全部ブロックされて
//   「AI Safety Guard BLOCKED: 入力データを読み取れなかったため…」だけが出続けた。
//   macOS 26 では -p が通るため講師機では再現しない。
//
// 対策: OS ごとに当たり外れのある外部コマンドに頼らず、Node（元から必須依存）で読み直す。
// 出力は `plutil -p` と同じ見た目なので、以降の検査（deny 床の照合）は変わらない。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..', '..');
const PLUTIL_P_JS = path.join(root, 'scripts', 'common', 'plutil-p.js');

// 実機の macOS 14 を再現する plutil。-p は常に失敗させ、それ以外は本物へ委譲する。
const FAKE_PLUTIL = [
  '#!/bin/sh',
  'for a in "$@"; do',
  '  if [ "$a" = "-p" ]; then',
  '    echo "plutil: Unexpected character { at line 1" >&2',
  '    exit 1',
  '  fi',
  'done',
  'exec /usr/bin/plutil "$@"',
  '',
].join('\n');

function setupWorkspace(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'plutil-p-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));

  const fake = path.join(base, 'plutil');
  fs.writeFileSync(fake, FAKE_PLUTIL, { mode: 0o755 });

  const ws = path.join(base, 'ws');
  const installed = spawnSync('bash', [path.join(root, 'scripts', 'macos', 'install.sh'), ws],
    { env: { ...process.env, HOME: base }, encoding: 'utf8' });
  assert.strictEqual(installed.status, 0, `install 失敗: ${installed.stdout}\n${installed.stderr}`);

  const lib = path.join(ws, '.ai-safety', 'hooks', 'macos', 'lib', 'safety_policy.sh');
  const body = fs.readFileSync(lib, 'utf8');
  assert.ok(body.includes('_PLUTIL=/usr/bin/plutil'), '差し替え位置が見つかること');
  fs.writeFileSync(lib, body.replace('_PLUTIL=/usr/bin/plutil', `_PLUTIL=${fake}`));

  return { base, ws };
}

function runHook(ws, hook, payload, home) {
  return spawnSync('bash', [path.join(ws, '.ai-safety', 'hooks', 'macos', hook)], {
    input: JSON.stringify(payload),
    env: { ...process.env, HOME: home },
    encoding: 'utf8',
  });
}

// plutil -p の出力形式は、危険コマンドを判定する正規表現の前提になっている。
// Node 実装がそこからずれると deny 床の当たり方が変わるため、本物と突き合わせて固定する。
test('Node 実装の出力は本物の plutil -p と一致する', { skip: process.platform !== 'darwin' }, (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'plutil-fmt-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));

  const cases = {
    'hook.json': {
      session_id: 't', hook_event_name: 'PreToolUse', tool_name: 'Bash',
      tool_input: { command: 'rm -rf /tmp/x', n: 1, ok: true }, arr: ['a', 'b'],
    },
    // 引用符・バックスラッシュ・改行・タブ・日本語・null・小数・負数。
    // plutil -p はこれらをエスケープせず生で出す（検査に直結するので必ず合わせる）。
    'escape.json': {
      s: 'quote" and back\\slash', nl: 'line1\nline2', tab: 'a\tb',
      uni: '日本語', empty: '', num: 1.5, neg: -3, null: null,
      nested: { z: 1, a: 2 },
    },
    'empty.json': { emptyArr: [], emptyObj: {}, deep: { a: [{ b: 'c' }] } },
  };

  for (const [name, value] of Object.entries(cases)) {
    const file = path.join(dir, name);
    fs.writeFileSync(file, JSON.stringify(value));
    const real = spawnSync('/usr/bin/plutil', ['-p', file], { encoding: 'utf8' });
    assert.strictEqual(real.status, 0, `この Mac の plutil -p が動くこと: ${real.stderr}`);
    const ours = spawnSync(process.execPath, [PLUTIL_P_JS], {
      input: fs.readFileSync(file, 'utf8'), encoding: 'utf8',
    });
    assert.strictEqual(ours.status, 0, `Node 実装が成功すること: ${ours.stderr}`);
    assert.strictEqual(ours.stdout.trimEnd(), real.stdout.trimEnd(), `${name}: 出力が一致すること`);
  }
});

test('壊れた JSON は読めないまま（fail-closed を保つ）', () => {
  const r = spawnSync(process.execPath, [PLUTIL_P_JS], { input: '{not json', encoding: 'utf8' });
  assert.notStrictEqual(r.status, 0, '読めないものを読めたことにしてはいけない');
});

test('plutil -p が使えない macOS でも、無害な入力はブロックされない',
  { skip: process.platform !== 'darwin' }, (t) => {
    const { base, ws } = setupWorkspace(t);
    const r = runHook(ws, 'guard-prompt.sh', {
      session_id: 't', hook_event_name: 'UserPromptSubmit', prompt: 'こんにちは',
    }, base);
    assert.strictEqual(r.status, 0, `無害なプロンプトが止められている（受講者の症状）: ${r.stderr}`);
    assert.doesNotMatch(r.stderr || '', /入力データを読み取れなかった/,
      '読み取り失敗で fail-closed してはいけない');
  });

test('読めるようになっても deny 床は不変（危険なコマンドは止まる）',
  { skip: process.platform !== 'darwin' }, (t) => {
    const { base, ws } = setupWorkspace(t);
    const blocked = runHook(ws, 'guard-bash.sh', {
      session_id: 't', hook_event_name: 'PreToolUse', tool_name: 'Bash',
      tool_input: { command: 'rm -rf /Users/example/Documents' },
    }, base);
    assert.strictEqual(blocked.status, 2, '危険なコマンドは止めること');
    assert.match(blocked.stderr || '', /BLOCKED/, 'ブロック理由を出すこと');

    const ok = runHook(ws, 'guard-bash.sh', {
      session_id: 't', hook_event_name: 'PreToolUse', tool_name: 'Bash',
      tool_input: { command: 'ls -la' },
    }, base);
    assert.strictEqual(ok.status, 0, '無害なコマンドは通すこと');
  });

test('外部コマンドに依存しない読み取り経路が残っていること', () => {
  const lib = fs.readFileSync(path.join(root, 'scripts', 'macos', 'lib', 'safety_policy.sh'), 'utf8');
  assert.match(lib, /plutil-p\.js/, 'Node 実装へフォールバックすること');
  assert.match(lib, /Sonoma/, 'なぜ必要かを実装に残すこと');
  assert.ok(fs.existsSync(PLUTIL_P_JS), 'Node 実装が配布物にあること');
});
