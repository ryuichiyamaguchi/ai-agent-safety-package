'use strict';
// Windows d-claude の実機事故 2 件を、ソースで再発させないための見張り。
//
// 1) 毎回「AI 判定の起動に失敗しました」
//    PowerShell 5.1（.NET Framework）には ProcessStartInfo.StandardInputEncoding が無い。
//    触ると catch に落ち、グレーな Bash のたびに確認ダイアログになる。
//
// 2) gemini-vision を含む MCP が起動しない
//    ConvertTo-Json が要素 1 個の args をスカラーに潰し、Set-Content -Encoding UTF8 が BOM を付ける。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..', '..');
const guard = fs.readFileSync(path.join(root, 'scripts', 'windows', 'guard-bash.ps1'), 'utf8');
const launch = fs.readFileSync(path.join(root, 'scripts', 'windows', 'launch-claude-safe.ps1'), 'utf8');
const macLaunch = fs.readFileSync(path.join(root, 'scripts', 'macos', 'launch-claude-safe.sh'), 'utf8');

test('guard-bash.ps1 は StandardInputEncoding を代入しない（PS 5.1 で存在しない）', () => {
  assert.doesNotMatch(guard, /\$psi\.StandardInputEncoding/,
    'StandardInputEncoding を触ると毎回「AI 判定の起動に失敗しました」になる');
});

test('guard-bash.ps1 は node.exe を優先し、stdin は UTF-8 バイトで渡す', () => {
  assert.match(guard, /\$c -match '\\.exe\$'/, 'node.exe を優先していない');
  assert.match(guard, /UTF8Encoding \$false/, 'BOM なし UTF-8 を使っていない');
  assert.match(guard, /StandardInput\.BaseStream\.Write/, 'stdin を BaseStream へ書いていない');
  assert.match(guard, /assist-error/, '起動失敗を監査に残していない');
});

test('Windows d-claude MCP 設定は ConvertTo-Json + UTF8 BOM で書かない', () => {
  assert.doesNotMatch(launch, /Set-Content -LiteralPath \$mcpCfgPath -Encoding UTF8/,
    'BOM 付き UTF8 で MCP JSON を書いてはいけない');
  assert.match(launch, /d-claude-mcp-write\.js/, 'node で JSON を書く経路が無い');
  assert.match(launch, /JSON\.stringify\(\{ mcpServers: servers \}\)/,
    '配列を保つ JSON.stringify が無い');
  assert.match(launch, /--none--/, 'PS 5.1 が空引数を省略するので番兵が必要');
  assert.match(launch, /gemini-vision/, 'vision MCP が登録されていない');
});

test('mac d-claude MCP writer は argv[1] を出力先にする（search-mcp 上書きの再発防止）', () => {
  assert.match(macLaunch, /fs\.writeFileSync\(process\.argv\[1\]/);
  assert.match(macLaunch, /process\.argv\[5\].*gemini-vision|servers\["gemini-vision"\].*process\.argv\[5\]/);
});

test('node -e のユーザ引数は argv[1] から始まる（現行 Node の契約）', () => {
  const r = spawnSync(process.execPath, ['-e', 'process.stdout.write(JSON.stringify(process.argv.slice(1)))', 'first', 'second'], {
    encoding: 'utf8',
  });
  assert.strictEqual(r.status, 0, r.stderr);
  const argv = JSON.parse(r.stdout);
  assert.strictEqual(argv[0], 'first', 'node -e の最初のユーザ引数が argv[1] でないと mac MCP 登録がずれる');
  assert.strictEqual(argv[1], 'second');
});

test('mac と同じ node -e MCP writer は vision を args 配列で書く', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp-write-'));
  const out = path.join(dir, 'mcp.json');
  const vision = path.join(dir, 'gemini-vision-mcp.js');
  fs.writeFileSync(vision, '');
  try {
    const r = spawnSync(process.execPath, [
      '-e',
      'const fs=require("fs"); const servers={};'
      + 'if(process.argv[2]) servers["gemini-search"]={command:"node",args:[process.argv[2]]};'
      + 'if(process.argv[3]) servers["pollinations-image"]={command:"node",args:[process.argv[3]]};'
      + 'if(process.argv[4]) servers["agy-image"]={command:"node",args:[process.argv[4]]};'
      + 'if(process.argv[5]) servers["gemini-vision"]={command:"node",args:[process.argv[5]]};'
      + 'if(process.argv[6]) servers["playwright"]={command:"node",args:[process.argv[6]]};'
      + 'if(process.argv[7]) servers["codex-image"]={command:"node",args:[process.argv[7]]};'
      + 'fs.writeFileSync(process.argv[1],JSON.stringify({mcpServers:servers}));',
      out, '', '', '', vision, '', '',
    ], { encoding: 'utf8' });
    assert.strictEqual(r.status, 0, r.stderr);
    const json = JSON.parse(fs.readFileSync(out, 'utf8'));
    assert.ok(json.mcpServers['gemini-vision'], 'vision が登録されていない');
    assert.deepStrictEqual(json.mcpServers['gemini-vision'].args, [vision]);
    assert.ok(!json.mcpServers['gemini-search'], '空文字の search まで登録してはいけない');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
