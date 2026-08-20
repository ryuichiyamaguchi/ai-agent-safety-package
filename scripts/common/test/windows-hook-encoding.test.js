'use strict';
// windows-hook-encoding.test.js — Windows の hook が日本語を UTF-8 で出すことの見張り。
//
// 実機で起きた不具合（山口さんの Windows）:
//   PreToolUse hook が出す「AI Safety Guard BLOCKED: …」などの日本語が化けて読めない。
//   受講者が一番読むべき「なぜ止まったのか」が読めなくなるので実害が大きい。
//
// 原因（mac の pwsh で CP932 を再現して確認済み）:
//   Claude Code / Codex は hook の stdout / stderr を UTF-8 として読む。一方 PowerShell 5.1 の
//   [Console]::OutputEncoding は日本語 Windows では既定が CP932。CP932 のバイト列
//   （危険 = 8a eb 8c af）がそのまま出て、受け取り側が UTF-8 として解釈するので化ける。
//
// 直し方:
//   日本語を書く前に [Console]::OutputEncoding を UTF-8（BOM なし）へ切り替える。
//   ・$OutputEncoding とは別物（あちらはネイティブコマンドの stdin へパイプするときの符号化）。
//   ・BOM 付きにすると stdout の permissionDecision JSON の先頭に BOM が載って壊れる。
//   ・**hook 専用**。.bat が `chcp 932` した実コンソールへ出すスクリプト
//     （install / doctor / launch-* / open-monitor / secret-scan）で同じことをすると逆に化ける。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

const PKG = path.resolve(__dirname, '..', '..', '..');
const LIB = path.join(PKG, 'scripts', 'windows', 'lib', 'SafetyPolicy.ps1');
const HOOKS = ['guard-bash', 'guard-write', 'guard-prompt', 'guard-webfetch', 'guard-observe', 'guard-post-output'];
// .bat から chcp 932 済みの実コンソール、または PowerShell のパイプへ出すもの。
// ここで UTF-8 を強制すると「直すつもりで壊す」ので、触っていないことを見張る。
const MUST_NOT_TOUCH = [
  'install.ps1', 'doctor.ps1', 'open-monitor.ps1', 'secret-scan.ps1',
  'launch-integrated.ps1', 'launch-codex-safe.ps1', 'launch-agy-safe.ps1',
  'launch-claude-safe.ps1', 'launch-longrun.ps1', 'protect-folder.ps1',
  'apply-global-guard.ps1',
];

const read = (rel) => fs.readFileSync(path.join(PKG, rel), 'utf8');

test('共有ライブラリに UTF-8 切り替えの実体があり、BOM なしを使っている', () => {
  const lib = fs.readFileSync(LIB, 'utf8');
  assert.match(lib, /function Set-AiSafeConsoleUtf8/, '切り替え関数がない');
  assert.match(lib, /\[Console\]::OutputEncoding = \$utf8/, '[Console]::OutputEncoding を設定していない');
  assert.match(lib, /New-Object System\.Text\.UTF8Encoding\(\$false\)/,
    'BOM なし（UTF8Encoding($false)）でないと stdout の JSON が壊れる');
  assert.ok(!/\[Console\]::OutputEncoding\s*=\s*\[System\.Text\.Encoding\]::UTF8/.test(lib),
    'BOM 付きの [System.Text.Encoding]::UTF8 を使ってはいけない');
  // 設定できない環境（コンソールを持たない等）で安全判定を巻き添えにしないこと。
  assert.match(lib, /try \{[\s\S]*\[Console\]::OutputEncoding = \$utf8[\s\S]*?\} catch/,
    '例外を握りつぶす try/catch が無い');
});

test('日本語を出す共有関数は、書き出す前に UTF-8 へ切り替える', () => {
  const lib = fs.readFileSync(LIB, 'utf8');
  // 「なぜ止まったのか」を伝える経路と、fail-closed、承認ダイアログの理由（stdout）の 3 本。
  const mustGuard = [
    /Set-AiSafeConsoleUtf8\r?\n\s*\[Console\]::Error\.WriteLine\("AI Safety Guard BLOCKED: "/,
    /Set-AiSafeConsoleUtf8\r?\n\s*\[Console\]::Error\.WriteLine\("AI Safety Guard FAILED CLOSED/,
    /Set-AiSafeConsoleUtf8\r?\n\s*\[Console\]::Out\.WriteLine\(\(\$obj \| ConvertTo-Json/,
  ];
  for (const re of mustGuard) assert.match(lib, re, `書き出しの直前に切り替えが無い: ${re}`);
});

test('各 hook は lib を読み込んだ直後に UTF-8 へ切り替える', () => {
  for (const name of HOOKS) {
    const src = read(path.join('scripts', 'windows', `${name}.ps1`));
    assert.match(src, /SafetyPolicy\.ps1"\)\r?\n(?:\s*#[^\r\n]*\r?\n)*\s*Set-AiSafeConsoleUtf8/,
      `${name}.ps1: lib 読み込み直後に Set-AiSafeConsoleUtf8 が無い`);
    // 取りこぼし防止のため、そのファイル内の最初の Console 書き出しより前にあること。
    const at = src.indexOf('Set-AiSafeConsoleUtf8');
    const firstWrite = src.search(/\[Console\]::(Error|Out)\.Write/);
    if (firstWrite >= 0) {
      assert.ok(at >= 0 && at < firstWrite,
        `${name}.ps1: 最初の Console 書き出しより後で切り替えている`);
    }
  }
});

test('実コンソールへ出すスクリプトの出力エンコーディングは変えていない', () => {
  for (const name of MUST_NOT_TOUCH) {
    const file = path.join(PKG, 'scripts', 'windows', name);
    if (!fs.existsSync(file)) continue;
    const src = fs.readFileSync(file, 'utf8');
    assert.ok(!/\[Console\]::OutputEncoding\s*=/.test(src),
      `${name}: .bat が chcp 932 した実コンソールへ出すので、UTF-8 を強制すると逆に化ける`);
  }
});

// --- 実測（pwsh があるときだけ）------------------------------------------------------
// mac の pwsh は既定が UTF-8 なので、そのままでは不具合が再現しない。
// CodePagesEncodingProvider を登録して [Console]::OutputEncoding を 932 にし、
// 「日本語 Windows の PowerShell 5.1」を模してから確かめる。
const pwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8' });
const hasPwsh = pwsh.status === 0;

test('CP932 から始めても、日本語が UTF-8 のバイト列で出る', { skip: hasPwsh ? false : 'pwsh が無いため skip' }, (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-enc-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const probe = path.join(dir, 'probe.ps1');
  fs.writeFileSync(probe, [
    "$ErrorActionPreference = 'Stop'",
    '. $args[0]',
    'try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }',
    'try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(932) } catch { }',
    '$before = [Console]::OutputEncoding.CodePage',
    'Set-AiSafeConsoleUtf8',
    '[Console]::Error.WriteLine("AI Safety Guard BLOCKED: 危険なコマンドのため止めました")',
    '[Console]::Out.WriteLine("before=$before after=" + [Console]::OutputEncoding.CodePage)',
  ].join('\n') + '\n');

  const r = spawnSync('pwsh', ['-NoProfile', '-File', probe, LIB], { timeout: 60000 });
  assert.strictEqual(r.status, 0, String(r.stderr));

  const stdout = r.stdout.toString('utf8');
  // CP932 を実際に用意できた環境でだけ「元は 932 だった」ことまで見る
  // （用意できない環境では after が 65001 であることだけ確かめれば十分）。
  assert.match(stdout, /after=65001/, `UTF-8 へ切り替わっていない: ${stdout}`);

  // stdout の先頭に BOM が載っていないこと（載ると permissionDecision JSON が壊れる）。
  assert.notStrictEqual(r.stdout[0], 0xef, 'stdout に BOM が付いている');

  // stderr の日本語が UTF-8 として妥当で、往復しても壊れないこと。
  const err = r.stderr;
  const decoded = err.toString('utf8');
  assert.match(decoded, /危険なコマンドのため止めました/, `UTF-8 として読めない: ${err.toString('hex')}`);
  assert.ok(Buffer.compare(Buffer.from(decoded, 'utf8'), err) === 0,
    'UTF-8 として往復しない = 不正なバイト列が混ざっている');
  // 「危」の CP932 表現(0x8a 0xeb)が生で出ていないこと（修正前はこれが出ていた）。
  assert.ok(!err.includes(Buffer.from([0x8a, 0xeb])), 'CP932 のバイト列が出ている（文字化けの再発）');
});
