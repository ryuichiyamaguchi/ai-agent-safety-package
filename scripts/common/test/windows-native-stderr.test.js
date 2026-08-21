'use strict';
// Windows PowerShell 5.1 の「ネイティブコマンドの標準エラーでスクリプトが止まる」事故の回帰テスト。
//
// 何が起きたか（v1.17.2 実機・受講者の Windows）:
//   更新で ds-gateway.js の中身が変わり、gateway-token.js の --probe が
//   「not reusable (fingerprint-mismatch)」を返した。これは「古い gateway を立て直せばよい」
//   という正常系の判断でしかない。ところが理由が標準エラーへ出ており、ランチャー側は
//       & $NodePath $GatewayTokenJs '--probe' ... 2>$null | Out-Null
//   の形で呼んでいた。Windows PowerShell 5.1 は、ネイティブコマンドの標準エラーを
//   リダイレクト（2>$null / 2>&1）やパイプで受けた時点でその 1 行を NativeCommandError という
//   エラーレコードに変換する。$ErrorActionPreference = 'Stop' の下ではこれが終了時エラーになり、
//   OpenCode / d-claude の起動が丸ごと止まった。2>$null では抑止できない
//   （捨て先を変えても、リダイレクトそのものが変換の引き金だから）。
//
// このテストが固定すること:
//   1. $ErrorActionPreference = 'Stop' を敷く .ps1 に、危険な「& ネイティブ + stderr リダイレクト」
//      の直書きが残っていないこと
//   2. その代わりに Invoke-NativeQuiet（終了コードで判定するヘルパー）が定義されていること
//
// なぜ静的検査なのか:
//   この挙動は Windows PowerShell 5.1 固有で、PowerShell 7（pwsh）は同じ変換をしないため
//   mac の pwsh では再現しない。実挙動の確認は Windows 実機が必要。ここは
//   「危険な書き方が二度と入らないこと」を機械的に固定する役割に絞る。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const WIN_DIR = path.join(__dirname, '..', '..', 'windows');

function listPs1(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      // test/ 配下はテストハーネス自身。受講者の PC では動かないので対象外。
      if (entry.name === 'test') continue;
      out.push(...listPs1(full));
    } else if (entry.name.endsWith('.ps1')) {
      out.push(full);
    }
  }
  return out;
}

// `& <コマンド> ... 2>$null` / `... 2>&1` の直書きを拾う。
// `&` で始まる行だけを見る（Get-Content 等の PowerShell コマンドレットは対象外）。
const NATIVE_CALL_WITH_STDERR_REDIRECT = /(^|[\s({=])&\s+[^\r\n|;]*?\d?2>(&1|\$null|\s*\$null)/;

test('$ErrorActionPreference=Stop の .ps1 に「& ネイティブ + stderr リダイレクト」の直書きが残っていない', () => {
  const offenders = [];
  for (const file of listPs1(WIN_DIR)) {
    const text = fs.readFileSync(file, 'utf8');
    if (!/\$ErrorActionPreference\s*=\s*['"]Stop['"]/.test(text)) continue;
    const lines = text.split(/\r?\n/);
    lines.forEach((line, i) => {
      const code = line.replace(/^\s*#.*$/, '');
      if (!NATIVE_CALL_WITH_STDERR_REDIRECT.test(code)) return;
      // 直前で $ErrorActionPreference を 'Continue' に戻している区間は安全（Invoke-NativeQuiet 本体など）。
      // 変換自体は起きるが、Stop ではないので終了時エラーにならない。
      const guarded = lines
        .slice(Math.max(0, i - 12), i)
        .some((prev) => /\$ErrorActionPreference\s*=\s*['"]Continue['"]/.test(prev));
      if (guarded) return;
      offenders.push(`${path.relative(WIN_DIR, file)}:${i + 1}: ${line.trim()}`);
    });
  }
  assert.deepStrictEqual(
    offenders,
    [],
    'PowerShell 5.1 では stderr のリダイレクトが NativeCommandError になり、'
    + 'EAP=Stop 下で起動が止まる。Invoke-NativeQuiet を使うこと:\n' + offenders.join('\n'),
  );
});

test('ランチャーには Invoke-NativeQuiet（終了コードで判定するヘルパー）がある', () => {
  const required = [
    'opencode/launch-opencode-deepseek.ps1',
    'deepseek/launch-deepseek-gateway.ps1',
    'launch-integrated.ps1',
    'launch-claude-safe.ps1',
    'lib/IsolationDrills.ps1',
  ];
  for (const rel of required) {
    const file = path.join(WIN_DIR, ...rel.split('/'));
    const text = fs.readFileSync(file, 'utf8');
    assert.match(text, /function Invoke-NativeQuiet/, `${rel} に Invoke-NativeQuiet が無い`);
    // 握り潰しにならないよう、必ず終了コードを返すこと。
    assert.match(text, /ExitCode\s*=\s*\$code/, `${rel} の Invoke-NativeQuiet が終了コードを返していない`);
    // 呼び出しの外へ設定を漏らさないこと。
    assert.match(text, /\$ErrorActionPreference\s*=\s*\$prevEap/, `${rel} が ErrorActionPreference を戻していない`);
  }
});

test('gateway の再利用判定は終了コードだけで行う（メッセージ本文に依存しない）', () => {
  for (const rel of ['opencode/launch-opencode-deepseek.ps1', 'deepseek/launch-deepseek-gateway.ps1']) {
    const file = path.join(WIN_DIR, ...rel.split('/'));
    const text = fs.readFileSync(file, 'utf8');
    assert.match(
      text,
      /\$probe\s*=\s*Invoke-NativeQuiet[\s\S]{0,400}?return\s*\(\$probe\.ExitCode\s*-eq\s*0\)/,
      `${rel}: Test-GatewayReusable は Invoke-NativeQuiet の ExitCode で判定すること`,
    );
  }
});

test('gateway-token.js の --probe は正常系を標準エラーへ出さない', () => {
  const text = fs.readFileSync(path.join(__dirname, '..', 'gateway-token.js'), 'utf8');
  const probeBlock = text.slice(text.indexOf("argv.includes('--probe')"));
  const notReusable = probeBlock.slice(0, probeBlock.indexOf('--fingerprint'));
  assert.ok(
    !/stderr\.write/.test(notReusable),
    '「再利用できない」は正常系。標準エラーへ書くと PowerShell 5.1 の呼び出し側が止まる',
  );
  // 本当の異常（例外）は従来どおり標準エラーへ出すこと。
  assert.match(text, /run\(\)\.catch\(\(e\) => \{\s*process\.stderr\.write/);
});

// --- 実挙動の確認（可能な範囲で） -------------------------------------------------------
// PowerShell 7（pwsh）は 5.1 と違い、標準エラーのリダイレクトを NativeCommandError に変換
// しないので、事故そのものは mac では再現できない。ただし PowerShell 7 には
// $PSNativeCommandUseErrorActionPreference という近い性質のスイッチがある（ネイティブコマンドの
// 非ゼロ終了を $ErrorActionPreference に従わせる）。これを有効にすると
// 「終了コードが 1 なだけで丸ごと止まる」という同じ形の事故が起き、
// 古い書き方は落ちて Invoke-NativeQuiet は落ちないことを実際に確認できる。
// PowerShell 7.4 以降ではこのスイッチが既定で有効な構成もあるため、この確認自体にも意味がある。
const pwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8' });
const HAS_PWSH = pwsh.status === 0;

test('pwsh: Invoke-NativeQuiet はネイティブコマンドの失敗で例外にならず終了コードを返す', { skip: HAS_PWSH ? false : 'pwsh が無い環境' }, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ps-native-'));
  const noisy = path.join(dir, 'noisy.js');
  fs.writeFileSync(noisy, "process.stderr.write('gateway-token: not reusable (fingerprint-mismatch)\\n');\nprocess.exit(1);\n");

  // ランチャー本体からヘルパーの定義をそのまま切り出して使う（テスト用に書き写さない）。
  // .ps1 は CRLF なので、切り出す前に改行を正規化する。
  const launcher = fs.readFileSync(
    path.join(WIN_DIR, 'opencode', 'launch-opencode-deepseek.ps1'), 'utf8',
  ).replace(/\r\n/g, '\n');
  const start = launcher.indexOf('function Invoke-NativeQuiet');
  assert.notStrictEqual(start, -1, 'ランチャーから Invoke-NativeQuiet を取り出せない');
  const end = launcher.indexOf('\n}\n', start);
  assert.ok(end > start, 'Invoke-NativeQuiet の終わりを特定できない');
  const helper = launcher.slice(start, end + 3);
  assert.match(helper, /ExitCode\s*=\s*\$code/, '切り出したヘルパーが不完全');

  const script = [
    '$PSNativeCommandUseErrorActionPreference = $true',
    "$ErrorActionPreference = 'Stop'",
    helper,
    `$node = (Get-Command node).Source`,
    `$js = '${noisy.replace(/'/g, "''")}'`,
    // 1) 旧来の書き方は落ちる（この事故の形）
    'try { & $node $js 2>$null | Out-Null; Write-Output "OLD:ok" } catch { Write-Output "OLD:threw" }',
    // 2) 新しいヘルパーは落ちず、終了コードを返す
    'try { $r = Invoke-NativeQuiet -File $node -Arguments @($js); Write-Output ("NEW:ok:" + $r.ExitCode) } catch { Write-Output "NEW:threw" }',
    // 3) 呼び出しの外へ設定を漏らさない
    'Write-Output ("EAP:" + $ErrorActionPreference)',
  ].join('\n');

  const run = spawnSync('pwsh', ['-NoProfile', '-Command', script], { encoding: 'utf8' });
  const out = String(run.stdout);
  assert.match(out, /OLD:threw/, '旧来の書き方はこの条件で落ちること（事故の再現）');
  assert.match(out, /NEW:ok:1/, 'Invoke-NativeQuiet は落ちずに終了コード 1 を返すこと');
  assert.match(out, /EAP:Stop/, '呼び出しのあと ErrorActionPreference が Stop に戻っていること');
});
