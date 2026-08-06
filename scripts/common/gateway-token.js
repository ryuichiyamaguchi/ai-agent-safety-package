// 送信検査 Gateway の「呼び出し元合言葉」を、同じ PC の複数ランチャー間で共有する。
//
// 経緯（なぜファイル共有にしたか）:
//   もとは起動のたびに乱数トークンを採番し、既に動いている gateway を必ず停止して
//   自分の gateway を立て直していた。この方式だと OpenCode を 2 枚開いたり、
//   OpenCode と d-claude を併用したりすると、後から起動した側が前の gateway を殺すため、
//   先に開いていた窓だけが古い合言葉を持ったまま取り残されて全リクエストが 401 になる
//   （"ds-gateway: unauthorized caller; not forwarded (fail-closed)"）。教室では
//   「作業中に急に止まって、開き直すと直る」という形で頻発した。
//
//   そこで合言葉を「起動ごとの値」から「この PC の秘密」に変え、実キー(auth)と同じ
//   ディレクトリ・同じ権限でファイルに保持する。gateway が何らかの理由で落ちて
//   立ち上がり直しても合言葉は変わらないので、開きっぱなしの窓もそのまま通り続ける。
//
// 防御としての強さ:
//   実キー(~/.deepseek-claude/auth)は元から同じ場所に平文ファイルで永続している。
//   合言葉はその実キーより価値が低い（gateway 経由でしか使えず、送信検査とマスクを必ず
//   通る）ので、置き場と権限を実キーに合わせても守りの強さは実質変わらない。
//   ファイルは 0600、ディレクトリは 0700。Windows は %USERPROFILE% 配下＝既定で本人のみ。
'use strict';
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');

const DEFAULT_TOKEN_FILE = process.env.DS_GATEWAY_TOKEN_FILE
  || path.join(os.homedir(), '.deepseek-claude', 'gateway-token');

function tokenFilePath(explicit) {
  const value = String(explicit || '').trim();
  return value || DEFAULT_TOKEN_FILE;
}

// gateway 本体の指紋。「今 listen している gateway が、これから使いたい ds-gateway.js と
// 同じ中身か」を判定するために使う。更新後に古い gateway が居座っていると、新しい検査
// ルールが効かないまま使われてしまうため、指紋が違うときだけ停止して立て直す。
function gatewayFingerprint(gatewayPath) {
  try {
    const buf = fs.readFileSync(gatewayPath);
    return crypto.createHash('sha256').update(buf).digest('hex').slice(0, 32);
  } catch (_) {
    return '';
  }
}

function isValidToken(value) {
  return typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
}

function readTokenFile(file) {
  try {
    const raw = fs.readFileSync(tokenFilePath(file), 'utf8');
    const json = JSON.parse(raw);
    if (!json || typeof json !== 'object') return null;
    if (!isValidToken(json.token)) return null;
    return json;
  } catch (_) {
    return null;
  }
}

function writeTokenFile(file, data) {
  const target = tokenFilePath(file);
  fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
  // 書きかけを他プロセスに読ませないよう、同じディレクトリに作ってから置き換える。
  const tmp = `${target}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(data)}\n`, { mode: 0o600 });
  try {
    fs.chmodSync(tmp, 0o600);
  } catch (_) { /* Windows では mode が効かない（%USERPROFILE% 配下なので既定で本人のみ） */ }
  fs.renameSync(tmp, target);
  return data;
}

// 合言葉を用意する。既にあればそれを使い、無い・壊れているときだけ新しく作る。
// 同時起動で二重に作られないよう、作成は「まだ無いときだけ書く」で入り、
// 負けた側は書かれた値を読み直す。
function ensureToken({ file, gatewayPath } = {}) {
  const target = tokenFilePath(file);
  const existing = readTokenFile(target);
  if (existing) return { token: existing.token, created: false, file: target };

  const token = crypto.randomBytes(32).toString('hex');
  const payload = {
    version: 1,
    token,
    gateway_fingerprint: gatewayPath ? gatewayFingerprint(gatewayPath) : '',
    created_at: new Date().toISOString(),
  };
  fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
  try {
    // wx = 既にあれば失敗。競争に負けたら相手の値を読む。
    fs.writeFileSync(target, `${JSON.stringify(payload)}\n`, { mode: 0o600, flag: 'wx' });
    try {
      fs.chmodSync(target, 0o600);
    } catch (_) { /* Windows */ }
    return { token, created: true, file: target };
  } catch (_) {
    const raced = readTokenFile(target);
    if (raced) return { token: raced.token, created: false, file: target };
    // 壊れたファイルが残っている場合はここで作り直す（読めない合言葉は誰も使えないため）。
    writeTokenFile(target, payload);
    return { token, created: true, file: target };
  }
}

// gateway が起動したときに、自分の素性（指紋・PID・ポート・起動時刻）を書き残す。
// 合言葉そのものは既存の値を保つ（ここで作り直すと開いている窓が 401 になる）。
function recordGatewayStart({ file, gatewayPath, port, pid } = {}) {
  const target = tokenFilePath(file);
  const ensured = ensureToken({ file: target, gatewayPath });
  const existing = readTokenFile(target) || {};
  const payload = {
    ...existing,
    version: 1,
    token: ensured.token,
    gateway_fingerprint: gatewayPath ? gatewayFingerprint(gatewayPath) : (existing.gateway_fingerprint || ''),
    pid: Number(pid || process.pid),
    port: Number(port || 0),
    started_at: new Date().toISOString(),
  };
  writeTokenFile(target, payload);
  return payload;
}

// 今 gateway が使っているポート。ランチャーはまずこれを見て「動いている gateway が
// 居ないか」を確かめる。既定ポート(8788)が別のプログラムに取られていると gateway は
// 別のポートで立ち上がるので、ポートを決め打ちで探すと再利用できなくなる。
function recordedPort({ file } = {}) {
  const info = readTokenFile(tokenFilePath(file));
  const port = info && Number(info.port);
  return Number.isInteger(port) && port > 0 ? port : 0;
}

function healthz(port, timeoutMs = 1000) {
  return new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port: Number(port), path: '/healthz', timeout: timeoutMs },
      (res) => {
        let body = '';
        res.on('data', (c) => { body += c; });
        res.on('end', () => resolve(res.statusCode === 200 && body.includes('"status":"ok"')));
      });
    req.on('timeout', () => { req.destroy(); resolve(false); });
    req.on('error', () => resolve(false));
  });
}

// 「今動いている gateway をそのまま使えるか」を判定する。
// 使える条件は 2 つだけ:
//   1. /healthz が応答する（= gateway が生きている）
//   2. 記録された指紋が、これから使いたい ds-gateway.js と一致する（= 中身が古くない）
// 指紋が違うときは再利用しない。古い検査ルールのまま使われるのを防ぐため、
// 呼び出し側（ランチャー）が停止してから立て直す。
async function probeReusable({ file, gatewayPath, port } = {}) {
  const target = tokenFilePath(file);
  const info = readTokenFile(target);
  if (!info) return { reusable: false, reason: 'no-token-file' };
  const alive = await healthz(port);
  if (!alive) return { reusable: false, reason: 'not-listening', token: info.token };
  const current = gatewayFingerprint(gatewayPath);
  if (!current) return { reusable: false, reason: 'gateway-unreadable', token: info.token };
  if (String(info.gateway_fingerprint || '') !== current) {
    return { reusable: false, reason: 'fingerprint-mismatch', token: info.token };
  }
  return { reusable: true, reason: 'ok', token: info.token };
}

module.exports = {
  DEFAULT_TOKEN_FILE,
  tokenFilePath,
  gatewayFingerprint,
  readTokenFile,
  writeTokenFile,
  ensureToken,
  recordGatewayStart,
  recordedPort,
  probeReusable,
  healthz,
};

// ------------------------------------------------------------------
// CLI: ランチャー（bash / PowerShell）から同じ判断を 1 行で呼べるようにする。
//   --ensure   … 合言葉を用意して標準出力に出す（無ければ作る）
//   --probe    … 動いている gateway を再利用できるなら合言葉を出して終了コード 0、
//                 できなければ終了コード 1（理由は標準エラーへ）
// 合言葉はコマンドライン引数には載せない（ps / タスクマネージャーに出るため）。
// 受け渡しは常に標準出力経由。
// ------------------------------------------------------------------
if (require.main === module) {
  const argv = process.argv.slice(2);
  const flag = (name) => {
    const i = argv.indexOf(name);
    return i === -1 ? '' : String(argv[i + 1] || '');
  };
  const gatewayPath = flag('--gateway') || path.join(__dirname, 'ds-gateway.js');
  const file = flag('--file');
  const port = flag('--port') || process.env.DS_GATEWAY_PORT || '8788';

  const run = async () => {
    if (argv.includes('--probe')) {
      const result = await probeReusable({ file, gatewayPath, port });
      if (!result.reusable) {
        process.stderr.write(`gateway-token: not reusable (${result.reason})\n`);
        process.exit(1);
      }
      process.stdout.write(result.token);
      process.exit(0);
    }
    if (argv.includes('--fingerprint')) {
      process.stdout.write(gatewayFingerprint(gatewayPath));
      process.exit(0);
    }
    if (argv.includes('--recorded-port')) {
      const p = recordedPort({ file });
      process.stdout.write(p ? String(p) : '');
      process.exit(0);
    }
    // 既定は --ensure
    const ensured = ensureToken({ file, gatewayPath });
    process.stdout.write(ensured.token);
    process.exit(0);
  };
  run().catch((e) => {
    process.stderr.write(`gateway-token: ${e && e.message ? e.message : e}\n`);
    process.exit(1);
  });
}
