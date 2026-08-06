'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..', '..');

function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}

test('macOS OpenCode launcher enforces config after project config and requires gateway health', () => {
  const script = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  assert.match(script, /OPENCODE_CONFIG_CONTENT/);
  assert.match(script, /OPENCODE_DISABLE_PROJECT_CONFIG/);
  assert.match(script, /OPENCODE_PURE/);
  assert.match(script, /opencode-config\.js/);
  assert.match(script, /DS_GATEWAY_AUTH_FILE/);
  assert.match(script, /api\.deepseek\.com/);
  assert.match(script, /\/healthz/);
  assert.match(script, /1\.14\.24/);
  assert.match(script, /unset OPENCODE_ENABLE_EXA/);
  assert.match(script, /AI_SAFE_DRY_RUN/);
});

test('Windows OpenCode launcher provides the same fail-closed controls', () => {
  const script = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');
  assert.match(script, /OPENCODE_CONFIG_CONTENT/);
  assert.match(script, /OPENCODE_DISABLE_PROJECT_CONFIG/);
  assert.match(script, /OPENCODE_PURE/);
  assert.match(script, /opencode-config\.js/);
  assert.match(script, /DS_GATEWAY_AUTH_FILE/);
  assert.match(script, /api\.deepseek\.com/);
  assert.match(script, /\/healthz/);
  assert.match(script, /1\.14\.24/);
  assert.match(script, /OPENCODE_ENABLE_EXA/);
  assert.match(script, /AI_SAFE_DRY_RUN/);
});

// OpenCode 統合ランチャーは OPENCODE_DISABLE_PROJECT_CONFIG=1 で起動するため、
// プロジェクトの .opencode/ はスキャンされない（プローブスキルで実測）。スキルの配布先は
// .ai-safety/dist-skills →（起動時に）$XDG_CONFIG_HOME/opencode/skills/ へ一本化した。
test('Mac and Windows installers place Bouncer and the OpenCode skill source', () => {
  const mac = read('scripts/macos/install.sh');
  const win = read('scripts/windows/install.ps1');

  assert.match(mac, /bouncer-gateway/);
  assert.match(mac, /\.ai-safety\/dist-skills/);
  assert.match(mac, /AGENTS\.md/);
  assert.match(win, /bouncer-gateway/);
  assert.match(win, /\.ai-safety\\dist-skills/);
  assert.match(win, /AGENTS\.md/);
});

// --- 回帰: 環境変数で強制設定を丸ごと無効化される穴 ------------------------------
// OPENCODE_PERMISSION / OPENCODE_TEST_MANAGED_CONFIG_DIR は OPENCODE_CONFIG_CONTENT より
// 後にマージされるため、消したうえで安全な値を入れ直すところまでやらないと塞がらない。
test('both launchers strip the environment variables that can disable the forced config', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  assert.match(mac, /unset OPENCODE_PERMISSION OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_TEST_MANAGED_CONFIG_DIR/);
  assert.match(win, /Remove-Item Env:\\OPENCODE_PERMISSION, Env:\\OPENCODE_CONFIG, Env:\\OPENCODE_CONFIG_DIR, Env:\\OPENCODE_TEST_MANAGED_CONFIG_DIR/);
});

test('both launchers re-assert the deny floor through OPENCODE_PERMISSION', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  assert.match(mac, /--print-permission-env/);
  assert.match(mac, /export OPENCODE_PERMISSION/);
  assert.match(win, /--print-permission-env/);
  assert.match(win, /\$env:OPENCODE_PERMISSION = \$enforced/);
});

// --- 配線が消えていないことの確認 ------------------------------------------------
// 以下はソース上の配線しか見ていない（「本体が起動しないこと」の実動作検証は
// opencode-launcher-runtime.test.js が偽 opencode を使って行う）。
test('both launchers keep the syntax check on the safety plugin wired up', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  assert.match(mac, /node --check "\$MONITOR_PLUGIN"/);
  assert.match(mac, /fail-closed/);
  assert.match(win, /--check \$monitorPlugin/);
  assert.match(win, /fail-closed/);
});

test('both launchers keep the resolved-config check, the ready gate and the watchdog wired up', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  for (const script of [mac, win]) {
    assert.match(script, /debug config/);
    assert.match(script, /--verify-resolved/);
    // 本体を出す前の同期確認（プラグインが実際に載ったか）。
    assert.match(script, /--verify-ready/);
    assert.match(script, /BOUNCER_READY_OK/);
    assert.match(script, /--watchdog/);
    assert.match(script, /opencode-monitor-ready\.json/);
    // 秘密の環境変数とポリシー差し替え変数の消去。
    assert.match(script, /--print-secret-env/);
    assert.match(script, /AI_SAFE_POLICY/);
  }
});

test('both launchers preserve a redacted diagnostic when resolved config parsing fails', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  for (const script of [mac, win]) {
    assert.match(script, /opencode-resolved-config\.failed\.txt/);
    assert.match(script, /REDACTED/);
    assert.match(script, /診断ファイル/);
  }
});

// 「毎回消して置き直す」方式が消すファイル名の一覧。opencode 1.18.4 は設定ディレクトリ直下の
// config.json も設定として読む（実機確認）ので、ここに任意のプラグインや MCP を書かれると
// 起動時に実行される。opencode.json5 / .opencoderc / config.jsonc は読まないので対象外。
test('both launchers wipe config.json as well as the opencode.json family', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  for (const name of ['AGENTS.md', 'opencode.json', 'opencode.jsonc', 'config.json']) {
    assert.ok(mac.includes(`"$OC_CONFIG_DIR/${name}"`), `mac のランチャーが ${name} を消していない`);
    assert.ok(win.includes(`'${name}'`), `Windows のランチャーが ${name} を消していない`);
  }
});

test('both launchers reject an empty generated config', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  assert.match(mac, /\[ -n "\$OPENCODE_CONFIG_CONTENT" \]/);
  assert.match(win, /-not \$env:OPENCODE_CONFIG_CONTENT/);
});

test('the Windows launcher reads the version defensively and cleans up its gateway port', () => {
  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');

  assert.doesNotMatch(win, /\| Select-Object -First 1\)\.Trim\(\)/, 'null に .Trim() を呼ぶと不親切な英語例外になる');
  assert.match(win, /\$null -eq \$versionRaw/);
  assert.match(win, /Remove-Item Env:\\OPENCODE_PERMISSION, Env:\\DS_GATEWAY_PORT/);
});

test('the macOS launcher keeps LF endings and the Windows launcher keeps UTF-8 BOM + CRLF', () => {
  const mac = fs.readFileSync(path.join(root, 'scripts/macos/opencode/launch-opencode-deepseek.sh'));
  const win = fs.readFileSync(path.join(root, 'scripts/windows/opencode/launch-opencode-deepseek.ps1'));

  assert.ok(!mac.includes('\r'), 'sh に CR が混ざっている');
  assert.deepStrictEqual([...win.subarray(0, 3)], [0xef, 0xbb, 0xbf], 'ps1 の UTF-8 BOM が失われている');
  const lf = [...win].filter((byte) => byte === 0x0a).length;
  const crlf = win.toString('binary').split('\r\n').length - 1;
  assert.strictEqual(lf, crlf, 'ps1 に CRLF でない改行が混ざっている');
});

test('legacy d-claude launchers remain present as an advanced compatibility route', () => {
  assert.ok(fs.existsSync(path.join(root, 'scripts/macos/deepseek/launch-deepseek-gateway.sh')));
  assert.ok(fs.existsSync(path.join(root, 'scripts/windows/deepseek/launch-deepseek-gateway.ps1')));
  assert.ok(fs.existsSync(path.join(root, 'workspace-template/d-claude.cmd')));
});

// ── 送信検査 Gateway の共用（複数の窓を同時に開けるようにする） ──────────────
// 以前は起動のたびに合言葉を採番し、動いている gateway を必ず停止して立て直していた。
// そのため OpenCode を 2 枚開く / d-claude と併用すると、先に開いていた窓だけが古い
// 合言葉のまま取り残されて全リクエストが 401 になっていた（教室で頻発）。
const GATEWAY_LAUNCHERS = [
  'scripts/macos/opencode/launch-opencode-deepseek.sh',
  'scripts/windows/opencode/launch-opencode-deepseek.ps1',
  'scripts/macos/deepseek/launch-deepseek-gateway.sh',
  'scripts/windows/deepseek/launch-deepseek-gateway.ps1',
];

for (const rel of GATEWAY_LAUNCHERS) {
  test(`${rel} は合言葉を共有ファイルから取り、使える gateway は立て直さない`, () => {
    const script = read(rel);
    assert.match(script, /gateway-token\.js/, '合言葉は共有ファイル経由で受け取ること');
    assert.match(script, /--ensure/, '合言葉が無ければ作る');
    assert.match(script, /--probe/, '動いている gateway を再利用できるか確かめる');
    // 起動ごとの採番（＝先に開いた窓を 401 にする原因）が残っていないこと。
    assert.ok(!/openssl rand -hex 32/.test(script), '起動ごとの合言葉採番は残さない');
    assert.ok(!/RandomNumberGenerator/.test(script), '起動ごとの合言葉採番は残さない');
  });
}

test('macOS ランチャーは共用中の gateway を自分の終了で巻き添えにしない', () => {
  for (const rel of ['scripts/macos/opencode/launch-opencode-deepseek.sh',
                     'scripts/macos/deepseek/launch-deepseek-gateway.sh']) {
    const script = read(rel);
    assert.match(script, /\[ -n "\$GW_PID" \] && kill "\$GW_PID"/,
      '自分で立てた gateway のときだけ停止すること');
    assert.match(script, /GATEWAY_REUSED/, '再利用しているかを持ち回ること');
    assert.match(script, /our_gateway_pid/, 'そのポートを握っているのが自分たちの gateway か確かめること');
  }
});

test('Windows ランチャーは共用中の gateway を自分の終了で巻き添えにしない', () => {
  for (const rel of ['scripts/windows/opencode/launch-opencode-deepseek.ps1',
                     'scripts/windows/deepseek/launch-deepseek-gateway.ps1']) {
    const script = read(rel);
    assert.match(script, /\$gw = \$null/, '再利用時は停止対象を持たないこと');
    assert.match(script, /Get-OurGatewayPid/, 'そのポートを握っているのが自分たちの gateway か確かめること');
    assert.match(script, /Test-GatewayReusable/, '再利用の可否を判定すること');
    assert.match(script, /if \(\$gw -and -not \$gw\.HasExited\)/, '自分で立てたときだけ停止すること');
  }
});

// ── 前回の続きから開く ────────────────────────────────────────────
// 401 などで窓が落ちても作業を引き継げるようにする。会話は OpenCode 自身が
// ローカルに保存しているので、--continue で戻れる。
test('OpenCode ランチャーは --resume を受けて opencode --continue を起動する', () => {
  const mac = read('scripts/macos/opencode/launch-opencode-deepseek.sh');
  assert.match(mac, /--resume\|--continue\)\s*RESUME="--continue"/, 'mac: --resume を受けること');
  assert.match(mac, /"\$OPENCODE_BIN" --continue/, 'mac: --continue で起動すること');

  const win = read('scripts/windows/opencode/launch-opencode-deepseek.ps1');
  assert.match(win, /\[switch\]\$Resume/, 'Windows: -Resume を受けること');
  assert.match(win, /& \$openCode '--continue'/, 'Windows: --continue で起動すること');
});

test('統合ランチャーは「続きから」を OpenCode へ渡す', () => {
  const mac = read('scripts/macos/launch-integrated.sh');
  assert.match(mac, /--websearch\|--resume\)/, 'mac: --resume を受け付けること');
  assert.match(mac, /launch-opencode-deepseek\.sh" "\$workspace" "\$extra" "\$extra2"/);

  const win = read('scripts/windows/launch-integrated.ps1');
  assert.match(win, /\[switch\]\$Resume/);
  assert.match(win, /-Resume:\$Resume/);
  assert.match(win, /-Resume は OpenCode だけで指定できます/);
});

test('起動メニューに「続きから」の番号がある（Mac / Windows とも）', () => {
  const command = read('workspace-template/スタート/0_Bouncer統合版を起動.command');
  assert.match(command, /8\) exec bash "\$LAUNCHER" "\$WORKSPACE" opencode standard --resume/);
  assert.match(command, /前回の続きから開く/);
  assert.match(command, /1〜8の番号/, '案内の番号範囲も更新すること');

  // .bat は教室 PC の PowerShell 5.1 が読めるよう CP932 で配布する（UTF-8 だと文字化けして即閉じ）。
  const batBytes = fs.readFileSync(path.join(root, 'workspace-template/スタート/0_Bouncer統合版を起動.bat'));
  assert.ok(batBytes[0] !== 0xef, '.bat に BOM を付けない');
  const bat = new TextDecoder('shift_jis').decode(batBytes);
  assert.match(bat, /choice \/c 12345678 \/n \/m "番号を選んでください \[1-8\]: "/);
  assert.match(bat, /if errorlevel 8 goto opencode_resume/);
  assert.match(bat, /:opencode_resume/);
  assert.match(bat, /-Agent opencode -Profile standard -Resume/);
  assert.match(bat, /前回の続きから開く/, 'CP932 のまま日本語が壊れていないこと');
});

// ── 既定ポートが他のプログラムに使われていても起動できる ──────────────────
// 8788 を別プロジェクトの常駐サービスが握っている PC が実在し、決め打ちのままだと
// gateway が bind できず「Gateway を確認できない」で起動そのものができなくなっていた。
test('4 本のランチャーは 8788 が塞がっていたら別のポートへ自動で移る', () => {
  for (const rel of GATEWAY_LAUNCHERS) {
    const script = read(rel);
    assert.match(script, /--recorded-port/, `${rel}: 動いている gateway のポートを記録から知ること`);
    assert.match(script, /8797/, `${rel}: 8788 から 8797 までを候補にすること`);
    assert.match(script, /DS_GATEWAY_PORT/, `${rel}: 明示指定があればそれを尊重すること`);
  }
});

test('ポートを 1 つも確保できないときは、原因が分かる日本語で止まる', () => {
  for (const rel of GATEWAY_LAUNCHERS) {
    const script = read(rel);
    assert.match(script, /他のプログラムが使っている可能性/,
      `${rel}: 「ポートが埋まっている」と分かる文言を出すこと`);
  }
  // OpenCode 側は gateway が出した生のメッセージ（EADDRINUSE 等）も画面に出す。
  assert.match(read('scripts/macos/opencode/launch-opencode-deepseek.sh'), /Gateway が出したメッセージ/);
  assert.match(read('scripts/windows/opencode/launch-opencode-deepseek.ps1'), /Gateway が出したメッセージ/);
});

test('既定以外のポートを使ったときは利用者に伝える', () => {
  for (const rel of GATEWAY_LAUNCHERS) {
    assert.match(read(rel), /8788 は他のプログラムが使っていたため/,
      `${rel}: 黙って別ポートへ逃げないこと`);
  }
});
