'use strict';
// clipboard-encoding.test.js — マスキングツール（伏せる / 元に戻す）が日本語を壊さない見張り。
//
// 実機で起きた不具合:
//   「マスキングツールが文字化けして使えない」。
//   スタートフォルダの（上級）10「コピーした文章から秘密を伏せる」/ 11「伏せた文章を元に戻す」
//   から呼ばれる scripts/common/clipboard-mask.js のクリップボード経路が原因。
//
// 化けていたのは「画面出力」ではなく「クリップボードとの受け渡し」。実測の内訳:
//
//   mac（読み側）: ロケールが UTF-8 でないと pbpaste が CP932 のバイト列を返す。
//     LC_ALL=C で「秘密の住所」が 94e9 96a7 82cc 8f5a 8f8a で返り、utf8 として読むと
//     "�閧�̏Z��" になった。
//   mac（書き側）: 同じ条件で pbcopy が UTF-8 の入力を扱えず、クリップボードが空になった。
//   Windows（読み側）: PowerShell 5.1 の [Console]::OutputEncoding は日本語 Windows で既定 CP932。
//     Get-Clipboard -Raw の出力が CP932 のバイト列で届くので、utf8 として読むと化ける。
//   Windows（書き側）: [Console]::In.ReadToEnd() は InputEncoding（CP932）で解釈するので、
//     UTF-8 のバイト列を標準入力に流し込むと化ける。
//
// 直し方:
//   mac    → 子プロセスの環境だけ UTF-8 に固定する（__CF_USER_TEXT_ENCODING と LC_CTYPE）。
//   Windows → 本文を base64（ASCII のみ）で受け渡す。ASCII は CP932 でも UTF-8 でも同じ
//             バイト列なので、コンソールのコードページに依存しなくなる。
//
// 画面出力は触らない。.bat は chcp 932 した実コンソールで node を直接起動しており、
// node はコンソール宛ての書き出しを WriteConsoleW で行うためコードページの影響を受けない。
// ここで UTF-8 を強制すると v1.17.3 の windows-hook-encoding.test.js と同じ理由で逆に壊す。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

const PKG = path.resolve(__dirname, '..', '..', '..');
const MASK_JS = path.join(PKG, 'scripts', 'common', 'clipboard-mask.js');
// クリップボードの文字コードの実装は secret-store.js に一本化してある（SSOT）。
// clipboard-mask.js（伏せる / 戻す）も secret-store.js（金庫の取り出し）も同じ経路を通る。
const STORE_JS = path.join(PKG, 'scripts', 'common', 'secret-store.js');
const mask = require(MASK_JS);
const store = require(STORE_JS);

// 実装が置かれている側と、それを使う側の両方を見る。
const SRC = [MASK_JS, STORE_JS].map((f) => fs.readFileSync(f, 'utf8')).join('\n');

test('伏せる/戻す と 金庫の取り出し が同じクリップボード経路を使っている', () => {
  // 片方だけ直して片方が化ける、という分岐を作らせない。
  assert.strictEqual(mask.clipboardRead, store.clipboardRead);
  assert.strictEqual(mask.clipboardWrite, store.clipboardWrite);
  assert.strictEqual(mask.PS_READ_B64, store.PS_READ_B64);
  assert.strictEqual(mask.PS_WRITE_B64, store.PS_WRITE_B64);
  // 金庫の取り出し（（上級）17）が独自に Set-Clipboard を呼び直していないこと。
  const storeSrc = fs.readFileSync(STORE_JS, 'utf8');
  assert.ok(!/'\$t=\[Console\]::In\.ReadToEnd\(\); Set-Clipboard -Value \$t'/.test(storeSrc),
    'secret-store.js が素の標準入力で Set-Clipboard している（日本語の値が CP932 で化ける）');
  assert.match(storeSrc, /input: Buffer\.from\(t, 'utf8'\), env: utf8Env\(\)/,
    'secret-store.js の pbcopy が utf8Env() を使っていない');
});

// 日本語・記号・CP932 で丸め落とされる字（髙）を混ぜて、往復の欠けを見つけられるようにする。
const JP = '秘密の住所 test@example.jp 東京都渋谷区 ①㈱髙';
const JP_HEX = Buffer.from(JP, 'utf8').toString('hex');

// --- 実装の形の見張り（実機が無くても崩れを検知できるように）-----------------------
test('Windows 経路はクリップボードの中身を base64 で受け渡している', () => {
  const src = SRC;
  assert.match(mask.PS_READ_B64, /ToBase64String\(\[Text\.Encoding\]::UTF8\.GetBytes\(\$t\)\)/,
    '読み側が base64 で出していない（CP932 のバイト列が生で届く）');
  assert.match(mask.PS_WRITE_B64, /FromBase64String\(\$b\.Trim\(\)\)/,
    '書き側が base64 を受けていない（[Console]::In が CP932 で解釈して化ける）');
  assert.match(mask.PS_WRITE_B64, /\[Console\]::In\.ReadToEnd\(\)/,
    '値をコマンド文字列に埋めてはいけない（長文・引用符・改行で壊れる）');
  // 旧実装の形（powershell の出力を utf8 として読む / 本文をそのまま標準入力へ）が戻らないこと。
  assert.ok(!/Get-Clipboard -Raw'\s*\]/.test(src) && !/'Get-Clipboard -Raw'/.test(src),
    '素の Get-Clipboard -Raw を直接読んでいる（CP932 で化ける）');
  assert.ok(!/\$t=\[Console\]::In\.ReadToEnd\(\); Set-Clipboard -Value \$t/.test(src),
    '本文を素の標準入力で渡している（CP932 で化ける）');
});

test('mac 経路は pbpaste / pbcopy を UTF-8 に固定して呼んでいる', () => {
  const src = SRC;
  for (const tool of ['pbpaste', 'pbcopy']) {
    const line = src.split('\n').find((l) => l.includes(`/usr/bin/${tool}`));
    assert.ok(line && /env:\s*utf8Env\(\)/.test(line),
      `${tool} を utf8Env() 無しで呼んでいる（ロケール次第で CP932 になる / 空になる）`);
  }
  const env = mask.utf8Env();
  assert.ok(!('LC_ALL' in env), 'LC_ALL を落としていない（LC_ALL=C が LC_CTYPE を上書きする）');
  assert.strictEqual(env.LC_CTYPE, 'UTF-8');
  assert.match(env.__CF_USER_TEXT_ENCODING, /^0x[0-9A-F]+:0x08000100:0x08000100$/,
    'CoreFoundation へ UTF-8 を明示していない');
  // 親の環境は変えないこと（他のツールの文字コードを巻き添えにしない）。
  assert.notStrictEqual(env, process.env);
});

test('画面出力のコードページは触っていない', () => {
  // 「なぜ触らないか」は注釈に書いてあるので、注釈を落としてから見る。
  const code = SRC.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
  assert.ok(!/\[Console\]::OutputEncoding\s*=/.test(code),
    '.bat が chcp 932 した実コンソールへ出すので、UTF-8 を強制すると逆に化ける');
  assert.ok(!/\bchcp\b/.test(code), 'node 側からコードページを変えてはいけない');
});

test('ボタン（.bat / .command）は node を直接起動している', () => {
  const dir = path.join(PKG, 'workspace-template', 'スタート');
  const names = fs.readdirSync(dir).filter((n) => /^（上級）1[01]_/.test(n));
  assert.ok(names.length >= 4, `伏せる / 元に戻すのボタンが見つからない: ${names.join(', ')}`);
  for (const n of names) {
    const buf = fs.readFileSync(path.join(dir, n));
    if (n.endsWith('.bat')) {
      // CP932 + CRLF を維持していること（Windows のメモ帳・cmd がそのまま読む形）。
      assert.ok(buf.includes(Buffer.from('\r\n')), `${n}: CRLF でない`);
      assert.ok(!buf.includes(Buffer.from([0xef, 0xbb, 0xbf])), `${n}: BOM が付いている`);
      assert.ok(!isValidUtf8Japanese(buf), `${n}: UTF-8 になっている（cmd が CP932 で読むので化ける）`);
      assert.match(buf.toString('latin1'), /chcp 932/, `${n}: chcp 932 が無い`);
    } else {
      assert.strictEqual(buf.toString('utf8').includes('�'), false, `${n}: UTF-8 として壊れている`);
    }
    // node を直接呼ぶ（powershell 経由に変えると出力が CP932 のパイプを通って化ける）。
    const text = n.endsWith('.bat') ? buf.toString('latin1') : buf.toString('utf8');
    assert.match(text, /node "\$?[{%]?[A-Za-z]*TARGET[}%]?"/, `${n}: node を直接起動していない`);
  }
});

// CP932 のバイト列は UTF-8 として妥当でないことが多い。日本語を含む CP932 かどうかの粗い判定。
function isValidUtf8Japanese(buf) {
  const s = buf.toString('utf8');
  return !s.includes('�') && /[ぁ-んァ-ン一-龥]/.test(s);
}

// --- 実測: mac ---------------------------------------------------------------------
// ロケールが壊れている状態（LC_ALL=C）でも日本語がバイト列レベルで往復すること。
// 実クリップボードを使うので、元の中身は必ず戻す。
const hasPb = process.platform === 'darwin' && fs.existsSync('/usr/bin/pbpaste');

test('mac: LC_ALL=C でも日本語がバイト列のまま往復する', { skip: hasPb ? false : 'mac 以外のため skip' }, (t) => {
  const utf8 = mask.utf8Env();
  const saved = spawnSync('/usr/bin/pbpaste', [], { env: utf8, timeout: 30000 }).stdout;
  t.after(() => { spawnSync('/usr/bin/pbcopy', [], { input: saved, env: utf8, timeout: 30000 }); });

  // 壊れた環境を作る。utf8Env() はこの環境を土台に作られるので、修正が効いていれば無傷で通る。
  const orig = { LC_ALL: process.env.LC_ALL, LANG: process.env.LANG, LC_CTYPE: process.env.LC_CTYPE };
  process.env.LC_ALL = 'C';
  delete process.env.LANG;
  delete process.env.LC_CTYPE;
  t.after(() => {
    for (const [k, v] of Object.entries(orig)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  });

  // 読み側: 壊れた env のままだと CP932 が返ること（不具合の再現）を先に確かめる。
  spawnSync('/usr/bin/pbcopy', [], { input: Buffer.from(JP, 'utf8'), env: utf8, timeout: 30000 });
  const naive = spawnSync('/usr/bin/pbpaste', [], { env: process.env, timeout: 30000 }).stdout;
  assert.notStrictEqual(naive.toString('hex'), JP_HEX,
    '不具合が再現しない環境（この端末は既に UTF-8 固定）: 実測の意味が無いので確認すること');

  // 修正後の読み側。
  const got = mask.clipboardRead();
  assert.strictEqual(Buffer.from(got, 'utf8').toString('hex'), JP_HEX,
    `読み取りが UTF-8 で往復しない: ${Buffer.from(String(got), 'utf8').toString('hex')}`);

  // 修正後の書き側（旧実装はここでクリップボードが空になっていた）。
  spawnSync('/usr/bin/pbcopy', [], { input: Buffer.from('先に消しておく', 'utf8'), env: utf8, timeout: 30000 });
  assert.strictEqual(mask.clipboardWrite(JP), true, '書き戻しに失敗した');
  const back = spawnSync('/usr/bin/pbpaste', [], { env: utf8, timeout: 30000 }).stdout;
  assert.strictEqual(back.toString('hex'), JP_HEX, `書き戻しが UTF-8 で往復しない: ${back.toString('hex')}`);
});

// --- 実測: Windows を模した CP932 コンソール ------------------------------------------
// mac の pwsh は既定が UTF-8 なので、CodePagesEncodingProvider を登録して
// [Console]::OutputEncoding / InputEncoding を 932 にし、「日本語 Windows の PowerShell 5.1」
// を模してから、clipboard-mask.js が実際に使う PowerShell 文字列そのものを走らせる。
// Get-Clipboard / Set-Clipboard は Windows 専用なのでファイルで代用する。
const pwshCheck = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'],
  { encoding: 'utf8', timeout: 60000 });
const hasPwsh = pwshCheck.status === 0;

test('Windows(CP932 模擬): 読み取りが日本語を UTF-8 のバイト列で復元する',
  { skip: hasPwsh ? false : 'pwsh が無いため skip' }, (t) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-clip-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    const clip = path.join(dir, 'clip.txt');
    fs.writeFileSync(clip, Buffer.from(JP, 'utf8'));

    const probe = path.join(dir, 'read.ps1');
    fs.writeFileSync(probe, [
      cp932Preamble(),
      // Windows の Get-Clipboard -Raw の代役。中身は UTF-8 のファイル。
      'function Get-Clipboard { param([switch]$Raw)',
      '  [IO.File]::ReadAllText($env:FAKE_CLIP, (New-Object System.Text.UTF8Encoding($false))) }',
      mask.PS_READ_B64,
    ].join('\n') + '\n');

    const r = spawnSync('pwsh', ['-NoProfile', '-File', probe],
      { env: Object.assign({}, process.env, { FAKE_CLIP: clip }), timeout: 120000 });
    assert.strictEqual(r.status, 0, String(r.stderr));
    // 経路を流れるのは ASCII（base64）だけ = コードページの影響を受けない。
    assert.match(r.stdout.toString('ascii'), /^[A-Za-z0-9+/=\s]+$/,
      `base64 以外が混ざっている: ${r.stdout.toString('hex')}`);
    const decoded = Buffer.from(r.stdout.toString('ascii').trim(), 'base64');
    assert.strictEqual(decoded.toString('hex'), JP_HEX, `復元できていない: ${decoded.toString('hex')}`);

    // 修正前の形（Get-Clipboard の出力をそのまま出す）だと CP932 が出ることを確かめる = 再現の証拠。
    const naive = path.join(dir, 'read-old.ps1');
    fs.writeFileSync(naive, [cp932Preamble(), `Write-Output ${JSON.stringify(JP)}`].join('\n') + '\n');
    const rn = spawnSync('pwsh', ['-NoProfile', '-File', naive], { timeout: 120000 });
    assert.ok(rn.stdout.includes(Buffer.from([0x94, 0xe9])),
      `CP932 が再現していない（模擬が効いていない）: ${rn.stdout.toString('hex')}`);
  });

test('Windows(CP932 模擬): 書き戻しが日本語を UTF-8 のバイト列で渡す',
  { skip: hasPwsh ? false : 'pwsh が無いため skip' }, (t) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-clip-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    const out = path.join(dir, 'written.bin');

    const probe = path.join(dir, 'write.ps1');
    fs.writeFileSync(probe, [
      cp932Preamble(),
      // Windows の Set-Clipboard の代役。受け取った文字列を UTF-8 で書き出す。
      'function Set-Clipboard { param([string]$Value)',
      '  [IO.File]::WriteAllBytes($env:FAKE_CLIP_OUT, [Text.Encoding]::UTF8.GetBytes($Value)) }',
      mask.PS_WRITE_B64,
    ].join('\n') + '\n');

    const input = Buffer.from(Buffer.from(JP, 'utf8').toString('base64'), 'ascii');
    const r = spawnSync('pwsh', ['-NoProfile', '-File', probe],
      { input, env: Object.assign({}, process.env, { FAKE_CLIP_OUT: out }), timeout: 120000 });
    assert.strictEqual(r.status, 0, String(r.stderr));
    const got = fs.readFileSync(out);
    assert.strictEqual(got.toString('hex'), JP_HEX, `渡した日本語が壊れている: ${got.toString('hex')}`);
  });

function cp932Preamble() {
  return [
    "$ErrorActionPreference = 'Stop'",
    'try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }',
    'try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(932) } catch { }',
    'try { [Console]::InputEncoding  = [System.Text.Encoding]::GetEncoding(932) } catch { }',
  ].join('\n');
}
