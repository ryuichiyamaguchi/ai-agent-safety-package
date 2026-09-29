'use strict';
// workspace-snapshot.js（作業フォルダの控えと「元に戻す」）の回帰テスト。
//
// 守りたいこと:
//   1. 控え → 書き換え・削除・追加 → 元に戻す、で中身が控えの時点に戻る
//   2. 控えのあとで新しくできたファイルは消さずに set-aside/ へ移す
//   3. 元に戻す直前の控えが自動で取られ、それを使えば「元に戻す」自体を取り消せる
//   4. 一覧（manifest）が書き換えられていても、作業フォルダの外や .ai-safety の中へは書かない
//   5. 控えの中身が壊れていたら、何も変えずに中止する
//   6. .ai-safety・除外フォルダ・パッケージ管理下の場所には触らない
//   7. シンボリックリンクはたどらない（控えに入れず、書き戻しでも外へ書き出さない）
//   8. 大きすぎるファイルは控えに入れず、元に戻すときもそのまま残す（消さない）
//   9. 古い控えの整理と、使われなくなった中身の片付け
//  10. 同時実行を防ぐ lock（新しい lock は待って諦める / 古い lock は引き継ぐ）
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const SCRIPT = path.join(__dirname, '..', 'workspace-snapshot.js');
const snap = require(SCRIPT);

function mkws(t) {
  const ws = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'snap-ws-')));
  t.after(() => fs.rmSync(ws, { recursive: true, force: true }));
  return ws;
}

function write(ws, rel, content) {
  const p = path.join(ws, ...rel.split('/'));
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, content);
  return p;
}

function read(ws, rel) {
  return fs.readFileSync(path.join(ws, ...rel.split('/')), 'utf8');
}

function exists(ws, rel) {
  return fs.existsSync(path.join(ws, ...rel.split('/')));
}

function manifestsDir(ws) {
  return path.join(ws, '.ai-safety', 'snapshots', 'manifests');
}

function listFilesRecursive(dir) {
  const out = [];
  const walk = (d) => {
    for (const name of fs.readdirSync(d)) {
      const p = path.join(d, name);
      const st = fs.lstatSync(p);
      if (st.isDirectory()) walk(p); else out.push(p);
    }
  };
  if (fs.existsSync(dir)) walk(dir);
  return out;
}

function withEnv(name, value, fn) {
  const had = Object.prototype.hasOwnProperty.call(process.env, name);
  const prev = process.env[name];
  process.env[name] = value;
  try { return fn(); } finally {
    if (had) process.env[name] = prev; else delete process.env[name];
  }
}

function canSymlink(dir) {
  try {
    const target = path.join(dir, '.probe-target');
    fs.writeFileSync(target, 'x');
    fs.symlinkSync(target, path.join(dir, '.probe-link'));
    fs.rmSync(path.join(dir, '.probe-link'));
    fs.rmSync(target);
    return true;
  } catch { return false; }
}

function runCli(args, input) {
  return spawnSync(process.execPath, [SCRIPT, ...args], { encoding: 'utf8', input: input == null ? '' : input, timeout: 60000 });
}

// ── 1〜3. 往復・脇へ片付け・元に戻す直前の控え ─────────────────────────────────
test('控え → 変更 → 元に戻す で中身が戻り、新しいファイルは set-aside へ移る（消さない）', (t) => {
  const ws = mkws(t);
  write(ws, 'proj/a.txt', 'original A');
  write(ws, 'proj/src/app.js', 'console.log(1);');
  write(ws, '日本語メモ.md', 'メモ');

  const first = snap.take(ws, { reason: 'before-codex' });
  assert.strictEqual(first.reused, false);
  assert.strictEqual(first.fileCount, 3);

  // AI がやらかした想定: 書き換え・削除・新規作成（フォルダごと）
  write(ws, 'proj/a.txt', 'BROKEN by AI');
  fs.rmSync(path.join(ws, 'proj', 'src'), { recursive: true });
  write(ws, 'proj/new.txt', 'created after snapshot');
  write(ws, 'extra/deep/file.bin', 'another new one');

  const plan = snap.diff(ws, '1');
  assert.deepStrictEqual(plan.restore.map((r) => [r.path, r.kind]).sort(),
    [['proj/a.txt', 'changed'], ['proj/src/app.js', 'deleted']]);
  assert.deepStrictEqual(plan.setAside, ['extra/deep/file.bin', 'proj/new.txt']);
  assert.strictEqual(plan.unchanged, 1);

  const res = snap.restore(ws, first.id);
  assert.deepStrictEqual(res.failed, []);
  assert.strictEqual(read(ws, 'proj/a.txt'), 'original A');
  assert.strictEqual(read(ws, 'proj/src/app.js'), 'console.log(1);');
  assert.strictEqual(read(ws, '日本語メモ.md'), 'メモ');
  // 新しくできたファイルは作業フォルダからは消えるが、消されずに set-aside の同じ相対パスにある。
  assert.ok(!exists(ws, 'proj/new.txt'));
  assert.ok(res.setAsideDir && res.setAsideDir.startsWith(path.join(ws, '.ai-safety', 'snapshots', 'set-aside')));
  assert.strictEqual(fs.readFileSync(path.join(res.setAsideDir, 'proj', 'new.txt'), 'utf8'), 'created after snapshot');
  assert.strictEqual(fs.readFileSync(path.join(res.setAsideDir, 'extra', 'deep', 'file.bin'), 'utf8'), 'another new one');

  // 元に戻す直前の控えが取られていて、AI がやらかした状態を含んでいる。
  const items = snap.list(ws);
  assert.strictEqual(items.length, 2);
  assert.strictEqual(items[0].reason, 'before-restore');
  assert.strictEqual(res.before.id, items[0].id);
  // その控えへ戻せば「元に戻す」自体を取り消せる。
  const undo = snap.restore(ws, items[0].id);
  assert.deepStrictEqual(undo.failed, []);
  assert.strictEqual(read(ws, 'proj/a.txt'), 'BROKEN by AI');
  assert.strictEqual(read(ws, 'proj/new.txt'), 'created after snapshot');
  assert.ok(!exists(ws, 'proj/src/app.js'), 'before-restore の時点では消えていたファイル');
});

test('変更が無ければ新しい控えは作らず、元に戻しても何もしない', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'same');
  const a = snap.take(ws, { reason: 'before-claude' });
  const b = snap.take(ws, { reason: 'before-codex' });
  assert.strictEqual(b.reused, true);
  assert.strictEqual(b.id, a.id);
  assert.strictEqual(snap.list(ws).length, 1);
  const res = snap.restore(ws, a.id);
  assert.strictEqual(res.before, null, '変更が無いのに元に戻す直前の控えを増やさない');
  assert.strictEqual(res.restored.length, 0);
});

test('番号で控えを選べる（1 がいちばん新しい）', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'v1');
  const s1 = snap.take(ws, { reason: 'before-codex' });
  write(ws, 'a.txt', 'v2 longer');
  const s2 = snap.take(ws, { reason: 'before-claude' });
  const items = snap.list(ws);
  assert.deepStrictEqual(items.map((i) => i.id), [s2.id, s1.id]);
  assert.strictEqual(items[1].reasonLabel, 'Codex の起動前');
  write(ws, 'a.txt', 'v3 even longer');
  snap.restore(ws, '2');
  assert.strictEqual(read(ws, 'a.txt'), 'v1');
});

test('続けて取った控えは、同じミリ秒でも必ず取った順に並ぶ', (t) => {
  const ws = mkws(t);
  const ids = [];
  for (let i = 0; i < 12; i += 1) {
    write(ws, 'a.txt', `v${i}`);
    ids.push(snap.take(ws, { reason: 'before-codex', prune: false }).id);
  }
  assert.deepStrictEqual(snap.list(ws).map((x) => x.id), ids.slice().reverse());
});

// ── 4. 書き換えられた一覧（パスの抜け道） ───────────────────────────────────────
test('一覧のパスが外を指していたら、その控えは丸ごと使わない（外にも .ai-safety にも書かない）', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'good');
  const s = snap.take(ws, { reason: 'before-codex' });
  const mp = path.join(manifestsDir(ws), `${s.id}.json`);
  const original = JSON.parse(fs.readFileSync(mp, 'utf8'));
  const sha = original.files[0].sha256;
  const outsideName = `snap-escape-${process.pid}.txt`;
  const bad = [
    `../${outsideName}`,
    `a/../../${outsideName}`,
    path.join(os.tmpdir(), outsideName).replace(/\\/g, '/'),
    `/${outsideName}`,
    'C:/Windows/evil.txt',
    'sub\\..\\..\\evil.txt',
    '.ai-safety/policy/safety-policy.json',
    'x/.AI-SAFETY/hooks/evil.js',
    './a.txt',
    'a//b.txt',
    '',
  ];
  for (const p of bad) {
    const tampered = { ...original, files: [...original.files, { path: p, sha256: sha, size: 4, mtimeMs: 1, mode: 0o644 }] };
    fs.writeFileSync(mp, JSON.stringify(tampered));
    assert.throws(() => snap.restore(ws, s.id), (e) => e instanceof snap.SnapshotError && e.code === 'tampered',
      `危ないパスを受け付けてしまった: ${JSON.stringify(p)}`);
    assert.throws(() => snap.diff(ws, s.id), snap.SnapshotError);
  }
  assert.ok(!fs.existsSync(path.join(path.dirname(ws), outsideName)), '作業フォルダの外に書き出された');
  assert.ok(!fs.existsSync(path.join(os.tmpdir(), outsideName)));
  assert.strictEqual(snap.list(ws).length, 1, '中止したのに元に戻す直前の控えが作られている');
});

test('isSafeRelPath: 普通の相対パスだけを通す', () => {
  for (const ok of ['a.txt', 'proj/src/app.js', '日本語/メモ.md', '.hidden/x', 'a..b/c']) {
    assert.strictEqual(snap.isSafeRelPath(ok), true, ok);
  }
  for (const ng of ['', '/abs', '../x', 'a/../b', 'a/./b', 'a//b', 'a/', 'C:x', 'c:/x', 'a\\b', 'a\0b',
    '.ai-safety', '.ai-safety/x', 'p/.Ai-Safety/q', null, 42]) {
    assert.strictEqual(snap.isSafeRelPath(ng), false, JSON.stringify(ng));
  }
});

// ── 5. 壊れた中身 ────────────────────────────────────────────────────────────────
test('控えの中身が壊れていたら、何も変えずに中止する', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'precious');
  write(ws, 'b.txt', 'other');
  const s = snap.take(ws, { reason: 'before-codex' });
  const entry = s.manifest.files.find((f) => f.path === 'a.txt');
  const obj = snap._internal.objectPath(snap._internal.openContext(ws), entry.sha256);
  fs.chmodSync(obj, 0o600);
  fs.writeFileSync(obj, 'tampered content!!');

  write(ws, 'a.txt', 'changed by AI');
  write(ws, 'new.txt', 'new');
  assert.throws(() => snap.restore(ws, s.id), (e) => e instanceof snap.SnapshotError && e.code === 'corrupt');
  assert.strictEqual(read(ws, 'a.txt'), 'changed by AI', '壊れた中身で上書きした');
  assert.strictEqual(read(ws, 'new.txt'), 'new', '中止したのに新しいファイルを動かした');
  assert.strictEqual(snap.list(ws).length, 1, '中止したのに元に戻す直前の控えが作られている');
});

// ── 6. 触らない場所 ──────────────────────────────────────────────────────────────
test('.ai-safety・除外フォルダ・パッケージ管理下の場所は控えにも書き戻しにも入らない', (t) => {
  const ws = mkws(t);
  write(ws, '.ai-safety/policy/safety-policy.json', '{"policy":1}');
  write(ws, '.ai-safety/docs-manifest.txt', '00_はじめに.md\n');
  write(ws, 'node_modules/pkg/index.js', 'module.exports = 1;');
  write(ws, 'proj/.git/HEAD', 'ref: refs/heads/main');
  write(ws, 'proj/__pycache__/x.pyc', 'bytes');
  write(ws, '.DS_Store', 'junk');
  write(ws, '.claude/settings.json', '{"a":1}');
  write(ws, 'スタート/4_AIを起動する.command', '#!/bin/bash');
  write(ws, 'docs/00_はじめに.md', 'package doc');
  write(ws, 'docs/自分のメモ.md', 'user note');
  write(ws, 'work.txt', 'work');

  const s = snap.take(ws, { reason: 'before-codex' });
  assert.deepStrictEqual(s.manifest.files.map((f) => f.path).sort(), ['docs/自分のメモ.md', 'work.txt']);

  // 書き戻しの時点で新しく増えていても、これらは片付けない。
  write(ws, '.ai-safety/policy/new.json', '{}');
  write(ws, 'node_modules/pkg2/index.js', 'x');
  write(ws, '.claude/commands/new.md', 'x');
  write(ws, 'スタート/10_作業フォルダを元に戻す.command', '#!/bin/bash');
  write(ws, 'docs/00_はじめに.md', 'package doc v2');
  write(ws, 'work.txt', 'changed');
  fs.rmSync(path.join(ws, 'docs', '自分のメモ.md'));

  const res = snap.restore(ws, s.id);
  assert.deepStrictEqual(res.failed, []);
  assert.deepStrictEqual(res.movedAside, []);
  assert.strictEqual(read(ws, 'work.txt'), 'work');
  assert.strictEqual(read(ws, 'docs/自分のメモ.md'), 'user note', '利用者が docs に置いたメモは守る');
  assert.strictEqual(read(ws, 'docs/00_はじめに.md'), 'package doc v2', '配布物の docs を古い版へ巻き戻さない');
  assert.strictEqual(read(ws, '.ai-safety/policy/safety-policy.json'), '{"policy":1}');
  assert.ok(exists(ws, '.ai-safety/policy/new.json'));
  assert.ok(exists(ws, 'node_modules/pkg2/index.js'));
  assert.ok(exists(ws, '.claude/commands/new.md'));
  assert.ok(exists(ws, 'スタート/10_作業フォルダを元に戻す.command'));
});

// ── 7. シンボリックリンク ────────────────────────────────────────────────────────
test('リンクはたどらない: 控えに入れず、ファイルがリンクに差し替えられても外へ書かない', (t) => {
  const ws = mkws(t);
  if (!canSymlink(ws)) { t.skip('この環境ではシンボリックリンクを作れない'); return; }
  const outsideDir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'snap-outside-')));
  t.after(() => fs.rmSync(outsideDir, { recursive: true, force: true }));
  const outsideFile = path.join(outsideDir, 'target.txt');
  fs.writeFileSync(outsideFile, 'outside secret');
  write(ws, 'a.txt', 'mine');
  write(ws, 'dir/b.txt', 'mine b');
  fs.symlinkSync(outsideFile, path.join(ws, 'link-to-outside'));

  const s = snap.take(ws, { reason: 'before-codex' });
  assert.ok(!s.manifest.files.some((f) => f.path === 'link-to-outside'));
  assert.ok(s.manifest.skipped.some((x) => x.path === 'link-to-outside' && x.why === 'symlink'));

  // AI がファイルとフォルダを外へのリンクに差し替えた想定。
  fs.rmSync(path.join(ws, 'a.txt'));
  fs.symlinkSync(outsideFile, path.join(ws, 'a.txt'));
  fs.rmSync(path.join(ws, 'dir'), { recursive: true });
  fs.symlinkSync(outsideDir, path.join(ws, 'dir'));

  const res = snap.restore(ws, s.id);
  assert.deepStrictEqual(res.failed, []);
  assert.strictEqual(fs.readFileSync(outsideFile, 'utf8'), 'outside secret', 'リンク先（外）を書き換えた');
  assert.ok(!fs.existsSync(path.join(outsideDir, 'b.txt')), 'リンク先（外）のフォルダへ書き出した');
  assert.ok(!fs.lstatSync(path.join(ws, 'a.txt')).isSymbolicLink());
  assert.strictEqual(read(ws, 'a.txt'), 'mine');
  assert.ok(fs.lstatSync(path.join(ws, 'dir')).isDirectory());
  assert.strictEqual(read(ws, 'dir/b.txt'), 'mine b');
  // 邪魔だったリンクは消さずに片付けてある（リンクそのものを移すだけ）。
  assert.ok(res.movedAside.some((m) => m.path === 'a.txt' && m.kind === 'link'));
  assert.ok(res.movedAside.some((m) => m.path === 'dir' && m.kind === 'link'));
  // 控えの時点からあったリンクには触らない。
  assert.ok(fs.lstatSync(path.join(ws, 'link-to-outside')).isSymbolicLink());
});

// ── 8. 大きさの上限 ──────────────────────────────────────────────────────────────
test('上限より大きいファイルは控えに入れず、元に戻すときもそのまま残す', (t) => {
  const ws = mkws(t);
  write(ws, 'small.txt', 'small');
  write(ws, 'big.bin', Buffer.alloc(3000, 1));
  const s = withEnv('AI_SAFE_SNAPSHOT_MAX_MB', '0.002', () => snap.take(ws, { reason: 'before-codex' }));
  assert.deepStrictEqual(s.manifest.files.map((f) => f.path), ['small.txt']);
  assert.ok(s.manifest.skipped.some((x) => x.path === 'big.bin' && x.why === 'too-large'));

  write(ws, 'big.bin', Buffer.alloc(4000, 2));
  const res = withEnv('AI_SAFE_SNAPSHOT_MAX_MB', '0.002', () => snap.restore(ws, s.id));
  assert.strictEqual(res.restored.length, 0);
  assert.strictEqual(fs.statSync(path.join(ws, 'big.bin')).size, 4000, '控えに無い大きなファイルを動かした');
  assert.ok(res.plan.notCovered.some((x) => x.path === 'big.bin'));
});

test('上書きで失われる版（元に戻す直前の控えに入らない大きさ）は脇へ移してから書き戻す', (t) => {
  const ws = mkws(t);
  write(ws, 'doc.txt', 'short original');
  const s = withEnv('AI_SAFE_SNAPSHOT_MAX_MB', '0.002', () => snap.take(ws, { reason: 'before-codex' }));
  const bigVersion = 'x'.repeat(5000);
  write(ws, 'doc.txt', bigVersion);
  const res = withEnv('AI_SAFE_SNAPSHOT_MAX_MB', '0.002', () => snap.restore(ws, s.id));
  assert.strictEqual(read(ws, 'doc.txt'), 'short original');
  const moved = res.movedAside.find((m) => m.path === 'doc.txt');
  assert.ok(moved, '大きな版を脇へ移していない（上書きで消えてしまう）');
  assert.strictEqual(fs.readFileSync(moved.to, 'utf8'), bigVersion);
});

// ── 9. 整理 ─────────────────────────────────────────────────────────────────────
test('古い控えを整理し、どの控えからも使われなくなった中身だけを片付ける', (t) => {
  const ws = mkws(t);
  write(ws, 'keep.txt', 'always here');
  write(ws, 'a.txt', 'one');
  snap.take(ws, { reason: 'before-codex', prune: false });
  write(ws, 'a.txt', 'two');
  snap.take(ws, { reason: 'before-codex', prune: false });
  write(ws, 'a.txt', 'three');
  const last = snap.take(ws, { reason: 'before-codex', prune: false });
  assert.strictEqual(snap.list(ws).length, 3);
  const objectsDir = path.join(ws, '.ai-safety', 'snapshots', 'objects');
  assert.strictEqual(listFilesRecursive(objectsDir).length, 4);

  const r = snap.prune(ws, { keep: 1 });
  assert.strictEqual(r.removedManifests, 2);
  assert.strictEqual(r.removedObjects, 2);
  assert.deepStrictEqual(snap.list(ws).map((i) => i.id), [last.id]);
  const remaining = listFilesRecursive(objectsDir).map((p) => path.basename(p)).sort();
  assert.deepStrictEqual(remaining, last.manifest.files.map((f) => f.sha256).sort());
  // 残した控えでちゃんと戻せる。
  write(ws, 'a.txt', 'four!');
  snap.restore(ws, last.id);
  assert.strictEqual(read(ws, 'a.txt'), 'three');
});

test('take のあとに自動で整理される（keep を超えた古い控えが消える）', (t) => {
  const ws = mkws(t);
  for (let i = 0; i < 4; i += 1) {
    write(ws, 'a.txt', `version ${i}`);
    snap.take(ws, { reason: 'before-codex', keep: 2 });
  }
  assert.strictEqual(snap.list(ws).length, 2);
});

test('整理しても set-aside（片付けた利用者のファイル）には触らない', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'a');
  const s = snap.take(ws, { reason: 'before-codex' });
  write(ws, 'new.txt', 'user file');
  const res = snap.restore(ws, s.id);
  snap.prune(ws, { keep: 1 });
  assert.strictEqual(fs.readFileSync(path.join(res.setAsideDir, 'new.txt'), 'utf8'), 'user file');
});

// ── 10. lock ─────────────────────────────────────────────────────────────────────
test('lock: 新しい lock があれば待って諦め、10 分より古い lock は引き継ぐ', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'a');
  snap.take(ws, { reason: 'before-codex' });
  const lockPath = path.join(ws, '.ai-safety', 'snapshots', 'lock');
  fs.writeFileSync(lockPath, JSON.stringify({ pid: process.pid, token: 'someone-else', at: new Date().toISOString() }));
  write(ws, 'a.txt', 'changed');
  assert.throws(() => snap.take(ws, { reason: 'before-codex', lockWaitMs: 300 }),
    (e) => e instanceof snap.SnapshotError && e.code === 'locked');
  assert.throws(() => snap.restore(ws, '1', { lockWaitMs: 300 }), (e) => e.code === 'locked');
  assert.strictEqual(read(ws, 'a.txt'), 'changed', 'lock 中なのに書き戻した');
  assert.ok(fs.existsSync(lockPath), '他人の lock を消した');

  const old = new Date(Date.now() - 11 * 60 * 1000);
  fs.utimesSync(lockPath, old, old);
  const r = snap.take(ws, { reason: 'before-codex', lockWaitMs: 300 });
  assert.strictEqual(r.reused, false);
  assert.ok(!fs.existsSync(lockPath), '終わったら自分の lock を片付けること');
});

test('lock: 持ち主のプロセスが居なければ新しくても引き継ぐ', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'a');
  snap.take(ws, { reason: 'before-codex' });
  const child = spawnSync(process.execPath, ['-e', 'process.stdout.write(String(process.pid))'], { encoding: 'utf8' });
  const deadPid = Number(child.stdout);
  const lockPath = path.join(ws, '.ai-safety', 'snapshots', 'lock');
  fs.writeFileSync(lockPath, JSON.stringify({ pid: deadPid, token: 'dead', at: new Date().toISOString() }));
  write(ws, 'a.txt', 'b');
  const r = snap.take(ws, { reason: 'before-codex', lockWaitMs: 300 });
  assert.strictEqual(r.reused, false);
});

// ── CLI ────────────────────────────────────────────────────────────────────────
test('CLI: take は日本語 1 行、使い方の誤りは終了コード 2', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'a');
  const r = runCli(['take', '--workspace', ws, '--reason', 'before-codex']);
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /^作業フォルダの控えを取りました（1 ファイル・[0-9.]+ 秒）\n$/);
  const q = runCli(['take', '--workspace', ws, '--quiet']);
  assert.strictEqual(q.status, 0);
  assert.strictEqual(q.stdout, '');
  assert.strictEqual(runCli(['take']).status, 2);
  assert.strictEqual(runCli(['nope', '--workspace', ws]).status, 2);
  assert.strictEqual(runCli(['take', '--workspace', ws, '--bogus']).status, 2);
  assert.strictEqual(runCli(['take', '--workspace', path.join(ws, 'missing')]).status, 2);
  assert.strictEqual(runCli(['restore', '--workspace', ws, '--id', '99', '--yes']).status, 2);
  assert.strictEqual(runCli(['prune', '--workspace', ws, '--keep', '0']).status, 2);
  const list = runCli(['list', '--workspace', ws, '--json']);
  assert.strictEqual(list.status, 0);
  assert.strictEqual(JSON.parse(list.stdout)[0].reason, 'before-codex');
});

test('CLI: 確認なし（--yes 無し・端末でない）の restore は何も変えずに 2 で終わる', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'a');
  runCli(['take', '--workspace', ws]);
  write(ws, 'a.txt', 'changed');
  const r = runCli(['restore', '--workspace', ws, '--id', '1']);
  assert.strictEqual(r.status, 2);
  assert.strictEqual(read(ws, 'a.txt'), 'changed');
  const dry = runCli(['restore', '--workspace', ws, '--id', '1', '--dry-run']);
  assert.strictEqual(dry.status, 0);
  assert.match(dry.stdout, /書き換え\s+a\.txt/);
  assert.strictEqual(read(ws, 'a.txt'), 'changed');
});

test('CLI: ボタン用の対話画面（番号 → 差分 → y）で元に戻せる', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'original');
  runCli(['take', '--workspace', ws, '--reason', 'before-claude']);
  write(ws, 'a.txt', 'broken');
  write(ws, 'new.txt', 'new');
  // いったんやめる → 何も変わらない
  const cancel = runCli(['wizard', '--workspace', ws], '1\nn\n');
  assert.strictEqual(cancel.status, 0, cancel.stderr);
  assert.match(cancel.stdout, /Claude Code の起動前/);
  assert.match(cancel.stdout, /やめました/);
  assert.strictEqual(read(ws, 'a.txt'), 'broken');
  // 実行する
  const run = runCli(['wizard', '--workspace', ws], '1\ny\nn\n');
  assert.strictEqual(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /元に戻しました/);
  assert.match(run.stdout, /set-aside/);
  assert.strictEqual(read(ws, 'a.txt'), 'original');
  assert.ok(!exists(ws, 'new.txt'));
  // 範囲外の番号
  const bad = runCli(['wizard', '--workspace', ws], '9\n');
  assert.strictEqual(bad.status, 2);
});

test('CLI: 控えが無い作業フォルダでは対話画面が案内だけして 0 で終わる（s なら控えを取る）', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'a');
  const r = runCli(['wizard', '--workspace', ws], '');
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /まだ控えがありません/);
  assert.strictEqual(snap.list(ws).length, 0, 'Enter だけなのに控えを取った');
  const s = runCli(['wizard', '--workspace', ws], 's\n');
  assert.strictEqual(s.status, 0, s.stderr);
  assert.match(s.stdout, /作業フォルダの控えを取りました/);
  const items = snap.list(ws);
  assert.strictEqual(items.length, 1);
  assert.strictEqual(items[0].reasonLabel, '手動で取った控え');
});

test('CLI: 控えがある作業フォルダでも対話画面の s で「いまの状態」の控えを取れる', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'a');
  runCli(['take', '--workspace', ws]);
  write(ws, 'a.txt', 'changed');
  const r = runCli(['wizard', '--workspace', ws], 's\n');
  assert.strictEqual(r.status, 0, r.stderr);
  assert.strictEqual(snap.list(ws).length, 2);
  assert.strictEqual(read(ws, 'a.txt'), 'changed', 's は控えを取るだけで何も戻さない');
});

test('ホームフォルダ丸ごとの控えは取らない', () => {
  assert.throws(() => snap.take(os.homedir()), (e) => e instanceof snap.SnapshotError && e.code === 'usage');
});

test('CLI: --launcher は失敗しても 1 行の警告を標準出力に出して 0 で終わる（起動を止めない）', (t) => {
  const ws = mkws(t);
  write(ws, 'a.txt', 'a');
  fs.mkdirSync(path.join(ws, '.ai-safety'), { recursive: true });
  fs.writeFileSync(path.join(ws, '.ai-safety', 'snapshots'), 'not a folder');
  const r = runCli(['take', '--workspace', ws, '--reason', 'before-codex', '--launcher']);
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stderr, '', '標準エラーへ出すと PowerShell 5.1 の呼び出し側で事故になる');
  assert.match(r.stdout, /^※ 元に戻す用の控えを取れませんでした（.+）。そのまま起動します。\n$/);
  const ok = runCli(['take', '--workspace', mkws(t), '--launcher']);
  assert.strictEqual(ok.status, 0);
  assert.match(ok.stdout, /^作業フォルダの控えを取りました/);
});

// ── 起動スクリプトとのつなぎ込み ───────────────────────────────────────────────
const PKG = path.join(__dirname, '..', '..', '..');
const readPkg = (rel) => fs.readFileSync(path.join(PKG, rel), 'utf8');

test('4 つの起動スクリプトが、dry-run の後・AI の起動前に控えを取る', () => {
  const macInt = readPkg('scripts/macos/launch-integrated.sh');
  const lastDry = macInt.lastIndexOf('AI_SAFE_DRY_RUN');
  const common = macInt.indexOf('snapshot_before_launch "before-$agent"');
  assert.ok(common > lastDry, 'mac 統合: 控えが dry-run より前にある（テストの dry-run で控えを取ってしまう）');
  assert.ok(common < macInt.indexOf('open-monitor.sh" >'), 'mac 統合: 控えがモニター起動より後ろにある');
  const agyDry = macInt.indexOf('agent:     agy (launch-agy-safe.sh へ委譲)');
  const agySnap = macInt.indexOf('snapshot_before_launch "before-agy"');
  assert.ok(agyDry > 0 && agySnap > agyDry && agySnap < macInt.indexOf('exec bash "$agy_launcher"'), 'mac 統合: AntiGravity の分岐で控えを取っていない');
  assert.match(macInt, /"\$_snap_js" take --workspace "\$workspace" --reason "\$_snap_reason" --launcher \|\| true/);

  const winInt = readPkg('scripts/windows/launch-integrated.ps1');
  const winCommon = winInt.indexOf("Invoke-WorkspaceSnapshot -Reason ('before-' + $snapAgent)");
  assert.ok(winCommon > winInt.lastIndexOf('AI_SAFE_DRY_RUN'), 'Windows 統合: 控えが dry-run より前にある');
  assert.ok(winCommon < winInt.indexOf('$monitorProc = Start-Process'), 'Windows 統合: 控えがモニター起動より後ろにある');
  const wAgy = winInt.indexOf("Invoke-WorkspaceSnapshot -Reason 'before-agy'");
  assert.ok(wAgy > winInt.indexOf('agent:     agy (launch-agy-safe.ps1 へ委譲)') && wAgy < winInt.indexOf('& $agyLauncher -Workspace $Workspace'),
    'Windows 統合: AntiGravity の分岐で控えを取っていない');

  const macLr = readPkg('scripts/macos/launch-longrun.sh');
  const lrSnap = macLr.indexOf('snapshot_before_launch "before-longrun-$engine"');
  assert.ok(lrSnap > macLr.indexOf('echo "長時間おまかせモードで起動します。"') && lrSnap < macLr.indexOf('case "$engine" in\n  codex)'),
    'mac 長時間: 同意の後・起動の前で控えを取っていない');
  assert.match(macLr, /AI_SAFE_SNAPSHOT_ALREADY="\$workspace" exec bash "\$hooks\/launch-integrated\.sh"/);

  const winLr = readPkg('scripts/windows/launch-longrun.ps1');
  const wlr = winLr.indexOf("Invoke-WorkspaceSnapshot -Reason ('before-longrun-' + $Engine)");
  assert.ok(wlr > winLr.indexOf("Write-Host '長時間おまかせモードで起動します。'") && wlr < winLr.indexOf("if ($Engine -eq 'codex')"),
    'Windows 長時間: 同意の後・起動の前で控えを取っていない');
  assert.match(winLr, /\$env:AI_SAFE_SNAPSHOT_ALREADY = \$Workspace\r?\n\s*& \(Join-Path \$hooks 'launch-integrated\.ps1'\)/);

  // Windows 側は出力を取り込まない（取り込むと [Console]::OutputEncoding を触ることになり、
  // chcp 932 の画面で化ける）。node 自身が 1 行を出す --launcher で呼ぶ。
  for (const src of [winInt, winLr]) {
    assert.match(src, /& \$nodeCmd\.Source \$snapJs 'take' '--workspace' \$Workspace '--reason' \$Reason '--launcher'/);
  }
});

function makeLauncherWorkspace(t) {
  const ws = mkws(t);
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'snap-home-')));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const hooks = path.join(ws, '.ai-safety', 'hooks', 'macos');
  fs.mkdirSync(hooks, { recursive: true });
  fs.mkdirSync(path.join(ws, '.ai-safety', 'hooks', 'common'), { recursive: true });
  fs.mkdirSync(path.join(ws, '.ai-safety', 'policy'), { recursive: true });
  fs.copyFileSync(path.join(PKG, 'policy', 'safety-policy.json'), path.join(ws, '.ai-safety', 'policy', 'safety-policy.json'));
  fs.copyFileSync(SCRIPT, path.join(ws, '.ai-safety', 'hooks', 'common', 'workspace-snapshot.js'));
  for (const name of ['launch-integrated.sh', 'launch-longrun.sh']) {
    fs.copyFileSync(path.join(PKG, 'scripts', 'macos', name), path.join(hooks, name));
  }
  const log = path.join(home, 'stub.log');
  const manifests = path.join(ws, '.ai-safety', 'snapshots', 'manifests');
  // AI 本体の代わりのスタブ。起動された時点で控えが既にあるか、目印が漏れていないかを記録する。
  const stub = (name) => [
    '#!/usr/bin/env bash',
    `n=$(ls ${JSON.stringify(manifests)} 2>/dev/null | wc -l | tr -d ' ')`,
    `printf '%s manifests=%s flag=%s args=%s\\n' ${JSON.stringify(name)} "$n" "\${AI_SAFE_SNAPSHOT_ALREADY:-unset}" "$*" >> ${JSON.stringify(log)}`,
    'exit 0',
  ].join('\n') + '\n';
  for (const name of ['launch-codex-safe.sh', 'launch-agy-safe.sh', 'open-monitor.sh']) {
    fs.writeFileSync(path.join(hooks, name), stub(name), { mode: 0o755 });
  }
  fs.mkdirSync(path.join(hooks, 'opencode'), { recursive: true });
  fs.writeFileSync(path.join(hooks, 'opencode', 'launch-opencode-deepseek.sh'), stub('launch-opencode-deepseek.sh'), { mode: 0o755 });
  write(ws, '案件/report.md', 'original');
  const env = { ...process.env, HOME: home, AI_SAFE_LOG_DIR: path.join(home, 'logs') };
  delete env.AI_SAFE_SNAPSHOT_ALREADY;
  delete env.AI_SAFE_DRY_RUN;
  delete env.AI_SAFE_SNAPSHOT;
  return { ws, hooks, log, env };
}

const macOnly = process.platform === 'win32' ? 'bash の起動スクリプトは mac / Linux で確かめる' : false;

test('mac 統合ランチャー: AI の起動前に控えを取り、dry-run・二重取りの目印・off では取らない', { skip: macOnly }, (t) => {
  const w = makeLauncherWorkspace(t);
  const run = (extraEnv, args) => spawnSync('bash', [path.join(w.hooks, 'launch-integrated.sh'), w.ws, ...args],
    { env: { ...w.env, ...extraEnv }, encoding: 'utf8', timeout: 60000 });

  const r = run({}, ['codex', 'standard']);
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /作業フォルダの控えを取りました/);
  const items = snap.list(w.ws);
  assert.strictEqual(items.length, 1);
  assert.strictEqual(items[0].reason, 'before-codex');
  assert.match(fs.readFileSync(w.log, 'utf8'), /launch-codex-safe\.sh manifests=1 flag=unset/, 'AI の起動より前に控えが取れていない');

  write(w.ws, '案件/report.md', 'changed');
  const dry = run({ AI_SAFE_DRY_RUN: '1' }, ['codex', 'standard']);
  assert.strictEqual(dry.status, 0);
  assert.strictEqual(snap.list(w.ws).length, 1, 'dry-run なのに控えを取った');

  const flagged = run({ AI_SAFE_SNAPSHOT_ALREADY: w.ws }, ['opencode', 'standard']);
  assert.strictEqual(flagged.status, 0, flagged.stdout + flagged.stderr);
  assert.strictEqual(snap.list(w.ws).length, 1, '長時間おまかせで取り終えたのに二重に取った');
  assert.match(fs.readFileSync(w.log, 'utf8'), /launch-opencode-deepseek\.sh manifests=1 flag=unset/, '目印が AI 本体まで漏れている');

  const off = run({ AI_SAFE_SNAPSHOT: 'off' }, ['codex', 'standard']);
  assert.strictEqual(off.status, 0);
  assert.strictEqual(snap.list(w.ws).length, 1, 'AI_SAFE_SNAPSHOT=off なのに控えを取った');

  // 控えの仕組みが壊れていても起動は止めない（警告 1 行で続ける）。
  fs.writeFileSync(path.join(w.ws, '.ai-safety', 'hooks', 'common', 'workspace-snapshot.js'), 'process.exit(3);\n');
  // 見守りモニター（open-monitor.sh）は裏で並行して立ち上がるので、記録の「最後の行」は
  // タイミング次第でモニター側になる。AI 本体の起動記録が 1 行増えたかで確かめる。
  const codexLaunches = () => fs.readFileSync(w.log, 'utf8').split('\n').filter((l) => /^launch-codex-safe\.sh /.test(l)).length;
  const before = codexLaunches();
  const broken = run({}, ['codex', 'standard']);
  assert.strictEqual(broken.status, 0, broken.stdout + broken.stderr);
  assert.strictEqual(codexLaunches(), before + 1, '控えの失敗で AI が起動しなかった');
});

test('mac 長時間おまかせ: 同意の後に控えを取り、OpenCode では統合ランチャーに二重取りさせない', { skip: macOnly }, (t) => {
  const w = makeLauncherWorkspace(t);
  // 統合ランチャーはスタブへ差し替え、受け取った目印を記録する。
  fs.writeFileSync(path.join(w.hooks, 'launch-integrated.sh'), [
    '#!/usr/bin/env bash',
    `printf 'launch-integrated.sh flag=%s args=%s\\n' "\${AI_SAFE_SNAPSHOT_ALREADY:-unset}" "$*" >> ${JSON.stringify(w.log)}`,
    'exit 0',
  ].join('\n') + '\n', { mode: 0o755 });
  const run = (engine, input) => spawnSync('bash', [path.join(w.hooks, 'launch-longrun.sh'), w.ws, engine],
    { env: w.env, encoding: 'utf8', input, timeout: 60000 });

  const declined = run('opencode', '\n');
  assert.strictEqual(declined.status, 0);
  assert.strictEqual(snap.list(w.ws).length, 0, '同意していないのに控えを取った');

  const oc = run('opencode', 'はい\n');
  assert.strictEqual(oc.status, 0, oc.stdout + oc.stderr);
  const items = snap.list(w.ws);
  assert.strictEqual(items.length, 1);
  assert.strictEqual(items[0].reason, 'before-longrun-opencode');
  assert.strictEqual(items[0].reasonLabel, '長時間おまかせ（OpenCode）の起動前');
  const logText = fs.readFileSync(w.log, 'utf8');
  assert.ok(logText.includes(`launch-integrated.sh flag=${w.ws} args=`) && /--longrun/.test(logText), logText);

  write(w.ws, '案件/report.md', 'changed by codex run');
  const cx = run('codex', '\n');
  assert.strictEqual(cx.status, 0, cx.stdout + cx.stderr);
  assert.strictEqual(snap.list(w.ws)[0].reason, 'before-longrun-codex');
  assert.match(fs.readFileSync(w.log, 'utf8'), /launch-codex-safe\.sh manifests=2 flag=unset args=.*--longrun/);
});
