// js-verdicts.mjs — 3 エンジン横断テストの OpenCode(JS) 側ランナー
//
// cases.json の command を 1 件ずつ本物の opencode-bouncer-monitor.mjs の
// tool.execute.before フックに流し、
//   <id><TAB>block|pass
// を 1 行ずつ標準出力に出す。判定ロジックはここには一切書かない。
//
// OpenCode の床に ask 層は無いので verdict は block / pass の 2 値。
//
// 使い方: node js-verdicts.mjs [cases.json]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..', '..', '..');
const casesFile = process.argv[2] || path.join(here, 'cases.json');
const pluginUrl = pathToFileURL(path.join(repo, 'scripts', 'common', 'opencode-bouncer-monitor.mjs')).href;
const policyPath = path.join(repo, 'policy', 'safety-policy.json');

const cases = JSON.parse(fs.readFileSync(casesFile, 'utf8')).cases;
const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tri-js-'));
process.env.AI_SAFE_LOG_DIR = logDir;

try {
  const { BouncerApprovalMonitor } = await import(pluginUrl);
  // ポリシーの置き場は環境変数では差し替えられない（RED-3）ので candidates 引数で渡す。
  const hooks = await BouncerApprovalMonitor({
    directory: '/work/customer-project',
    candidates: [policyPath],
  });
  for (const c of cases) {
    let verdict = 'pass';
    try {
      await hooks['tool.execute.before'](
        { tool: 'bash', sessionID: 'tri', callID: 'tri' },
        { args: { command: c.command } },
      );
    } catch (error) {
      // 床が読めないときも throw するので、block と取り違えないよう分ける。
      verdict = /安全ルール（safety-policy.json）を読み込めない/.test(error.message) ? 'fatal' : 'block';
    }
    process.stdout.write(`${c.id}\t${verdict}\n`);
  }
} finally {
  fs.rmSync(logDir, { recursive: true, force: true });
}
