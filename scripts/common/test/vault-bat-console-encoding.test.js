'use strict';
// vault-bat-console-encoding.test.js — 金庫のボタン（.bat）が CP932 コンソールで化けない見張り。
//
// 実機で起きた不具合（v1.17.4 で修正）:
//   「金庫ツールも文字化けする」。（上級）16「金庫に秘密をしまう」/ 17「金庫から秘密を取り出す」/
//   18「金庫の秘密を消す」の案内文と一覧が化けて読めなかった。
//
// 原因は .bat の中の文字コードの混在。1 本の powershell 行の先頭で、意味の違う 2 つを
// まとめて UTF-8 に固定していた:
//
//   [Console]::OutputEncoding … 「画面へ出す文字コード」。
//       .bat は chcp 932 した CP932 コンソールなので、ここを UTF-8 にすると
//       CP932 のコンソールへ UTF-8 のバイト列が流れて化ける。
//       実測（CP932 を模した pwsh）: " しまってあるもの:" が
//       20 e3 81 97 e3 81 be …（UTF-8）で出て、コンソールでは「縺励∪縺｣縺ｦ…」になる。
//   $OutputEncoding … 「ネイティブコマンド（node）へ渡す文字コード」。
//       node は UTF-8 前提なので、こちらは UTF-8 でなければならない。
//       （上級）16 は入力した秘密を `$p | & node ... --user-set` で node へ流すので、
//       これを落とすと日本語を含む値が壊れる。
//
// つまり「コンソール表示は CP932 / プロセス間の受け渡しは UTF-8」で分ける必要がある。
// v1.17.3 で「.bat が chcp 932 した実コンソールへ出すスクリプトは UTF-8 を強制すると
// 逆に化けるので対象外にする」と判断したのと同じ線引き。この 3 本はその『対象外にすべき側』
// なのに UTF-8 を強制していた、という食い違いだった。
//
// さらに（上級）17 / 18 は node の標準出力（金庫に入れた日本語の名前）を PowerShell で
// 受け取る。ここは逆に [Console]::OutputEncoding が UTF-8 でないと化ける。
// そこで「受け取る箇所だけ一時的に UTF-8 にして、直後に元へ戻す」形にしてある。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

const PKG = path.resolve(__dirname, '..', '..', '..');
// v1.18.0 再編でマスキング・金庫ボタンはサブフォルダ「キーと金庫」へ移った。
// 旧: （上級）10/11（マスキング）・（上級）16/17/18（金庫）
// 新: キーと金庫/10・11（マスキング）・7（しまう）/8（取り出す）/9（消す）
const START_DIR = path.join(PKG, 'workspace-template', 'スタート', 'キーと金庫');

// 今回の不具合で報告された 6 本（マスキング 2 本 + 金庫 3 本 = .bat 5 本、
// 10/11 は .command も見る）。番号で拾うので、名前が変わっても追従する。
const BUTTON_RE = /^(7|8|9|10|11)_/;

function buttons(ext) {
  return fs.readdirSync(START_DIR).filter((n) => BUTTON_RE.test(n) && n.endsWith(ext));
}

// .bat は CP932 なので、ASCII 部分を壊さずに読むには latin1 で開く。
function batText(name) {
  return fs.readFileSync(path.join(START_DIR, name)).toString('latin1');
}

test('報告された 6 本のボタンが揃っている', () => {
  const bats = buttons('.bat');
  const cmds = buttons('.command');
  assert.deepStrictEqual(
    bats.map((n) => n.match(BUTTON_RE)[1]).sort(),
    ['10', '11', '7', '8', '9'],
    `.bat が欠けている: ${bats.join(', ')}`);
  // mac 側も同じ 5 本あること（依頼者がどちらで踏んだか未確定なので両方を見張る）。
  assert.deepStrictEqual(
    cmds.map((n) => n.match(BUTTON_RE)[1]).sort(),
    ['10', '11', '7', '8', '9'],
    `.command が欠けている: ${cmds.join(', ')}`);
});

test('.bat は CP932 + CRLF + chcp 932 のまま（BOM を付けない）', () => {
  for (const n of buttons('.bat')) {
    const buf = fs.readFileSync(path.join(START_DIR, n));
    assert.ok(buf.includes(Buffer.from('\r\n')), `${n}: CRLF でない`);
    assert.ok(!buf.includes(Buffer.from([0xef, 0xbb, 0xbf])), `${n}: BOM が付いている`);
    assert.match(buf.toString('latin1'), /chcp 932/, `${n}: chcp 932 が無い`);
    // UTF-8 として読めてしまう＝CP932 で保存されていない、ということ。
    const asUtf8 = buf.toString('utf8');
    assert.ok(asUtf8.includes('�'),
      `${n}: UTF-8 で保存されている（cmd は CP932 で読むので画面が化ける）`);
  }
});

test('.command（mac）は UTF-8 のまま壊れていない', () => {
  for (const n of buttons('.command')) {
    const s = fs.readFileSync(path.join(START_DIR, n), 'utf8');
    assert.ok(!s.includes('�'), `${n}: UTF-8 として壊れている`);
    // mac 側でコードページをいじる余地は無い。紛れ込んでいたら誤り。
    assert.ok(!/OutputEncoding/.test(s), `${n}: mac 側に OutputEncoding が紛れ込んでいる`);
    assert.ok(!/\bchcp\b/.test(s), `${n}: mac 側に chcp が紛れ込んでいる`);
  }
});

// --- 本題: 画面用と node 受け渡し用の文字コードを混同していないか -------------------
test('金庫の .bat は画面表示を CP932 のままにしている（UTF-8 を強制しない）', () => {
  for (const n of buttons('.bat').filter((x) => /^[789]_/.test(x))) {
    const line = batText(n).split(/\r?\n/).find((l) => l.startsWith('powershell '));
    assert.ok(line, `${n}: powershell 行が見つからない`);

    // node へ渡す側は UTF-8 でなければならない（落とすと日本語の値・名前が壊れる）。
    assert.match(line, /\$OutputEncoding=\[Text\.Encoding\]::UTF8/,
      `${n}: $OutputEncoding が UTF-8 でない（node へ渡す日本語が壊れる）`);

    // 画面側を UTF-8 に固定したら、必ず同じ行で元へ戻していること。
    const set = (line.match(/\[Console\]::OutputEncoding=\[Text\.Encoding\]::UTF8/g) || []).length;
    const restore = (line.match(/\[Console\]::OutputEncoding=\$enc0/g) || []).length;
    assert.strictEqual(set, restore,
      `${n}: [Console]::OutputEncoding を UTF-8 にしたまま戻していない（CP932 コンソールで化ける）`);

    if (set > 0) {
      // 戻し先を控える文（$enc0=...）が、UTF-8 に切り替えるより前にあること。
      const save = line.indexOf('$enc0=[Console]::OutputEncoding');
      const first = line.indexOf('[Console]::OutputEncoding=[Text.Encoding]::UTF8');
      assert.ok(save >= 0 && save < first, `${n}: 元の文字コードを控える前に切り替えている`);
      // UTF-8 にするのは node の出力を受け取る箇所だけ（Read-Host / Write-Host を挟まない）。
      const between = line.slice(first, line.indexOf('[Console]::OutputEncoding=$enc0'));
      assert.ok(!/Write-Host|Read-Host/.test(between),
        `${n}: UTF-8 に切り替えている区間に画面入出力が入っている（そこが化ける）`);
      assert.match(between, /&\s*node\s/,
        `${n}: UTF-8 に切り替えた区間で node の出力を受け取っていない（切り替える理由が無い）`);
    }
  }
});

test('取り出す（8）/ 消す（9）は node の日本語の名前を UTF-8 で受け取っている', () => {
  for (const n of buttons('.bat').filter((x) => /^[89]_/.test(x))) {
    const line = batText(n).split(/\r?\n/).find((l) => l.startsWith('powershell '));
    // 一覧の取得は必ず UTF-8 の区間の中で行う（ここを CP932 で読むと名前が化ける）。
    const first = line.indexOf('[Console]::OutputEncoding=[Text.Encoding]::UTF8');
    const back = line.indexOf('[Console]::OutputEncoding=$enc0');
    const list = line.indexOf('--user-list');
    assert.ok(first >= 0 && back > first, `${n}: 一時的な UTF-8 の区間が無い`);
    assert.ok(list > first && list < back,
      `${n}: --user-list の取得が UTF-8 の区間の外にある（日本語の名前が化ける）`);
  }
});

// --- 実測: CP932 を模した PowerShell で、.bat の書き方そのものを走らせる -------------
// mac の pwsh は既定が UTF-8 なので、CodePagesEncodingProvider を登録して
// [Console]::OutputEncoding を 932 にし、「日本語 Windows の PowerShell 5.1」を模す。
// node の --user-list は日本語の名前を UTF-8 で出す代役に差し替える（金庫は Windows 専用のため）。
const pwshCheck = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'],
  { encoding: 'utf8', timeout: 60000 });
const hasPwsh = pwshCheck.status === 0;

const MSG = ' しまってあるもの:';
const NAMES = ['会社のメール', '仕事用パスワード'];

function cp932Preamble() {
  return [
    "$ErrorActionPreference = 'Stop'",
    'try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }',
    'try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(932) } catch { }',
    'try { [Console]::InputEncoding  = [System.Text.Encoding]::GetEncoding(932) } catch { }',
  ].join('\n');
}

// .bat の powershell 行から「文字コードに関する文」と「node の出力を受け取る文」だけを
// 順番どおりに取り出して、実際に走る形の probe を組み立てる。
// 実装を書き写すのではなく **ファイルの中身から組み立てる** ので、.bat を書き換えたら
// この実測も一緒に動く（見張りが形骸化しない）。
function probeFrom(line, fakeNodeJs) {
  const out = [];
  for (const stmt of line.split('; ')) {
    if (/\$names=@\(@\(&\s*node\s/.test(stmt)) {
      out.push(`$names=@(@(& node ${JSON.stringify(fakeNodeJs)}) | Where-Object { $_ -ne '' })`);
    } else if (/OutputEncoding/.test(stmt)) {
      // 先頭の `powershell ... -Command "` を落とす。
      out.push(stmt.replace(/^powershell\b.*?-Command\s+"/, ''));
    }
  }
  out.push('Write-Host $env:AI_SAFE_MSG_LIST');
  out.push('for($i=0; $i -lt $names.Count; $i++){ Write-Host ($names[$i]) }');
  return out.join('\n');
}

test('実測(CP932 模擬): 取り出す（8）の案内文と日本語の名前が CP932 のバイト列で出る',
  { skip: hasPwsh ? false : 'pwsh が無いため skip' }, (t) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-bat-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));

    // node の代役: 金庫の名前一覧を UTF-8 で出す（本物と同じ形）。
    const fake = path.join(dir, 'fake-node.js');
    fs.writeFileSync(fake, `process.stdout.write(${JSON.stringify(NAMES.join('\n') + '\n')});\n`, 'utf8');

    const name = buttons('.bat').find((x) => /^8_/.test(x));
    const line = batText(name).split(/\r?\n/).find((l) => l.startsWith('powershell '));
    const probe = path.join(dir, 'probe.ps1');
    fs.writeFileSync(probe, cp932Preamble() + '\n' + probeFrom(line, fake) + '\n', 'utf8');

    const r = spawnSync('pwsh', ['-NoProfile', '-File', probe],
      { env: Object.assign({}, process.env, { AI_SAFE_MSG_LIST: MSG }), timeout: 120000 });
    assert.strictEqual(r.status, 0, String(r.stderr));

    // 期待するのは CP932 のバイト列。chcp 932 のコンソールはこれをそのまま正しく描画する。
    const want = [MSG, ...NAMES].map((s) => cp932(s));
    for (let i = 0; i < want.length; i++) {
      assert.ok(r.stdout.includes(want[i]),
        `${[MSG, ...NAMES][i]} が CP932 で出ていない（画面が化ける）: ${r.stdout.toString('hex')}`);
    }
    // UTF-8 の日本語が混ざっていないこと（混ざっていたらそこが化ける）。
    assert.ok(!r.stdout.includes(Buffer.from(MSG.trim(), 'utf8')),
      `案内文が UTF-8 のまま出ている（CP932 コンソールで化ける）: ${r.stdout.toString('hex')}`);
  });

test('実測(CP932 模擬): 修正前の書き方だと実際に化ける（不具合の再現）',
  { skip: hasPwsh ? false : 'pwsh が無いため skip' }, (t) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-safe-bat-old-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    const probe = path.join(dir, 'old.ps1');
    // v1.17.3 までの形: 行の先頭で画面側まで UTF-8 に固定していた。
    fs.writeFileSync(probe, [
      cp932Preamble(),
      '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $OutputEncoding=[Text.Encoding]::UTF8',
      'Write-Host $env:AI_SAFE_MSG_LIST',
    ].join('\n') + '\n', 'utf8');

    const r = spawnSync('pwsh', ['-NoProfile', '-File', probe],
      { env: Object.assign({}, process.env, { AI_SAFE_MSG_LIST: MSG }), timeout: 120000 });
    assert.strictEqual(r.status, 0, String(r.stderr));
    // UTF-8 のバイト列がそのまま出る＝CP932 コンソールでは「縺励∪縺｣縺ｦ…」になる。
    assert.ok(r.stdout.includes(Buffer.from(MSG.trim(), 'utf8')),
      `不具合が再現しない（模擬が効いていない）: ${r.stdout.toString('hex')}`);
    assert.ok(!r.stdout.includes(cp932(MSG.trim())),
      `CP932 で出てしまっている（模擬が効いていない）: ${r.stdout.toString('hex')}`);
  });

// CP932 のバイト列を作る（Node に CP932 のエンコーダは無いので、必要な字だけ表で持つ）。
// テストで使う文字だけを載せる。増やすときは実機の値と突き合わせること。
const CP932_MAP = {
  ' ': [0x20], ':': [0x3a],
  し: [0x82, 0xb5], ま: [0x82, 0xdc], っ: [0x82, 0xc1], て: [0x82, 0xc4],
  あ: [0x82, 0xa0], る: [0x82, 0xe9], も: [0x82, 0xe0], の: [0x82, 0xcc],
  会: [0x89, 0xef], 社: [0x8e, 0xd0], メ: [0x83, 0x81], ー: [0x81, 0x5b], ル: [0x83, 0x8b],
  仕: [0x8e, 0x64], 事: [0x8e, 0x96], 用: [0x97, 0x70],
  パ: [0x83, 0x70], ス: [0x83, 0x58], ワ: [0x83, 0x8f], ド: [0x83, 0x68],
};
function cp932(s) {
  const bytes = [];
  for (const ch of s) {
    const b = CP932_MAP[ch];
    assert.ok(b, `CP932_MAP に ${ch} が無い（テストの表を足すこと）`);
    bytes.push(...b);
  }
  return Buffer.from(bytes);
}
