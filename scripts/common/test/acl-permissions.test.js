'use strict';
// acl-permissions.test.js — Windows のアクセス権まわりの回帰テスト（v1.17.2）。
//
// ● 何の事故を二度と起こさないためのテストか
//   v1.17.1 までの install.ps1 は導入の最後に次を実行していた:
//       icacls <~/.ai-safety> /inheritance:r /grant:r "$env:USERDOMAIN\$env:USERNAME:(OI)(CI)F" /T
//   `/inheritance:r` は継承 ACL を全部消し、そのうえで「USERDOMAIN\USERNAME」という
//   **文字列**に権限を与える。この名前は Microsoft アカウント / AzureAD 参加 /
//   USERDOMAIN が期待と違う PC では解決できず、解決に失敗すると
//   「継承は消えたが誰も権限を持たない」フォルダが残って **利用者本人ですら
//   読み書きできなくなる**。実機（受講者の Windows）で発生し、
//     ・gemini.dpapi が作られない（書き込めない）
//     ・deepseek.dpapi があるのに読めない（UnauthorizedAccessException）
//     ・診断が「PC を替えた／Windows を入れ直した可能性」と誤診する
//   が同時に起きた。非エンジニアには自力で回復できない重大不具合である。
//
// ● なぜ静的検査なのか（重要・未検証事項の明示）
//   mac の開発機では Windows の ACL を再現できない。実際に「締めたら入れなくなる」かどうかは
//   **Windows 実機でしか確認できない**。そこでここでは
//     (1) 付与先が名前ではなく SID であること
//     (2) 権限を触ったあとに本人の読み書きを検証していること
//     (3) 検証に失敗したら元へ戻していること
//     (4) `/inheritance:r`（継承の全削除）へ戻っていないこと
//     (5) 診断がアクセス拒否と復号失敗を区別していること
//   を**コードの形として固定**する。実機確認が必要な項目は docs/99_known_issues.md に
//   「実機確認が必要」として列挙してある。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PKG = path.resolve(__dirname, '..', '..', '..');
const REPAIR = path.join(PKG, 'scripts', 'windows', 'repair-permissions.ps1');
const INSTALL_PS1 = path.join(PKG, 'scripts', 'windows', 'install.ps1');
const INSTALL_SH = path.join(PKG, 'scripts', 'macos', 'install.sh');
const SHINDAN = path.join(PKG, 'scripts', 'windows', '診断.ps1');
const DOCTOR = path.join(PKG, 'scripts', 'windows', 'doctor.ps1');
const SAFETY_LIB = path.join(PKG, 'scripts', 'windows', 'lib', 'SafetyPolicy.ps1');
const BUTTON = path.join(PKG, 'workspace-template', 'スタート', '14_フォルダのアクセス権を直す.bat');
const VERSIONS = path.join(PKG, 'docs', 'tested_versions.md');
const KNOWN_ISSUES = path.join(PKG, 'docs', '99_known_issues.md');
const DOC13 = path.join(PKG, 'docs', '13_秘密の入れ物-APIキーの安全な持ち方.md');
const START_HTML = path.join(PKG, 'スタート.html');

// ★ 実機（受講者の Windows）で成功が確認された唯一の回復コマンド。
//   受講者に見せる案内は、どのファイルでもこの形と一致していなければならない。
//   /reset は「親から継承される既定の権限へ戻す」だけなので、SID の書式・特権・所有権に依存しない。
const OK_CMD = 'icacls "%USERPROFILE%\\.ai-safety" /reset /T /C /Q';

const read = (p) => fs.readFileSync(p, 'utf8');

// 「実際に走る行」だけを取り出す。コメント（原因の説明として旧コマンドを引用している）と、
// 画面へ文字列を出すだけの行（受講者に見せる手作業の回復コマンド）は実行ではないので除く。
// これを分けないと「原因を説明した」だけでテストが落ちる。
const codeOnly = (src) => src
  .split('\n')
  .filter((l) => !/^\s*#/.test(l))
  .filter((l) => !/^\s*(Say|SayOK|SayWarn|SayBad|Line|Write-Host|Write-Warning|echo)\b/.test(l))
  .join('\n');

test('修復スクリプト repair-permissions.ps1 が同梱されている', () => {
  assert.ok(fs.existsSync(REPAIR), REPAIR + ' がない');
});

test('.ps1 は BOM 付き UTF-8 + CRLF（配布規約）', () => {
  const buf = fs.readFileSync(REPAIR);
  assert.deepStrictEqual([...buf.subarray(0, 3)], [0xef, 0xbb, 0xbf], 'BOM が無い');
  const lf = (buf.toString('latin1').match(/\n/g) || []).length;
  const crlf = (buf.toString('latin1').match(/\r\n/g) || []).length;
  assert.strictEqual(lf, crlf, 'CRLF になっていない行がある');
});

test('付与先は名前ではなく SID を使う（今回の事故の直接原因）', () => {
  const s = read(REPAIR);
  assert.match(s, /WindowsIdentity\]::GetCurrent\(\)\.User/,
    '現在のユーザーの SID を取得していない');
  assert.match(s, /FileSystemAccessRule\(/, '.NET の ACL API で ACE を組み立てていない');
  // 名前の組み立てが復活していないこと（コメントでの原因説明は除く）。
  const code = codeOnly(s);
  assert.ok(!/USERDOMAIN/.test(code), 'USERDOMAIN による名前解決が復活している');
  assert.ok(!/\$env:USERNAME/.test(code), 'USERNAME による名前解決が復活している');
});

test('継承の全削除 (/inheritance:r) を行わない', () => {
  for (const f of [REPAIR, INSTALL_PS1]) {
    const code = codeOnly(read(f));
    assert.ok(!/inheritance:r/.test(code), path.basename(f) + ' に /inheritance:r が残っている');
  }
});

test('修復スクリプトは「継承を復活させる」側に倒す', () => {
  const s = read(REPAIR);
  // SetAccessRuleProtection($false, ...) = 継承を保護しない = 継承を復活させる
  assert.match(s, /SetAccessRuleProtection\(\$false,/,
    '継承を復活させる呼び出しが無い');
  assert.ok(!/SetAccessRuleProtection\(\$true/.test(s),
    '継承を切る（保護する）呼び出しが入っている');
});

test('権限を変えたあと、本人が実際に読み書きできることを検証する', () => {
  const s = read(REPAIR);
  assert.match(s, /function Test-SelfAccess/, '検証関数が無い');
  assert.match(s, /WriteAllText\(\$probe/, 'テストファイルを書いていない');
  assert.match(s, /ReadAllText\(\$probe/, 'テストファイルを読み返していない');
  assert.match(s, /Remove-Item -LiteralPath \$probe/, 'テストファイルを消していない');
  assert.match(s, /function Test-ExistingFilesReadable/, '既存ファイルの読み取り検証が無い');
  // 変更のあとに必ず検証を通す形になっていること。
  assert.match(s, /Invoke-GrantSelf[\s\S]{0,400}Test-AllAccess/,
    '権限を付けたあとに検証していない');
});

test('検証に失敗したら元の DACL へ戻す（締めたまま先へ進ませない）', () => {
  const s = read(REPAIR);
  assert.match(s, /\$beforeSddl\s*=\s*Get-DaclSddl/, '変更前の DACL を控えていない');
  assert.match(s, /function Restore-Dacl/, '巻き戻し関数が無い');
  assert.match(s, /Restore-Dacl \$rootItem \$beforeSddl/, '失敗時に控えへ戻していない');
  // 「広すぎる ACE を外す」段でも、検証済みの状態へ戻せること。
  assert.match(s, /Restore-Dacl \$rootItem \$safeSddl/, '締める操作の巻き戻しが無い');
  // 控えも復元も Access セクションだけであること（SACL を持ち回さない）。
  assert.match(s, /GetSecurityDescriptorSddlForm\(\$ACCESS_ONLY\)/, '控えが Access セクション限定でない');
  assert.match(s, /SetSecurityDescriptorSddlForm\(\$Sddl, \$ACCESS_ONLY\)/, '復元が Access セクション限定でない');
});

// ===== SACL 事故の再発防止（2 度目の実機失敗から） =====
// 最初の修正は Get-Acl → SetAccessRuleProtection → Set-Acl だったが、受講者の実機で
//     Set-Acl : プロセスにはこの操作に必要な 'SeSecurityPrivilege' 特権が与えられていません。
//     [Set-Acl], PrivilegeNotHeldException
// となり、**修復処理そのものが動かなかった**。Get-Acl / Set-Acl はセキュリティ記述子を
// 広く扱うため SACL（監査情報）が混ざり、そうなると SeSecurityPrivilege が要求される。
// この特権は**所有者であっても既定では持っていない**（管理者の明示的な昇格が要る種類）。
// 以下 3 本のテストで「二度と Get-Acl/Set-Acl に戻らない」ことを固定する。
const ACL_SITES = () => [
  ['repair-permissions.ps1', REPAIR],
  ['install.ps1', INSTALL_PS1],
  ['診断.ps1', SHINDAN],
  ['lib/SafetyPolicy.ps1', SAFETY_LIB],
];

test('ACL を触る全箇所で Get-Acl / Set-Acl コマンドレットを使わない', () => {
  for (const [name, file] of ACL_SITES()) {
    const code = codeOnly(read(file));
    assert.ok(!/\bGet-Acl\b/.test(code),
      name + ' が Get-Acl を使っている（SACL が混ざり標準ユーザーで失敗する）');
    assert.ok(!/\bSet-Acl\b/.test(code),
      name + ' が Set-Acl を使っている（SeSecurityPrivilege が要求され失敗する）');
  }
});

test('ACL を触る全箇所で AccessControlSections::Access を明示する', () => {
  for (const [name, file] of ACL_SITES()) {
    const s = read(file);
    assert.match(s, /AccessControlSections\]::Access/,
      name + ' が Access セクションを明示していない（SACL に触る恐れ）');
  }
});

test('DACL の取得・書き戻しは GetAccessControl / SetAccessControl を使う', () => {
  for (const [name, file] of [['repair-permissions.ps1', REPAIR], ['install.ps1', INSTALL_PS1], ['lib/SafetyPolicy.ps1', SAFETY_LIB]]) {
    const s = read(file);
    assert.match(s, /GetAccessControl/, name + ' に GetAccessControl が無い');
    assert.match(s, /SetAccessControl/, name + ' に SetAccessControl が無い');
    // PowerShell 7 では拡張メソッドなのでインスタンス呼び出しに解決されない。
    // 反射で両方（インスタンス/拡張）を探していること。
    assert.match(s, /FileSystemAclExtensions/,
      name + ' が PowerShell 7 の拡張メソッド経路を持っていない');
  }
});

test('SACL の教訓がコメントとして残っている（次に触る人が同じ罠を踏まないため）', () => {
  for (const [name, file] of [['repair-permissions.ps1', REPAIR], ['install.ps1', INSTALL_PS1], ['lib/SafetyPolicy.ps1', SAFETY_LIB]]) {
    const s = read(file);
    assert.match(s, /SeSecurityPrivilege/, name + ' に SeSecurityPrivilege の説明が無い');
    assert.match(s, /SACL/, name + ' に SACL の説明が無い');
  }
});

test('ACL を触る全箇所で付与先は名前ではなく SID', () => {
  for (const [name, file] of [['repair-permissions.ps1', REPAIR], ['install.ps1', INSTALL_PS1], ['lib/SafetyPolicy.ps1', SAFETY_LIB]]) {
    const code = codeOnly(read(file));
    assert.match(code, /WindowsIdentity\]::GetCurrent\(\)\.User/,
      name + ' が SID（.User）を付与先にしていない');
    // `.Name` は「あなた: <名前>」の画面表示にだけ使ってよい（$meName への代入のみ）。
    // ACE の付与先に使うと、環境によって解決できず誰も権限を持たない状態を作る。
    for (const line of code.split('\n').filter((l) => /WindowsIdentity\]::GetCurrent\(\)\.Name/.test(l))) {
      assert.match(line, /\$meName\s*=/,
        name + ' が名前（.Name）を表示以外に使っている: ' + line.trim());
    }
    assert.ok(!/FileSystemAccessRule\([\s\S]{0,240}\$meName/.test(code),
      name + ' が表示用の名前を ACE の付与先に渡している');
  }
});

test('install.ps1 の mac フック読み取り専用化は失敗しても導入を止めない', () => {
  const s = read(INSTALL_PS1);
  // $ErrorActionPreference = "Stop" なので、try/catch が無いと ACL 失敗で導入全体が落ちる。
  assert.match(s, /mac 側フックの読み取り専用化をスキップしました/,
    'ACL 失敗時に導入を継続する catch が無い');
});

test('外部コマンドにはタイムアウトを付ける', () => {
  const s = read(REPAIR);
  assert.match(s, /WaitForExit\(\$TimeoutMs\)/, '外部コマンドにタイムアウトが無い');
  assert.match(s, /Invoke-IcaclsReset 60000/, 'icacls /reset のタイムアウト値が渡されていない');
  assert.match(s, /Invoke-Takeown 60000/, 'takeown のタイムアウト値が渡されていない');
  assert.match(s, /function Test-Deadline/, '木をたどる処理に打ち切りが無い');
});

// ===== 実機で成功した方法へ寄せる（3 度目の実機確認から） =====
// 依頼者の Windows 実機で成功したのは cmd の `icacls "<path>" /reset /T /C /Q` だけだった。
// 失敗したのは (1) icacls /grant "<SID>:..."（* の前置が必須）(2) takeown（アクセス拒否の大量発生）
// (3) Get-Acl/Set-Acl（SeSecurityPrivilege）。(4) GetAccessControl+SetAccessControl は未検証。
test('第一の手段は icacls /reset（実機で成功が確認された唯一の方法）', () => {
  const s = read(REPAIR);
  assert.match(s, /function Invoke-IcaclsReset/, 'icacls /reset の実装が無い');
  assert.match(s, /-FilePath "icacls\.exe"/, 'icacls を外部コマンドとして起動していない');
  assert.match(s, /'\/reset', '\/T', '\/C', '\/Q'/, '/reset /T /C /Q の指定になっていない');
  // 呼び出し順: icacls /reset が .NET の DACL 経路より先であること。
  const iReset = s.indexOf('if (Invoke-IcaclsReset 60000)');
  const iGrant = s.indexOf('if (Invoke-GrantSelf $rootItem)');
  assert.ok(iReset > 0, 'icacls /reset を本編で呼んでいない');
  assert.ok(iGrant > 0, '第二の手段（DACL）を本編で呼んでいない');
  assert.ok(iReset < iGrant, 'icacls /reset が第一の手段になっていない');
});

test('icacls に SID を渡さない（* の前置漏れで実機が失敗した形へ戻らない）', () => {
  const code = codeOnly(read(REPAIR));
  assert.ok(!/icacls[^\n]*\/grant/.test(code), 'icacls /grant が実行行に復活している');
});

test('takeown は既定で実行しない（実機でアクセス拒否が大量発生し、しかも不要だった）', () => {
  const s = read(REPAIR);
  assert.match(s, /\[switch\]\$NoTakeown/, '-NoTakeown（互換）が無い');
  assert.match(s, /\[switch\]\$Takeown/, '-Takeown（明示指定）が無い');
  // 既定では走らない = 呼び出しが $Takeown で守られていること。
  assert.match(s, /-not \$accessOk -and \$Takeown -and -not \$NoTakeown/,
    'takeown が -Takeown 明示指定のときだけの最後の手段になっていない');
  // install も修復ボタンも -Takeown を渡さないこと。
  assert.ok(!/-Takeown\b/.test(codeOnly(read(INSTALL_PS1))), 'install.ps1 が -Takeown を渡している');
  const bat = spawnSync('iconv', ['-f', 'CP932', '-t', 'UTF-8', BUTTON], { encoding: 'utf8', timeout: 30000 });
  assert.strictEqual(bat.status, 0, '.bat が CP932 として読めない');
  assert.ok(!/-Takeown\b/.test(bat.stdout), '修復ボタンが -Takeown を渡している');
});

test('すでに読み書きできるときは権限に触らない（install が権限を壊す経路を断つ）', () => {
  const s = read(REPAIR);
  assert.match(s, /\$accessOk = Test-AllAccess \$Path\r?\n\r?\nif \(\$accessOk\) \{/,
    '最初に現状を検証して、問題なければ触らない分岐が無い');
  assert.match(s, /すでにあなた自身が読み書きできます。アクセス権には触りません。/,
    '無変更で終える経路のメッセージが無い');
});

test('実機で失敗した 4 つの方法が、理由つきでコード内コメントに残っている', () => {
  const s = read(REPAIR);
  for (const [needle, why] of [
    ['マッピングは実行されませんでした', 'icacls に SID を渡して失敗した記録'],
    ['`*` の前置が必須', 'SID に * を前置する必要があるという記録'],
    ['アクセスが拒否されました」が大量発生', 'takeown が失敗した記録'],
    ['PrivilegeNotHeldException', 'Get-Acl/Set-Acl が失敗した記録'],
    ['SeSecurityPrivilege', 'SACL/特権の説明'],
    ['**未検証**', 'GetAccessControl/SetAccessControl が未検証である記録'],
  ]) {
    assert.ok(s.includes(needle), why + ' がコメントに無い: ' + needle);
  }
});

test('受講者に見せる回復コマンドが、実機で成功した形と全ファイルで一致する', () => {
  // .bat は batch のエスケープで %% と書くため、表示される形へ戻してから比べる。
  const batOut = spawnSync('iconv', ['-f', 'CP932', '-t', 'UTF-8', BUTTON], { encoding: 'utf8', timeout: 30000 });
  assert.strictEqual(batOut.status, 0, '.bat が CP932 として読めない');
  const sites = [
    ['repair-permissions.ps1', read(REPAIR)],
    ['診断.ps1', read(SHINDAN)],
    ['doctor.ps1', read(DOCTOR)],
    ['install.ps1', read(INSTALL_PS1)],
    ['14_フォルダのアクセス権を直す.bat', batOut.stdout.replace(/%%/g, '%')],
    ['docs/99_known_issues.md', read(KNOWN_ISSUES)],
    ['docs/13_秘密の入れ物…', read(DOC13)],
    ['スタート.html', read(START_HTML)],
  ];
  for (const [name, raw] of sites) {
    const text = raw.replace(/[`]/g, '');  // markdown のコード記法をはがす
    assert.ok(text.includes(OK_CMD), name + ' に実機成功版のコマンドが無い: ' + OK_CMD);
    // 「cmd で実行する」ことの明記。PowerShell では %USERPROFILE% が展開されない。
    assert.match(text, /コマンドプロンプト|\(cmd\)|（cmd）/, name + ' に cmd で実行する旨が無い');
    assert.match(text, /PowerShell では %USERPROFILE% が展開されない/,
      name + ' に「PowerShell では展開されない」注意が無い');
  }
});

test('コマンドが苦手な受講者向けに、エクスプローラーでの回復手順も併記されている', () => {
  const batOut = spawnSync('iconv', ['-f', 'CP932', '-t', 'UTF-8', BUTTON], { encoding: 'utf8', timeout: 30000 });
  assert.strictEqual(batOut.status, 0, '.bat が CP932 として読めない');
  const sites = [
    ['repair-permissions.ps1', read(REPAIR)],
    ['診断.ps1', read(SHINDAN)],
    ['doctor.ps1', read(DOCTOR)],
    ['14_フォルダのアクセス権を直す.bat', batOut.stdout],
    ['docs/99_known_issues.md', read(KNOWN_ISSUES)],
    ['docs/13_秘密の入れ物…', read(DOC13)],
    ['スタート.html', read(START_HTML)],
  ];
  for (const [name, text] of sites) {
    assert.ok(text.includes('継承の有効化'), name + ' にエクスプローラー手順（継承の有効化）が無い');
    assert.ok(text.includes('子オブジェクトのアクセス許可エントリ'),
      name + ' にエクスプローラー手順（子オブジェクトの置き換え）が無い');
  }
});

test('install.ps1 は修復スクリプト経由で権限を整え、改ざん検知にも入れる', () => {
  const s = read(INSTALL_PS1);
  assert.match(s, /repair-permissions\.ps1/, 'install が修復スクリプトを呼んでいない');
  assert.match(s, /-Quiet -NoTakeown/, 'install が静か/takeown 無しで呼んでいない');
  assert.match(s, /'scripts\/windows\/repair-permissions\.ps1'/,
    '改ざん検知（Test-DistributionHash）の一覧に入っていない');
  assert.ok(!/icacls/.test(codeOnly(s)), 'install.ps1 が icacls を実行している');
});

test('受講者が押せる修復ボタンがある（CP932 + CRLF + 行頭 chcp 932）', () => {
  assert.ok(fs.existsSync(BUTTON), BUTTON + ' がない');
  const buf = fs.readFileSync(BUTTON);
  const lf = (buf.toString('latin1').match(/\n/g) || []).length;
  const crlf = (buf.toString('latin1').match(/\r\n/g) || []).length;
  assert.strictEqual(lf, crlf, '.bat が CRLF になっていない');
  assert.notDeepStrictEqual([...buf.subarray(0, 3)], [0xef, 0xbb, 0xbf], '.bat に BOM が付いている');
  // CP932 として復号できること（UTF-8 の .bat は日本語 Windows で即文字化けする）。
  const iconv = spawnSync('iconv', ['-f', 'CP932', '-t', 'UTF-8', BUTTON], { encoding: 'utf8', timeout: 30000 });
  assert.strictEqual(iconv.status, 0, '.bat が CP932 として読めない');
  const text = iconv.stdout;
  assert.match(text, /^@echo off\r?\nchcp 932/, '行頭に chcp 932 が無い');
  assert.ok(!/chcp\s+65001/i.test(text), 'chcp 65001 を指定している');
  assert.match(text, /repair-permissions\.ps1/, '修復スクリプトを呼んでいない');
  assert.match(text, /%HERE%/, '相対解決（%HERE%）をしていない');
});

test('診断はアクセス拒否と復号失敗を区別する（誤診の修正）', () => {
  const s = read(SHINDAN);
  assert.match(s, /function Test-AccessDeniedError/, 'アクセス拒否の判定関数が無い');
  assert.match(s, /UnauthorizedAccessException/, 'UnauthorizedAccessException を見ていない');
  // 「PC を替えた」案内は、アクセス拒否でないときだけに限定されていること。
  assert.match(s, /if \(Test-AccessDeniedError \$_\) \{[\s\S]{0,600}\} else \{[\s\S]{0,300}PC を替えた/,
    '「PC を替えた」案内がアクセス拒否のときにも出る形のまま');
  assert.match(s, /キーの作り直しは不要/, 'アクセス拒否のときに「作り直し不要」を伝えていない');
});

test('診断は修復手段をコピペできる形で表示する', () => {
  const s = read(SHINDAN);
  assert.match(s, /function Show-PermissionRepairHint/, '修復案内が無い');
  assert.match(s, /14_フォルダのアクセス権を直す/, '修復ボタンの案内が無い');
  // ★ 実機で成功した形（cmd で icacls /reset）だけを出す。SID を使う形・takeown を
  //   案内に書き戻さないこと（どちらも実機で失敗した。理由は下の失敗リストのテスト参照）。
  //   判定対象は「受講者の画面に出る本文」= Show-PermissionRepairHint の中身だけ。
  //   関数の外にある「なぜ書いてはいけないか」のコメントまで拾うと、記録を残せなくなる。
  const body = s.slice(s.indexOf('function Show-PermissionRepairHint'));
  const hint = body.slice(0, body.indexOf('\n}'));
  assert.ok(hint.includes(OK_CMD), '実機で成功した回復コマンドが案内に無い');
  assert.ok(!/takeown/i.test(hint), '実機で失敗した takeown の案内が復活している');
  assert.ok(!/\/grant/.test(hint), '実機で失敗した icacls /grant の案内が復活している');
  assert.ok(!/GetCurrent\(\)\.User\.Value/.test(hint),
    '実機で失敗した SID 直書きの案内が復活している');
});

test('診断はアクセス権が壊れているとき「未登録」と誤って言わない', () => {
  const s = read(SHINDAN);
  assert.match(s, /\$permBroken/, 'アクセス権の破損フラグが無い');
  assert.match(s, /if \(\$permBroken\) \{ Line \("  " \+ \$k\.Name \+ ": 判定できません/,
    '他のキーの判定が「未登録」のまま');
});

test('doctor も金庫フォルダのアクセス権を見る', () => {
  const s = read(DOCTOR);
  assert.match(s, /secretDirAccessible/, 'アクセス権の判定が無い');
  assert.match(s, /金庫フォルダのアクセス権/, '結果行が無い');
  assert.match(s, /14_フォルダのアクセス権を直す/, '直し方の案内が無い');
});

test('mac 側も chmod のあとに読み書きを検証し、失敗したら戻す', () => {
  const s = read(INSTALL_SH);
  assert.match(s, /_perm_probe/, '検証プローブが無い');
  assert.match(s, /chmod 755 "\$HOME\/\.ai-safety"/, '失敗時の巻き戻しが無い');
});

test('修復スクリプトが改ざん検知の表に載っていて、ハッシュが一致する', () => {
  const table = read(VERSIONS);
  const rel = 'scripts/windows/repair-permissions.ps1';
  const line = table.split('\n').find((l) => l.startsWith('| ' + rel + ' |'));
  assert.ok(line, 'docs/tested_versions.md に ' + rel + ' の行が無い');
  const m = line.match(/\|\s*[0-9a-f]{64}\s*\|/);
  assert.ok(m, 'ハッシュ列が無い');
  const listed = m[0].replace(/[|\s]/g, '');
  const actual = crypto.createHash('sha256').update(fs.readFileSync(REPAIR)).digest('hex');
  assert.strictEqual(listed, actual, 'ハッシュ表が現物と一致しない（表の追従漏れ）');
});

test('既に壊れた受講者向けの回復手順が docs に書いてある', () => {
  const s = read(KNOWN_ISSUES);
  assert.match(s, /アクセスが拒否/, '症状が書かれていない');
  assert.match(s, /14_フォルダのアクセス権を直す/, '回復手段が書かれていない');
  assert.match(s, /実機確認が必要/, '未検証事項が明示されていない');
  // 実機で失敗した 4 つの方法が理由つきで残っていること（同じ轍を踏ませないため）。
  assert.match(s, /実機で失敗した方法/, '失敗した方法の一覧が無い');
  for (const needle of ['マッピングは実行されませんでした', 'takeown', 'PrivilegeNotHeldException', '未検証']) {
    assert.ok(s.includes(needle), '失敗記録が不足: ' + needle);
  }
});

// ★ 構文検査より一段深い実測。mac では Windows の ACL を「操作」できないが、
//   .NET の型解決とメソッド解決は mac の pwsh でも同じ仕組みで行われるので、
//   「DACL だけを扱う層がこの実行環境で結線できるか（型・引数の妥当性）」は実測できる。
//   -SelfTest はまさにそれを行い、1 つでも結線できなければ非 0 で終わる。
//   これにより「Access セクション付きの GetAccessControl/SetAccessControl が本当に存在し、
//   SecurityIdentifier を受ける FileSystemAccessRule のコンストラクタが本当にある」ことまで
//   確認できる（引数の型を間違えていれば、ここで落ちる）。
test('-SelfTest: DACL 層が実際に結線できる（型・引数の実測。pwsh がある環境でのみ）', (t) => {
  const probe = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'],
    { encoding: 'utf8', timeout: 60000 });
  if (probe.status !== 0) { t.skip('pwsh が無い'); return; }
  const r = spawnSync('pwsh', ['-NoProfile', '-File', REPAIR, '-SelfTest'],
    { encoding: 'utf8', timeout: 120000 });
  const out = (r.stdout || '') + (r.stderr || '');
  assert.strictEqual(r.status, 0, 'DACL 層が結線できない: ' + out);
  for (const need of [
    'DirectoryInfo.GetAccessControl(Access のみ)',
    'DirectoryInfo.SetAccessControl',
    'FileInfo.GetAccessControl(Access のみ)',
    'FileInfo.SetAccessControl',
    'FileSystemAccessRule(SID, 権限, 継承, 伝播, 許可)',
  ]) {
    assert.ok(out.includes(need + ': 呼べます'), need + ' が結線できていない: ' + out);
  }
  assert.ok(!out.includes('呼べません'), '結線できない項目がある: ' + out);
});

// mac では ACL を再現できないので「実際に権限が直るか」は測れない。ここで測れるのは
// 「非 Windows では何もせず正常終了する（＝ install.sh 経由の mac 導入を壊さない）」ことだけ。
// 実機での動作確認が必要な項目は docs/99_known_issues.md を参照。
test('非 Windows では何もせず正常終了する（pwsh がある環境でのみ）', (t) => {
  const probe = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'],
    { encoding: 'utf8', timeout: 60000 });
  if (probe.status !== 0) { t.skip('pwsh が無い'); return; }
  if (process.platform === 'win32') { t.skip('Windows 実機ではこの分岐を通らない'); return; }
  const r = spawnSync('pwsh', ['-NoProfile', '-File', REPAIR, '-Quiet', '-NoTakeown'],
    { encoding: 'utf8', timeout: 120000 });
  assert.strictEqual(r.status, 0, '非 Windows で異常終了した: ' + (r.stdout || '') + (r.stderr || ''));
});

test('PowerShell として構文が通る（pwsh がある環境でのみ）', (t) => {
  const probe = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'],
    { encoding: 'utf8', timeout: 60000 });
  if (probe.status !== 0) { t.skip('pwsh が無い'); return; }
  for (const f of [REPAIR, SHINDAN, DOCTOR, INSTALL_PS1]) {
    const r = spawnSync('pwsh', ['-NoProfile', '-Command',
      '$e=$null;$t=$null;' +
      '[void][System.Management.Automation.Language.Parser]::ParseFile(' + JSON.stringify(f).replace(/"/g, "'") + ',[ref]$t,[ref]$e);' +
      'if($e -and $e.Count){$e|ForEach-Object{Write-Output $_.Message};exit 1}'],
      { encoding: 'utf8', timeout: 120000 });
    assert.strictEqual(r.status, 0, path.basename(f) + ' の構文エラー: ' + (r.stdout || '') + (r.stderr || ''));
  }
});
