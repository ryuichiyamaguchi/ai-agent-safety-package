// ps51-compat.test.js — Windows 用の .ps1 が Windows PowerShell 5.1（.NET Framework）で動く書き方かを静的に確かめる。
//
// 受講者の Windows には PowerShell 5.1 しか無い。ところが mac の pwsh（7）で流すテストでは、
// .NET Core にしか無い API や PowerShell 6 以降の自動変数を使っても通ってしまう。
// v1.19.0 で GitHub Actions の Windows PowerShell 5.1 を初めて回したところ、次がまとめて見つかった:
//   - ProcessStartInfo.StandardInputEncoding（.NET Core のみ）への代入 → 5.1 では例外
//   - ProcessStartInfo.ArgumentList（.NET Core のみ）→ 5.1 では null
//   - StrictMode の lib で $IsWindows（PowerShell 6+ の自動変数）をそのまま参照 → 5.1 では未定義で例外
//     （SafetyPolicy.ps1 の監査ログ ACL で、毎日最初のフックが fail-closed していた）
// 本物の 5.1 での確認は .github/workflows/windows-tests.yml が行う。ここは mac でも回る早期の歯止め。
'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const REPO = path.resolve(__dirname, '..', '..', '..');

function ps1Files(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...ps1Files(p));
    else if (e.name.endsWith('.ps1')) out.push(p);
  }
  return out;
}

const FILES = [
  ...ps1Files(path.join(REPO, 'scripts', 'windows')),
  ...ps1Files(path.join(REPO, 'scripts', 'common', 'test')),
  ...ps1Files(path.join(REPO, 'workspace-template')),
];

// コメント行（# で始まる行）は除いて見る。
function codeLines(file) {
  return fs.readFileSync(file, 'utf8').replace(/^﻿/, '').split(/\r?\n/)
    .map((l, i) => ({ n: i + 1, l }))
    .filter(({ l }) => !/^\s*#/.test(l));
}

const rel = (f) => path.relative(REPO, f);

test('StandardInputEncoding に代入していない（.NET Framework に無い）', () => {
  const bad = [];
  for (const f of FILES) for (const { n, l } of codeLines(f)) {
    if (/\.StandardInputEncoding\s*=/.test(l)) bad.push(`${rel(f)}:${n}`);
  }
  assert.deepStrictEqual(bad, []);
});

test('ProcessStartInfo.ArgumentList を使っていない（.NET Framework に無い）', () => {
  const bad = [];
  for (const f of FILES) for (const { n, l } of codeLines(f)) {
    if (/\.ArgumentList\.Add\(/.test(l)) bad.push(`${rel(f)}:${n}`);
  }
  assert.deepStrictEqual(bad, []);
});

test('StrictMode のファイルで $IsWindows / $IsMacOS / $IsLinux をむき出しで参照していない', () => {
  const bad = [];
  for (const f of FILES) {
    const text = fs.readFileSync(f, 'utf8');
    if (!/Set-StrictMode\s+-Version\s+(2|3|Latest)/i.test(text)) continue;
    for (const { n, l } of codeLines(f)) {
      if (/\$Is(Windows|MacOS|Linux)\b/.test(l) && !/variable:Is(Windows|MacOS|Linux)/.test(l)) bad.push(`${rel(f)}:${n}`);
    }
  }
  assert.deepStrictEqual(bad, []);
});

test('検査対象の .ps1 が見つかっている', () => {
  assert.ok(FILES.length > 30, 'ps1 が少なすぎる: ' + FILES.length);
});
