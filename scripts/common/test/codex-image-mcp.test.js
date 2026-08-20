'use strict';
// GPT-Image-2（Codex 経由）の画像生成 MCP の回帰テスト。
//
// ここで守りたいこと:
//   1. OpenCode / d-claude の両ハーネスに載り、権限は必ず ask になる
//   2. AI_SAFE_DCLAUDE_CODEX_IMAGE=0 で個別に無効化できる
//   3. Claude 経路（launch-claude-safe は d-claude 限定の分岐）以外へは広げない
//   4. codex の呼び出しが「非対話・read-only サンドボックス・画像生成ツールを明示有効化」であること
//   5. 生成物の保存先が作業フォルダ（generated-images/）の中に必ず収まること
//   6. 画像生成は時間がかかるので timeout が十分に長いこと
//
// 実際に画像を生成する検証は課金を消費するのでここでは行わない（呼び出し形だけを固定する）。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.join(__dirname, '..', '..', '..');
const commonDir = path.join(root, 'scripts', 'common');
const { buildMcpConfig } = require(path.join(commonDir, 'opencode-config.js'));
const mcp = require(path.join(commonDir, 'codex-image-mcp.js'));

test('codex-image MCP は既定で local MCP として登録され、権限は ask になる', () => {
  const { mcp: servers, permission } = buildMcpConfig({ mcpDir: commonDir, env: {} });
  assert.ok(servers['codex-image'], 'codex-image が登録されていること');
  assert.strictEqual(servers['codex-image'].type, 'local');
  assert.deepStrictEqual(servers['codex-image'].command, ['node', path.join(commonDir, 'codex-image-mcp.js')]);
  assert.strictEqual(servers['codex-image'].enabled, true);
  // 実測で 1 枚 50 秒前後。既存の agy-image（210 秒）より余裕を持たせる。
  assert.ok(servers['codex-image'].timeout >= 210000, '画像生成に足りる timeout であること');
  assert.strictEqual(permission['codex-image_generate_image_gpt'], 'ask', '外部送信を伴うので ask であること');
});

test('AI_SAFE_DCLAUDE_CODEX_IMAGE=0 で無効化できる', () => {
  const { mcp: servers, permission } = buildMcpConfig({
    mcpDir: commonDir,
    env: { AI_SAFE_DCLAUDE_CODEX_IMAGE: '0' },
  });
  assert.ok(!servers['codex-image'], '無効化フラグが効くこと');
  assert.ok(!permission['codex-image_generate_image_gpt'], '権限も登録されないこと');
});

test('鍵は要らない（Gemini のコーチ用キーが無くても登録される）', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-img-home-'));
  try {
    const { mcp: servers } = buildMcpConfig({ mcpDir: commonDir, env: {}, homeDir: home });
    assert.ok(servers['codex-image'], 'ChatGPT のサブスクリプションで動くので API キー不要');
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test('d-claude ハーネス（mac / Windows）の両方に載っていて、Claude 経路には載っていない', () => {
  const mac = fs.readFileSync(path.join(root, 'scripts', 'macos', 'launch-claude-safe.sh'), 'utf8');
  const win = fs.readFileSync(path.join(root, 'scripts', 'windows', 'launch-claude-safe.ps1'), 'utf8');
  for (const [name, body] of [['mac', mac], ['windows', win]]) {
    assert.ok(body.includes('codex-image-mcp.js'), `${name}: 実体が参照されていない`);
    assert.ok(body.includes('AI_SAFE_DCLAUDE_CODEX_IMAGE'), `${name}: 無効化フラグが無い`);
    assert.ok(body.includes('"codex-image"'), `${name}: MCP サーバー名が登録されていない`);
  }
  // d-claude 専用の分岐（DS_CLAUDE_MODE / DeepSeek 経路）の中だけに置く。
  // 素の Claude Code（claude-safe）は Anthropic 純正のツールを持つので、ここは増やさない。
  assert.ok(mac.indexOf('DS_CLAUDE_MODE') < mac.indexOf('codex-image-mcp.js'),
    'mac: d-claude 限定の分岐より後ろに置くこと');
});

test('codex の呼び出しは非対話・read-only・画像生成ツール明示有効化', () => {
  const args = mcp.codexArgs('テストのプロンプト', '/tmp/ws');
  assert.strictEqual(args[0], 'exec', '対話 TUI ではなく非対話の単発実行');
  assert.ok(args.includes('--enable') && args.includes('image_generation'),
    '受講者の設定に依存せず画像生成ツールを有効化する');
  const sandboxAt = args.indexOf('-s');
  assert.ok(sandboxAt !== -1 && args[sandboxAt + 1] === 'read-only',
    'モデルが動かすシェルには一切書かせない');
  assert.ok(args.includes('--skip-git-repo-check'), 'git 管理下でない作業フォルダでも動くこと');
  const cdAt = args.indexOf('-C');
  assert.ok(cdAt !== -1 && args[cdAt + 1] === '/tmp/ws', '作業フォルダを固定すること');
  assert.strictEqual(args[args.length - 1], 'テストのプロンプト', 'プロンプトは引数の最後に 1 個');
  // `--dangerously-bypass-approvals-and-sandbox` のような壁を外す引数は絶対に混ぜない。
  assert.ok(!args.some((a) => /dangerous/i.test(a)), '壁を外す引数を渡していないこと');
});

test('保存先は作業フォルダの中に必ず収まる（.. や絶対パスを渡されても外へ書かない）', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-img-out-'));
  try {
    const ok = mcp.resolveDest(dir, 'poster', '.png');
    assert.strictEqual(path.dirname(ok), fs.realpathSync(dir) === dir ? dir : path.resolve(dir));
    for (const evil of ['../../etc/passwd', '/etc/passwd', '..', './../x', 'a/../../b']) {
      const dest = mcp.resolveDest(dir, evil, '.png');
      const rel = path.relative(path.resolve(dir), dest);
      assert.ok(rel && !rel.startsWith('..') && !path.isAbsolute(rel),
        `作業フォルダの外に出た: ${evil} -> ${dest}`);
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('prompt が空なら課金する前に断る', async () => {
  const r = await mcp.generate({ prompt: '   ' });
  assert.strictEqual(r.ok, false);
  assert.match(r.message, /prompt が空/);
});

test('ツール定義は名前・必須引数・外部送信の注意を持つ', () => {
  assert.strictEqual(mcp.TOOL.name, 'generate_image_gpt');
  assert.deepStrictEqual(mcp.TOOL.inputSchema.required, ['prompt']);
  assert.match(mcp.TOOL.description, /OpenAI/, 'どこへ送られるかを AI 向けの説明にも書く');
});
