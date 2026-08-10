'use strict';
// フック入力（JSON）の読み取りが OS 差で失敗し、AI がまったく使えなくなる事故の回帰テスト。
//
// 何が起きたか（受講者の実機・macOS 14.8.7 Sonoma）:
//   ガードは `plutil -p -`（標準入力から JSON）でフック入力を読む。ところが Sonoma では
//   これが必ず "Unexpected character { at line 1" で失敗する。読めない＝検査できないので
//   設計どおり fail-closed になり、**無害なプロンプトも含めて全部ブロック**され、
//   「AI Safety Guard BLOCKED: 入力データを読み取れなかったため…」だけが出続けた。
//   macOS 26 では `plutil -p -` が通るため、講師機では再現しない。
//
// 対策: 同じ JSON でもファイル指定なら読めるので、一時ファイル経由で読み直す。
// ここでは「標準入力だけ失敗する plutil」を用意して Sonoma を再現し、
//   1. 無害な入力が通ること（＝受講者の症状が出ないこと）
//   2. それでも危険なコマンドは止まること（＝読めるようになっただけで床は不変）
// の両方を確かめる。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..', '..');

// 標準入力から読むときだけ失敗させ、ファイル指定は本物へ委譲する plutil。
// 判定は「入力の指定（最後の引数）が - かどうか」。`-o -`（出力先が標準出力）は
// ポリシー読み込みで普通に使うので、そこを巻き込んではいけない。
const FAKE_PLUTIL = [
  '#!/bin/sh',
  'last=""',
  'for a in "$@"; do last="$a"; done',
  'if [ "$last" = "-" ]; then',
  '  echo "plutil: Unexpected character { at line 1" >&2',
  '  exit 1',
  'fi',
  'exec /usr/bin/plutil "$@"',
  '',
].join('\n');

function setupWorkspace(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'plutil-fallback-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));

  const fake = path.join(base, 'plutil');
  fs.writeFileSync(fake, FAKE_PLUTIL, { mode: 0o755 });

  const ws = path.join(base, 'ws');
  const installed = spawnSync('bash', [path.join(root, 'scripts', 'macos', 'install.sh'), ws],
    { env: { ...process.env, HOME: base }, encoding: 'utf8' });
  assert.strictEqual(installed.status, 0, `install 失敗: ${installed.stdout}\n${installed.stderr}`);

  // 配置済みのガードが使う plutil を Sonoma 再現版へ差し替える。
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

test('標準入力から JSON を読めない macOS でも、無害な入力はブロックされない',
  { skip: process.platform !== 'darwin' }, (t) => {
    const { base, ws } = setupWorkspace(t);
    const r = runHook(ws, 'guard-prompt.sh', {
      session_id: 't', hook_event_name: 'UserPromptSubmit', prompt: 'こんにちは',
    }, base);
    assert.strictEqual(r.status, 0,
      `無害なプロンプトが止められている（受講者の症状）: ${r.stderr}`);
    assert.doesNotMatch(r.stderr || '', /入力データを読み取れなかった/,
      '読み取り失敗で fail-closed してはいけない');
  });

test('読めるようになっても deny 床は不変（危険なコマンドは止まる）',
  { skip: process.platform !== 'darwin' }, (t) => {
    const { base, ws } = setupWorkspace(t);
    const r = runHook(ws, 'guard-bash.sh', {
      session_id: 't',
      hook_event_name: 'PreToolUse',
      tool_name: 'Bash',
      tool_input: { command: 'rm -rf /Users/example/Documents' },
    }, base);
    assert.strictEqual(r.status, 2, '危険なコマンドは止めること');
    assert.match(r.stderr || '', /BLOCKED/, 'ブロック理由を出すこと');

    const ok = runHook(ws, 'guard-bash.sh', {
      session_id: 't',
      hook_event_name: 'PreToolUse',
      tool_name: 'Bash',
      tool_input: { command: 'ls -la' },
    }, base);
    assert.strictEqual(ok.status, 0, '無害なコマンドは通すこと');
  });

test('フォールバックの実装が残っていること（消すと同じ事故が再発する）', () => {
  const lib = fs.readFileSync(path.join(root, 'scripts', 'macos', 'lib', 'safety_policy.sh'), 'utf8');
  assert.match(lib, /mktemp/, '一時ファイル経由で読み直すこと');
  assert.match(lib, /chmod 600/, '入力の中身はプロンプト本文なので本人だけが読める権限にすること');
  assert.match(lib, /Sonoma/, 'なぜ必要かを実装に残すこと');
  // 失敗時も含めて必ず後始末する。
  assert.ok((lib.match(/rm -f "\$tmp"/g) || []).length >= 3, '成功・失敗のどちらでも消すこと');
});
