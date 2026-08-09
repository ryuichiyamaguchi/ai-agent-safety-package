'use strict';
// Buffer（SNS 予約投稿）を OpenCode から使えるようにするリモート MCP の回帰テスト。
//
// ここで守りたいこと:
//   1. 鍵が無ければ登録しない（鍵なしで登録すると毎回 401 を返すツールが並ぶ）
//   2. 登録するときは ask（SNS への投稿は取り消せないので、必ず確認を挟む）
//   3. 鍵は設定の Authorization ヘッダに入るので、診断ファイルへ書く前に伏せる
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.join(__dirname, '..', '..', '..');
const { buildMcpConfig } = require(path.join(root, 'scripts', 'common', 'opencode-config.js'));

function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}

function fakeHomeWith(files) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'buffer-mcp-'));
  fs.mkdirSync(path.join(home, '.ai-safety'), { recursive: true });
  for (const [name, body] of Object.entries(files)) {
    fs.writeFileSync(path.join(home, '.ai-safety', name), body);
  }
  return home;
}

test('Buffer は鍵が登録されていなければ MCP に載せない', (t) => {
  const home = fakeHomeWith({});
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const { mcp, permission } = buildMcpConfig({ mcpDir: path.join(root, 'scripts', 'common'), env: {}, homeDir: home });
  assert.ok(!mcp.buffer, '鍵が無いのに登録してはいけない');
  assert.ok(!permission['buffer_*'], '権限も出さないこと');
});

test('鍵があれば remote MCP として載り、権限は ask になる', (t) => {
  const home = fakeHomeWith({ 'buffer-api-key.txt': 'buffer-test-key-never-log\n' });
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const { mcp, permission } = buildMcpConfig({ mcpDir: path.join(root, 'scripts', 'common'), env: {}, homeDir: home });

  assert.ok(mcp.buffer, '鍵があれば登録すること');
  assert.strictEqual(mcp.buffer.type, 'remote');
  assert.strictEqual(mcp.buffer.url, 'https://mcp.buffer.com/mcp');
  assert.strictEqual(mcp.buffer.enabled, true);
  assert.strictEqual(mcp.buffer.oauth, false, '自動 OAuth でブラウザが開いて止まらないようにすること');
  assert.strictEqual(mcp.buffer.headers.Authorization, 'Bearer buffer-test-key-never-log',
    '前後の空白・改行を落として渡すこと');
  // SNS への投稿は取り消せない。既定の '*': 'ask' に頼らず設定にも明示する。
  assert.strictEqual(permission['buffer_*'], 'ask');
});

test('AI_SAFE_DCLAUDE_BUFFER=0 で無効にできる', (t) => {
  const home = fakeHomeWith({ 'buffer-api-key.txt': 'k' });
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const { mcp } = buildMcpConfig({
    mcpDir: path.join(root, 'scripts', 'common'),
    env: { AI_SAFE_DCLAUDE_BUFFER: '0' },
    homeDir: home,
  });
  assert.ok(!mcp.buffer, '無効化フラグが効くこと');
});

test('鍵は診断ファイルへ書く前に伏せる（両 OS）', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  assert.match(mac, /buffer-api-key\.txt/, 'mac: 鍵ファイルを読むこと');
  assert.match(mac, /resolved_safe="\$\{resolved_safe\/\/\$_remote_key\/REDACTED\}"/, 'mac: 伏せること');

  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');
  assert.match(win, /buffer-api-key\.txt/, 'Windows: 鍵ファイルを読むこと');
  assert.match(win, /\$resolvedSafe\.Replace\(\$remoteKey, 'REDACTED'\)/, 'Windows: 伏せること');
});

test('キー登録ボタンが両 OS にあり、取り消せない操作だと伝えている', () => {
  const cmd = read('workspace-template/スタート/（上級）11_Bufferのキーを登録.command');
  assert.match(cmd, /publish\.buffer\.com\/settings\/api/, '取得先を案内すること');
  assert.match(cmd, /buffer-api-key\.txt/, '保存先が鍵ファイルであること');
  assert.match(cmd, /chmod 600/, '本人だけが読める権限にすること');
  assert.match(cmd, /投稿は取り消せません/, '公開が不可逆であることを伝えること');

  const bat = fs.readFileSync(path.join(root, 'workspace-template/スタート/（上級）11_Bufferのキーを登録.bat'));
  assert.ok(bat[0] !== 0xef, '.bat に BOM を付けない');
  const text = new TextDecoder('shift_jis').decode(bat);
  assert.match(text, /chcp 932/, '教室 PC 向けに CP932 で動かすこと');
  assert.match(text, /buffer-api-key\.txt/);
  assert.match(text, /投稿は取り消せません/, 'CP932 のまま日本語が壊れていないこと');
});
