// =============================================================
// tri-engine-parity.test.js — 3 エンジン横断の判定一致テスト
//
// なぜこれがあるか（2026-07-28 の敵対的レビュー 2 巡目の総括）:
//   「パターンの集合を共有していても、それを適用するコードがエンジンごとに別実装で
//     ある限り同じ事故が繰り返します」
// 実際 1 巡目で mac だけ直した箇所が Windows と OpenCode に届いておらず、2 巡目で
// `echo evil> ~/.zshrc`（空白なしリダイレクト）が Windows / OpenCode だけ素通しである
// ことが実測された。個々のエンジンのテストをいくら足しても、この「片側だけ直っている」
// 型は見つからない。同じ入力を 3 エンジンに流して判定が割れていないことを見る。
//
// 構成:
//   tri-engine/cases.json        判定ケース表（SSOT・レビュアーの再現入力そのまま）
//   tri-engine/mac-verdicts.sh   本物の guard-bash.sh に流すランナー
//   tri-engine/win-verdicts.ps1  本物の guard-bash.ps1 に流すランナー
//   tri-engine/js-verdicts.mjs   本物の opencode-bouncer-monitor.mjs に流すランナー
// ランナーは判定ロジックを一切持たない（持つと「ガードを直したのにテストが古い判定を
// 見ている」空振りになる）。
//
// 実行: node --test scripts/common/test/tri-engine-parity.test.js
// 出荷前: scripts/release-version-check.sh が呼ぶ（不一致は release blocker）
// =============================================================
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const HERE = __dirname;
const REPO = path.resolve(HERE, '..', '..', '..');
const TRI = path.join(HERE, 'tri-engine');
const CASES_FILE = path.join(TRI, 'cases.json');

const VERDICTS = new Set(['block', 'ask', 'pass']);

function loadCases() {
  const cases = JSON.parse(fs.readFileSync(CASES_FILE, 'utf8')).cases;
  assert.ok(Array.isArray(cases) && cases.length > 0, 'cases.json が空です');
  return cases;
}

// ランナーの出力 "<id>\t<verdict>" を id -> verdict のマップにする。
function parseVerdicts(stdout, engine) {
  const map = new Map();
  for (const line of String(stdout).split('\n')) {
    if (!line.trim()) continue;
    const tab = line.indexOf('\t');
    assert.ok(tab > 0, `${engine} ランナーの出力が壊れています: ${line}`);
    map.set(line.slice(0, tab), line.slice(tab + 1).trim());
  }
  return map;
}

// ランナーは本物のガードを 64 回起動するので、混み合ったマシンでは分単位でかかる
// （実測: 平常時 mac 12 秒 / Windows 2 分。ロードアベレージ 50 超のときは 4 倍以上かかり、
// 15 分で足りずに落ちたことがある）。タイムアウトやプロセス起動の失敗を「判定が割れた」と
// 混同しないよう、ここで分けて投げる。混同すると、マシンが混んでいるだけで
// 「片側だけ直っている」と読める嘘の失敗が出て、テストそのものが信用されなくなる。
const RUNNER_TIMEOUT_MS = 30 * 60 * 1000;

function runEngine(engine, command, args) {
  let stdout;
  try {
    stdout = execFileSync(command, args, {
      cwd: REPO,
      encoding: 'utf8',
      maxBuffer: 8 * 1024 * 1024,
      timeout: RUNNER_TIMEOUT_MS,
    });
  } catch (error) {
    const why = (error.killed || error.signal)
      ? `${RUNNER_TIMEOUT_MS / 60000} 分以内に終わりませんでした（マシンが混んでいる可能性があります）`
      : `起動に失敗しました: ${error.message}`;
    throw new Error(
      `${engine} エンジンの判定を測定できませんでした。3 エンジンが一致しているかどうかは判定していません`
      + `（テスト環境の問題であって、パリティが壊れたという意味ではありません）。${why}`,
    );
  }
  return parseVerdicts(stdout, engine);
}

function hasPwsh() {
  try {
    execFileSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], {
      encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'ignore'],
    });
    return true;
  } catch {
    return false;
  }
}

// 期待値の解決。
//   expect            3 エンジン共通の期待値
//   engines[engine]   構造的な差（例: OpenCode の床には secretRegex 検査が無い）
//   knownGap.engines  まだ片側に修正が届いていない差。現状のまま固定し、
//                     直っても壊れてもここが FAIL する（直したら knownGap を消す）
function expectedFor(testCase, engine) {
  if (testCase.engines && testCase.engines[engine]) {
    return { verdict: testCase.engines[engine], kind: 'structural' };
  }
  if (testCase.knownGap && testCase.knownGap.engines && testCase.knownGap.engines[engine]) {
    return { verdict: testCase.knownGap.engines[engine], kind: 'knownGap' };
  }
  return { verdict: testCase.expect, kind: 'shared' };
}

// --- ケース表そのものの検査 ---------------------------------------------------
// 表が壊れていると以降の検査が丸ごと空振りするので、先に表を検査する。

test('ケース表: id が一意で、verdict の綴りが正しく、差分には必ず理由が付いている', () => {
  const cases = loadCases();
  const seen = new Set();
  for (const c of cases) {
    assert.ok(c.id, `id の無いケースがあります: ${JSON.stringify(c).slice(0, 120)}`);
    assert.ok(!seen.has(c.id), `id が重複しています: ${c.id}`);
    seen.add(c.id);
    assert.ok(typeof c.command === 'string' && c.command.length > 0, `${c.id}: command が空です`);
    assert.ok(VERDICTS.has(c.expect), `${c.id}: expect が不正です (${c.expect})`);
    assert.ok(c.why && c.why.length > 0, `${c.id}: why（なぜこのケースがあるか）が空です`);

    // 「3 エンジンで違ってよい」と書くときは必ず理由を添える。理由なしの上書きを
    // 許すと、事故をそのまま期待値に固定して検査が空振りする。
    if (c.engines) {
      assert.ok(c.why.length > 20, `${c.id}: engines で上書きするなら why に理由を書くこと`);
      for (const [engine, verdict] of Object.entries(c.engines)) {
        assert.ok(VERDICTS.has(verdict), `${c.id}: engines.${engine} が不正です (${verdict})`);
      }
    }
    if (c.knownGap) {
      assert.ok(c.knownGap.owner, `${c.id}: knownGap には owner（誰が閉じるか）が必要です`);
      assert.ok(c.knownGap.why && c.knownGap.why.length > 20,
        `${c.id}: knownGap には why（何が原因で、どう直せば閉じるか）が必要です`);
      for (const [engine, verdict] of Object.entries(c.knownGap.engines || {})) {
        assert.ok(VERDICTS.has(verdict), `${c.id}: knownGap.engines.${engine} が不正です (${verdict})`);
        assert.notStrictEqual(verdict, c.expect,
          `${c.id}: knownGap.engines.${engine} が expect と同じです（差が無いなら knownGap を消すこと）`);
      }
    }
  }
  assert.ok(cases.length >= 50, `ケース数が少なすぎます (${cases.length})`);
});

test('ケース表: レビューで床を破った入力が漏れなく載っている', () => {
  const commands = loadCases().map((c) => c.command);
  // 2 巡のレビューで実際に破られた形。ここから消すのは「もう守らない」と決めたときだけ。
  const required = [
    'echo evil> /Users/example/.zshrc',
    'echo evil>/Users/example/.zshrc',
    'echo evil2> /Users/example/.zshrc',
    'echo x > $PROFILE',
    'chmod -R 777 .',
    'ls\ncat /Users/example/project/.env',
  ];
  for (const command of required) {
    assert.ok(commands.includes(command), `レビューの再現入力が表から消えています: ${JSON.stringify(command)}`);
  }
});

// --- 3 エンジンの実測と突き合わせ ---------------------------------------------

// テスト全体の制限は 3 ランナー分の余裕を見る。ここが短いと、ランナー側の
// 「測定できませんでした」という正確な説明が出る前にテストが打ち切られてしまう。
test('3 エンジン（mac / Windows / OpenCode）が同じ入力に同じ判定を返す', { timeout: 95 * 60 * 1000 }, (t) => {
  const cases = loadCases();
  const engines = {
    mac: runEngine('mac', 'bash', [path.join(TRI, 'mac-verdicts.sh'), CASES_FILE]),
    js: runEngine('js', process.execPath, [path.join(TRI, 'js-verdicts.mjs'), CASES_FILE]),
  };
  if (hasPwsh()) {
    engines.win = runEngine('win', 'pwsh', ['-NoProfile', '-File', path.join(TRI, 'win-verdicts.ps1'), '-Cases', CASES_FILE]);
  } else {
    // pwsh が無い環境では Windows 側を測れない。出荷前チェック
    // （release-version-check.sh）は pwsh 必須にしてあるので、ここは開発時の逃げ道。
    t.diagnostic('pwsh が無いため Windows エンジンをスキップしました（出荷前チェックでは FAIL になります）');
  }

  const mismatches = [];
  const gapsStillOpen = [];
  const gapsClosed = [];

  for (const c of cases) {
    for (const [engine, verdicts] of Object.entries(engines)) {
      const actual = verdicts.get(c.id);
      assert.ok(actual !== undefined, `${engine} が ${c.id} の判定を返しませんでした`);
      // fatal = 床が読めない / 壊れている。block と取り違えないようランナーが分けている。
      assert.notStrictEqual(actual, 'fatal',
        `${engine}: ${c.id} で床が壊れています（ポリシーが読めないか、カナリアに当たらない）`);
      // timeout = そのケースだけ時間内に終わらなかった（マシン負荷）。判定ではない。
      assert.notStrictEqual(actual, 'timeout',
        `${engine}: ${c.id} が時間内に終わりませんでした。判定は取れていません（マシンが混んでいる可能性があります）`);

      const { verdict: expected, kind } = expectedFor(c, engine);
      if (actual === expected) {
        if (kind === 'knownGap') gapsStillOpen.push(`${c.id} / ${engine}: ${actual}（${c.knownGap.owner}）`);
        continue;
      }
      if (kind === 'knownGap') {
        gapsClosed.push(`${c.id} / ${engine}: knownGap は ${expected} と書いてあるが実測は ${actual}。`
          + `直ったなら cases.json の knownGap を消すこと`);
      } else {
        mismatches.push(`${c.id} / ${engine}: 期待 ${expected} / 実測 ${actual}`
          + `  command=${JSON.stringify(c.command)}  why=${c.why}`);
      }
    }
  }

  if (gapsStillOpen.length) {
    t.diagnostic(`未解消の 3 エンジン差 ${gapsStillOpen.length} 件（担当へ引き継ぎ中）:\n  `
      + gapsStillOpen.join('\n  '));
  }
  assert.deepStrictEqual(gapsClosed, [], `\n${gapsClosed.join('\n')}\n`);
  assert.deepStrictEqual(mismatches, [], `\n3 エンジンの判定が割れています:\n${mismatches.join('\n')}\n`);
});

// --- ランナーが本物のガードを見ていることの確認 -------------------------------
// ランナーが実装を写し取ってしまうと、ガードを直してもテストが古い判定を見続ける。
// 「ランナーは本物を起動しているだけ」であることを字面で固定する。

test('ランナーは判定ロジックを持たず、本物のガードを起動しているだけである', () => {
  const macRunner = fs.readFileSync(path.join(TRI, 'mac-verdicts.sh'), 'utf8');
  const winRunner = fs.readFileSync(path.join(TRI, 'win-verdicts.ps1'), 'utf8');
  const jsRunner = fs.readFileSync(path.join(TRI, 'js-verdicts.mjs'), 'utf8');

  assert.match(macRunner, /guard-bash\.sh/, 'mac ランナーが guard-bash.sh を起動していません');
  assert.match(winRunner, /guard-bash\.ps1/, 'Windows ランナーが guard-bash.ps1 を起動していません');
  assert.match(jsRunner, /opencode-bouncer-monitor\.mjs/, 'JS ランナーが本物のプラグインを読み込んでいません');

  // ランナー側でポリシーの正規表現を持ち出していないこと（持ち出した時点で別実装になる）。
  for (const [name, source] of [['mac', macRunner], ['win', winRunner], ['js', jsRunner]]) {
    assert.ok(!/dangerousCommandRegex|protectedPathRegex|redirectProtectedPathRegex/.test(source),
      `${name} ランナーがポリシーの規則を直接触っています（判定は本物のガードに任せること）`);
  }
});
