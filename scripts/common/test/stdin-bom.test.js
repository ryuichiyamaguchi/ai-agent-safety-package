// stdin-bom.test.js — Windows PowerShell 5.1 から Node へ渡る標準入力の先頭 BOM に耐えるかの回帰テスト。
//
// .NET Framework の Process.StandardInput は、画面の文字コードが UTF-8（65001）のとき先頭に BOM を書く。
// GitHub Actions の Windows（65001）で、解説（explainer.js）が空になり、AI 判定（command-judge.js）が
// JSON を読めず「コマンドが空」扱いで毎回人間に確認していたことが分かった。受講者の PC でも
// 「世界各国の言語サポートに Unicode UTF-8 を使用」を有効にしていれば同じことが起きる。
'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const COMMON = path.resolve(__dirname, '..');
const BOM = '\uFEFF';

test('explainer.js explain-command: 先頭 BOM があっても説明文が出る', () => {
  const r = spawnSync(process.execPath, [path.join(COMMON, 'explainer.js'), 'explain-command'], { input: BOM + 'Get-ChildItem -Path C:\\Temp', encoding: 'utf8' });
  const e = JSON.parse(r.stdout);
  assert.match(e.whatdo, /^C:\\Temp の中のファイル・フォルダ一覧/);
});

test('command-judge.js: 先頭 BOM があっても JSON を読み、コマンドが空とは言わない', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'judge-bom-'));
  try {
    const env = { ...process.env, HOME: home, USERPROFILE: home };
    delete env.GEMINI_API_KEY; delete env.GOOGLE_API_KEY;
    const r = spawnSync(process.execPath, [path.join(COMMON, 'command-judge.js')],
      { input: BOM + JSON.stringify({ command: 'ls -la', cwd: '/x' }), encoding: 'utf8', env });
    const out = JSON.parse(r.stdout);
    assert.doesNotMatch(out.judge.reason, /コマンドが空/);
    assert.strictEqual(out.decision, 'allow', 'ls は決定的に自動承認される: ' + r.stdout);
  } finally { fs.rmSync(home, { recursive: true, force: true }); }
});

test('answer-snapshot.js: 先頭 BOM があっても Stop の回答を控えに残す', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'snap-bom-'));
  try {
    const env = { ...process.env, AI_SAFE_LOG_DIR: dir, HOME: dir, USERPROFILE: dir };
    const input = BOM + JSON.stringify({ hook_event_name: 'Stop', last_assistant_message: 'こんにちは。作業が終わりました。' });
    spawnSync(process.execPath, [path.join(COMMON, 'answer-snapshot.js')], { input, encoding: 'utf8', env });
    const p = path.join(dir, 'latest-answer.json');
    assert.ok(fs.existsSync(p), 'latest-answer.json が作られていない');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
