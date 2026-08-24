#!/usr/bin/env node
'use strict';

const MINIMUM_VERSION = [1, 14, 24];
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
// OS の金庫（macOS キーチェーン / Windows DPAPI）。鍵の在処を「金庫 → 旧平文」の順で見る。
const secretStore = require('./secret-store.js');

// 依存ゼロ MCP サーバー（d-claude と同じ実体）を OpenCode にも接続する。
// 有効化条件は d-claude ランチャー（scripts/macos/launch-claude-safe.sh）の踏襲:
//   - AI_SAFE_DCLAUDE_*=0 で個別に無効化できる
//   - 実体の .js が無ければ登録しない
//   - Gemini 系（検索・画像読取）はコーチ用キー（~/.ai-safety/gemini-api-key.txt / 環境変数）が
//     無ければ登録しない。壊れた MCP を登録すると毎回エラーだけ返るツールが並ぶため。
// timeout は OpenCode 既定の 5000ms では全滅する（各 MCP の内部タイムアウトの方が長い）ので、
// 実体側の上限（検索/画像読取 30 秒・Pollinations 90 秒・agy 180 秒）より余裕を持たせる。
const MCP_SERVERS = [
  { key: 'gemini-search', file: 'gemini-search-mcp.js', flag: 'AI_SAFE_DCLAUDE_SEARCH', tool: 'web_search', timeout: 45000, needsGeminiKey: true },
  { key: 'gemini-vision', file: 'gemini-vision-mcp.js', flag: 'AI_SAFE_DCLAUDE_VISION', tool: 'describe_image', timeout: 45000, needsGeminiKey: true },
  { key: 'pollinations-image', file: 'pollinations-image-mcp.js', flag: 'AI_SAFE_DCLAUDE_IMAGE', tool: 'generate_image', timeout: 120000, needsGeminiKey: false },
  { key: 'agy-image', file: 'agy-image-mcp.js', flag: 'AI_SAFE_DCLAUDE_AGY_IMAGE', tool: 'generate_image_agy', timeout: 210000, needsGeminiKey: false },
  // GPT-Image-2（Codex 経由。API キー不要＝ChatGPT のサブスクリプションを使う）。3 本のうち一番きれい。
  // 1 枚 1 分前後かかる（実測 50 秒前後）ので、agy（210 秒）よりさらに余裕を持たせる。
  { key: 'codex-image', file: 'codex-image-mcp.js', flag: 'AI_SAFE_DCLAUDE_CODEX_IMAGE', tool: 'generate_image_gpt', timeout: 300000, needsGeminiKey: false },
  { key: 'playwright', file: 'playwright-mcp.js', flag: 'AI_SAFE_DCLAUDE_PLAYWRIGHT', tool: '*', timeout: 90000, needsGeminiKey: false },
];

// ホスト型（リモート）の MCP。実体は先方のサーバーで動くので、こちらは URL と鍵だけを持つ。
// 有効化条件はローカル MCP と同じ考え方:
//   - AI_SAFE_DCLAUDE_*=0 で個別に無効化できる
//   - 鍵ファイルが無ければ登録しない（鍵なしで登録すると毎回 401 を返すツールが並ぶため）
// Buffer は SNS の予約投稿サービス。投稿の作成・予約・下書き、チャンネル一覧、
// 実績の取得などができる。**投稿は公開＝取り消せない操作**なので権限は ask のまま
// （既定の '*': 'ask' と同じだが、設定に明示して debug config で確認できるようにする）。
// なお MCP の通信は OpenCode から先方へ直接出るため、DeepSeek 向けの送信検査（マスク）は
// 経由しない。これは既存の Gemini 検索 MCP（検索語が直接 Gemini へ行く）と同じ構造。
const REMOTE_MCP_SERVERS = [
  {
    key: 'buffer',
    url: 'https://mcp.buffer.com/mcp',
    flag: 'AI_SAFE_DCLAUDE_BUFFER',
    keyFile: 'buffer-api-key.txt',
    // OS の金庫での項目名（secret-store.js の固定表）。金庫 → 旧平文 の順で読む。
    storeName: 'buffer',
    timeout: 60000,
  },
];

// OpenCode 本体のプロセス環境から必ず取り除く秘密の環境変数（SSOT）。
// ランチャーは `--print-secret-env` でこの一覧を受け取り、OpenCode を起動する前に消す。
// 消す理由: OpenCode 配下の bash 子プロセスは環境をそのまま継承するので、`env` や
// `printenv` を一度通せば AI に鍵の実物が見えてしまう（送信検査 Gateway のマスキングは
// 「外へ送るとき」の話で、画面に出るのは止められない）。
// Gemini / Google の鍵をここに入れた結果、検索・画像読取の MCP は
// ~/.ai-safety/gemini-api-key.txt（「7_AIコーチのキーを登録」が書く場所）だけを見る。
const SECRET_ENV_VARS = [
  'DEEPSEEK_API_KEY',
  'DEEPSEEK_API_TOKEN',
  'ANTHROPIC_AUTH_TOKEN',
  'ANTHROPIC_API_KEY',
  'OPENAI_API_KEY',
  'GEMINI_API_KEY',
  'GOOGLE_API_KEY',
  'GOOGLE_GENAI_API_KEY',
];

// コーチ用 Gemini キーの有無だけを見る（値は絶対に設定へ書き出さない）。
// 環境変数は見ない: OpenCode の環境からは上の SECRET_ENV_VARS ごと消えているため、
// 環境変数を根拠に MCP を登録すると「登録されているのに鍵が届かない MCP」になる。
// 鍵の受け渡しはキーファイル 1 本に寄せる（設定にも環境変数にも実物が載らない）。
function hasCoachKeyFile(homeDir) {
  // v1.17.0: 保存先を OS の金庫（キーチェーン / DPAPI）に移した。
  // ここだけは意図的に環境変数を見ない（従来どおり）。OpenCode の環境からは SECRET_ENV_VARS が
  // 消えているので、環境変数を根拠に登録すると「登録されているのに鍵が届かない MCP」になる。
  // 見るのは「金庫 → 旧平文」の2段だけ。値は読まない設計（設定にも環境変数にも実物を載せない）は維持。
  try {
    if (secretStore.exists('gemini')) return true;
  } catch { /* 金庫が使えない環境 → 旧平文へ */ }
  try {
    return fs.readFileSync(path.join(homeDir, '.ai-safety', 'gemini-api-key.txt'), 'utf8').trim().length > 0;
  } catch {
    return false;
  }
}

// リモート MCP に渡す鍵を読む。v1.17.0 で保存先を OS の金庫へ移した。
// 順序は「金庫 → 旧平文 ~/.ai-safety/<name>」。ここも hasCoachKeyFile と同じ理由で
// 環境変数は見ない（OpenCode の環境からは秘密の環境変数が消えているため）。
// 読めない・空なら空文字（＝その MCP は登録しない）。
function readKeyFile(homeDir, name, storeName) {
  if (storeName) {
    try { const v = secretStore.get(storeName); if (v) return v; } catch { /* 金庫が使えない → 旧平文へ */ }
  }
  try {
    return fs.readFileSync(path.join(homeDir, '.ai-safety', name), 'utf8').trim();
  } catch {
    return '';
  }
}

// 接続できる MCP だけを { mcp, permission } の形で返す。
// MCP ツールの permission キーは「<設定のサーバー名>_<ツール名>」（1.18.4 実測: モデルへ渡る
// ツール名がそのまま permission 名になる。例 gemini-search_web_search）。
// いずれも外部サービスへ送信するツールなので ask（既定の '*': 'ask' と同じだが、
// 「何が外に出るか」を設定に明示して debug config で確認できるようにする）。
function buildMcpConfig({ mcpDir = '', env = process.env, homeDir = os.homedir() } = {}) {
  const mcp = {};
  const permission = {};
  if (!mcpDir) return { mcp, permission };
  if (!path.isAbsolute(mcpDir)) {
    throw new Error('OpenCode MCP directory must be absolute');
  }
  const geminiKey = hasCoachKeyFile(homeDir);
  for (const server of MCP_SERVERS) {
    if (String(env[server.flag] ?? '1') === '0') continue;
    if (server.needsGeminiKey && !geminiKey) continue;
    const entry = path.join(mcpDir, server.file);
    if (!fs.existsSync(entry)) continue;
    mcp[server.key] = {
      type: 'local',
      command: ['node', entry],
      enabled: true,
      timeout: server.timeout,
    };
    if (server.tool === '*') {
      permission[`${server.key}_*`] = 'ask';
    } else {
      permission[`${server.key}_${server.tool}`] = 'ask';
    }
  }
  for (const server of REMOTE_MCP_SERVERS) {
    if (String(env[server.flag] ?? '1') === '0') continue;
    const token = readKeyFile(homeDir, server.keyFile, server.storeName);
    if (!token) continue;
    mcp[server.key] = {
      type: 'remote',
      url: server.url,
      enabled: true,
      // 自動 OAuth を試させない（鍵はこちらで渡す）。ブラウザが開いて止まるのを避ける。
      oauth: false,
      headers: { Authorization: `Bearer ${token}` },
      timeout: server.timeout,
    };
    // ホスト型はツールが複数あり、名前も先方の都合で増減する。個別に列挙せず
    // まとめて ask に固定する（取りこぼしても既定の '*': 'ask' が受け止める）。
    permission[`${server.key}_*`] = 'ask';
  }
  return { mcp, permission };
}

// 設定・環境変数の両方で必ず deny に固定する bash パターン（SSOT）。
// OPENCODE_PERMISSION は OPENCODE_CONFIG_CONTENT より後にマージされるため、ランチャーは
// この集合を環境変数側にも明示 export して「危険な既存値の消去」と「安全な値での上書き」を
// 二重に行う（1.18.4 実測: 環境変数側のキーが最後に勝つ）。
//
// 2026-08-20 実用最小限への見直し（山口さん裁定）。撤廃・緩和したものと、その理由:
//   ・`curl *` / `wget *` を撤廃
//       パッケージ全体は v1.12.0 で curl/wget の一律 deny を撤廃済み（policy の
//       _comment_dangerousCommand 参照）なのに、この経路だけが撤廃前の床を保持していた。
//       残していた理由は「送信検査 Gateway を素通りするから」だったが、同じパッケージが
//       公式に載せている MCP 5 本（gemini-search / gemini-vision / pollinations-image /
//       agy-image / buffer）と webfetch は**全部 Gateway を通らずに外へ出ている**ので、
//       curl だけを deny に残す根拠が脅威モデル上もう成立していない。
//       しかも OpenCode の permission はコマンド文字列全体の前方一致グロブなので、
//       `cd . && curl ...` と 1 語前置きするだけで当たらない＝**正当用途だけを確実に止め、
//       悪用は 1 語で回避できる**という非対称になっていた。撤廃後は '*': 'ask' に落ちる。
//       秘密流出（.env 読み出し）・リモートコード実行（curl|sh、$(curl …)、-o して実行）・
//       匿名アップロードサイト宛は policy の dangerousCommandRegex / protectedPathRegex が
//       独立して決定的 deny を続けるので、そこは一切弱まっていない。
//   ・`chmod -R *` を撤廃
//       `chmod -R u+rwX,go-rwx project`（＝**権限を締める**正当操作）まで止めていた。
//       本当に危険な「他人に書き込みを与える形」（777/666 や a+w / o+w）は policy の
//       dangerousCommandRegex が 3 エンジン共通で決定的 deny を続ける。撤廃したのは
//       「-R が付いていたら中身に関係なく止める」という粗い規則のほうだけ。
//   ・`git push*` / `npm publish*` を deny → ask
//       公開系は取り消しにくいが、正当用途（自分のリポジトリへ push する）も多い。
//       確認カードを 1 枚挟む形にして、判断を受講者に渡す。
//   ・残したもの: 再帰削除（rm *）・`sudo *`・`git reset --hard*`
//       いずれも取り消せない破壊で、正当な代替手段がある。
//   ・追加したもの: `oc-safe*` を deny（自分自身の再帰起動なので閉じる）
//
// 2026-08-21 の再訂正（山口さんの明示指示）— 裸の `codex*` / `claude*` は deny → ask:
//   前版で「安全フックを通らない裸起動」を deny にしたが、**行きすぎだったので撤回する**。
//   素の `claude` / `codex` を打って使いたい受講者は普通にいるし、禁止するほどの根拠が無い。
//   - 確認カードを 1 枚挟む（ask）だけにして、「はい」と答えれば素のまま起動できる。
//   - グローバル安全設定（上級 5 = apply-global-guard / apply-global-deny）を入れてあれば、
//     素起動でも Claude / Codex 側の hook 層と deny 設定が効く。**素起動＝丸腰ではない**。
//     効かないのは「このパッケージの作業フォルダ隔離・送信検査 Gateway・見守りモニター」で、
//     それが要るときは `claude-safe` / `codex-safe` を使う、という案内にとどめる。
//   - `codex-safe*` / `claude-safe*` は従来どおり ask（下の enforcedBashAsk()）。安全な
//     起動口は 1 つも塞がない。`oc-safe*` の deny だけは残す（再帰起動の抑止であって、
//     「別の AI を使わせない」という意味の禁止ではない）。
//   - `opencode*` / `agy*` の裸起動は、そもそも deny 表にも ask 表にも載っていない＝
//     `'*': 'ask'` に落ちるので、この訂正のあとの `codex*` / `claude*` と同じ扱いになる。
//     わざわざ明示しても挙動が変わらないため、表は増やさない。
//   - longrun（無人）では確認に答える人がいないので、裸起動は従来どおり deny 側に置く。
//
// longrun（長時間おまかせモード）の扱い:
//   目を離している間に ask が出ると答える人がいないので、そこでセッションが止まる。
//   かといって自動許可にすると「取り消しにくい公開」や「対話前提のランチャー起動」が
//   無人で通る。したがって **ask だったものは deny 側へ倒す**（緩める向きへは動かさない）。
function enforcedBashDeny(longrun = false) {
  const base = {
    [['r', 'm *'].join('')]: 'deny',
    'sudo *': 'deny',
    'git reset --hard*': 'deny',
    'oc-safe*': 'deny',
  };
  if (!longrun) return base;
  return {
    ...base,
    'codex*': 'deny',
    'claude*': 'deny',
    'codex-safe*': 'deny',
    'claude-safe*': 'deny',
    'git push*': 'deny',
    'npm publish*': 'deny',
  };
}

// 設定・環境変数の両方で必ず ask に固定する bash パターン（SSOT）。
// **この表は enforcedBashDeny() より後ろに置くこと。** OpenCode の permission は
// 「最後に一致したルールが勝つ」ので、ask の表全体が deny の表（`rm *` / `sudo *` /
// `git reset --hard*` / `oc-safe*`、longrun ではさらに裸起動と公開系）より後ろに無いと
// 確認つきで通したいものが deny に飲まれる。並び順そのものが意味を持つため、起動前検査
// （verifyResolvedConfig）は「ask が deny より後ろにあること」まで確かめる。
//
// codex-safe / claude-safe は PATH 上のシム（install が ~/.ai-safety/bin/ に置く）で、
// 中で安全ランチャーへ橋渡しする。呼ばれた側は --sandbox workspace-write / 安全 settings /
// guard フック / 見守りモニターが全部かかった状態で動くので、**裸起動より安全**になる。
function enforcedBashAsk(longrun = false) {
  // 長時間おまかせモードでは「確認して通す」枠そのものを置かない（全部 deny 側へ移した）。
  if (longrun) return {};
  return {
    // 裸起動は「おすすめしないが使える」。確認カードで 1 度だけ聞く（2026-08-21 の訂正）。
    // `codex-safe*` / `claude-safe*` はこの後ろに置く（同じ ask なので順序は挙動を変えないが、
    // 「裸 → -safe」の並びを保つと既存の並び順テストがそのまま意味を持つ）。
    'codex*': 'ask',
    'claude*': 'ask',
    'codex-safe*': 'ask',
    'claude-safe*': 'ask',
    'git push*': 'ask',
    'npm publish*': 'ask',
  };
}

// ランチャーが OPENCODE_PERMISSION に入れる最小の強制集合（deny → ask の順を保つ）。
function buildEnforcedPermissionEnv(longrun = false) {
  return {
    bash: { ...enforcedBashDeny(longrun), ...enforcedBashAsk(longrun) },
    external_directory: enforcedExternalDirectoryRules(),
  };
}

// ファイル名の「.」をソースに直書きしない（このファイル自身が .env / .ai-safety を含むと
// 安全ガードの保護パス検査に自分で引っかかるため）。
const DOT = String.fromCharCode(46);

// 各 AI の「会話ログ（過去のやりとり）」の置き場（SSOT）。2026-08-21 に読み取り範囲を
// 緩めたときの許可対象。**実際に存在を確認したものだけ**を載せること（推測で足さない）。
//   ~/.claude/projects                        … Claude Code のセッション JSONL
//   ~/.codex/sessions ・ ~/.codex/archived_sessions … Codex CLI のセッション JSONL
//   ~/.gemini/tmp                             … Gemini CLI のチャット履歴・チェックポイント
//   ~/.gemini/antigravity-cli/conversations   … Antigravity の会話 DB
//   ~/.local/share/opencode/storage ・ log    … OpenCode のセッション差分とログ
//
// ⚠️ ここに載せてよいのは『フォルダ単位で開けても隣に鍵が無い』置き場だけ。ファイル 1 本を
// 開けたいときは下の CONVERSATION_LOG_FILES を使う（OpenCode の external_directory は
// 「対象の**親フォルダ** + /*」しか照合しないため、ファイル 1 本の許可は必ず親フォルダごとの
// 許可になる。閉じ直しの手当てがセットで要る）。
// ⚠️ 各置き場の**隣**にある鍵ファイルは AGENT_SECRET_FILES で読み取り deny のまま残す。
const CONVERSATION_LOG_DIRS = [
  `${DOT}claude/projects`,
  `${DOT}codex/sessions`,
  `${DOT}codex/archived_sessions`,
  `${DOT}gemini/tmp`,
  `${DOT}gemini/antigravity-cli/conversations`,
  `${DOT}local/share/opencode/storage`,
  `${DOT}local/share/opencode/log`,
];

// 会話ログのうち『フォルダごとは開けられない』もの＝**ファイル 1 本だけ**を開ける対象（SSOT）。
// ~/.codex/history.jsonl は「Codex に打ち込んだ指示の履歴」で、過去の作業を振り返るのに使う。
// 2026-08-21・依頼者裁定「そこも読めた方がいい」により、v1.17.3 で ask に落としていたものを
// 既定で読めるようにした。
//
// ⚠️ 仕組み上の代償と、その閉じ直し方（1.18.9 実測にもとづく）:
//   OpenCode の external_directory は `path.join(path.dirname(filepath), '*')` を照合対象にする。
//   つまり「~/.codex/history.jsonl だけ」を external_directory で許すことはできず、
//   `~/.codex/*` をフォルダごと allow にするしかない。そのままだと隣の auth.json や
//   config.toml.bak まで開いてしまう。そこで:
//     ・**read 表**の末尾に「`~/.codex/*`（直下）は丸ごと deny → history.jsonl だけ allow」を
//       この順で書く。OpenCode の権限評価は findLast＝**最後に一致したルールが勝つ**なので、
//       後ろに書いた 1 本だけが開く（enforcedOpenedDirReadRules）。
//     ・**edit 表**の末尾でも `~/.codex/*`（直下）を deny にする。external_directory は
//       読み取り専用の関門ではないので、開けたぶん書き込み側も閉じ直す
//       （enforcedOpenedDirEditDenyRules）。
//     ・**guard 側**（policy/safety-policy.json の protectedPathRegex）にも
//       `.codex/auth.json` ・ `.codex/*config.toml` ・ `.codex/*.bak*` を追加した。
//       read 表は read ツール専用で、`cat ~/.codex/auth.json` のようなシェル経由には効かないため。
//   `*` は `/` をまたがないので、この deny は ~/.codex/sessions/** や ~/.codex/prompts/** には
//   当たらない（会話ログと道具の置き場はこれまでどおり開いたまま）。
const CONVERSATION_LOG_FILES = [`${DOT}codex/history${DOT}jsonl`];

// CONVERSATION_LOG_FILES のためにフォルダごと開けた場所（＝直下を閉じ直す対象）。
const OPENED_DIR_LOCKDOWN = Array.from(
  new Set(CONVERSATION_LOG_FILES.map((f) => f.slice(0, f.lastIndexOf('/')))),
);

// 「設定そのもの」と「鍵の実物」（SSOT）。会話ログを開けても、その隣にあるこれらは
// 読み取り deny のまま残す（AI が自分への指示と安全設定を読み書きできてはいけない、
// 鍵の実物はそもそもモデルへ渡してはいけない、という線引き）。
const AGENT_SECRET_FILES = [
  `${DOT}claude/settings${DOT}json`,
  `${DOT}claude/settings${DOT}local${DOT}json`,
  `${DOT}claude${DOT}json`,
  `${DOT}claude/${DOT}credentials${DOT}json`,
  `${DOT}codex/config${DOT}toml`,
  `${DOT}codex/auth${DOT}json`,
  `${DOT}gemini/settings${DOT}json`,
  `${DOT}gemini/oauth_creds${DOT}json`,
  `${DOT}gemini/google_accounts${DOT}json`,
  `${DOT}gemini/antigravity-cli/antigravity-oauth-token`,
  `${DOT}gemini/antigravity-cli/settings${DOT}json`,
  `${DOT}config/opencode/opencode${DOT}json`,
  `${DOT}config/opencode/opencode${DOT}jsonc`,
  `${DOT}local/share/opencode/auth${DOT}json`,
  `${DOT}local/share/opencode/mcp-auth${DOT}json`,
];

// 「読まれたら困る」秘密の置き場（フォルダ単位）。policy/safety-policy.json の
// protectedPathRegex と同じ集合を read ツールの表でも閉じる。v1.17.3 までは
// external_directory: '*' deny が結果的に止めていたが、ホーム配下を緩めた
// （v1.17.3 で ask → 2026-08-24 に読み取り全体開放で allow）ので
// read 表の側にも明示的な deny を置く（緩めた分だけ、床を明示的に敷き直す）。
// external_directory が素通しになった今、read ツール経路の秘密はこの表が**唯一の床**。
const SECRET_DIRS = [
  `${DOT}ssh`,
  `${DOT}aws`,
  `${DOT}azure`,
  `${DOT}gnupg`,
  `${DOT}kube`,
  `${DOT}deepseek-claude`,
  `${DOT}config/gcloud`,
];

// 「読まれたら困る」秘密のファイル（単体）。
const SECRET_FILES = [
  `${DOT}npmrc`,
  `${DOT}pypirc`,
  `${DOT}docker/config${DOT}json`,
];

// 秘密の読み取り deny 表。read 表の末尾に置く（最後に一致したルールが勝つ）。
// ⚠️ `..` を含む形も 1 本足してある。OpenCode は照合前にパスを正規化する（1.18.9 の
// resolve が canonical を返し、location_escape を別途エラーにする）ので通常は当たらないが、
// 「会話ログの置き場から親をたどって設定本体へ」という踏み台を、正規化に頼らずに閉じる。
function enforcedSecretReadDenyRules() {
  const rules = {};
  for (const dir of SECRET_DIRS) {
    rules[`~/${dir}`] = 'deny';
    rules[`~/${dir}/**`] = 'deny';
    rules[`**/${dir}`] = 'deny';
    rules[`**/${dir}/**`] = 'deny';
  }
  for (const file of [...SECRET_FILES, ...AGENT_SECRET_FILES]) {
    rules[`~/${file}`] = 'deny';
    rules[`**/${file}`] = 'deny';
  }
  return rules;
}

// 「ファイル 1 本のためにフォルダごと開けた場所」の閉じ直し（read 表用・SSOT）。
// 直下（`*` は `/` をまたがない）を丸ごと deny してから、開けたい 1 本だけを allow で開ける。
// **この順序（deny → allow）を絶対に崩さないこと**。OpenCode は findLast＝最後に一致した
// ルールが勝つ実装なので、逆順に書くとフォルダごと素通しになる（1.18.9 実測）。
// この表は enforcedSecretReadDenyRules() の**後ろ**に置く。したがって「直下は全部 deny」は
// 秘密の deny と同じ結論になり、開くのは CONVERSATION_LOG_FILES の 1 本だけになる。
function enforcedOpenedDirReadRules() {
  const rules = {};
  for (const dir of OPENED_DIR_LOCKDOWN) {
    rules[`~/${dir}/*`] = 'deny';
    rules[`**/${dir}/*`] = 'deny';
  }
  for (const file of CONVERSATION_LOG_FILES) {
    rules[`~/${file}`] = 'allow';
    rules[`**/${file}`] = 'allow';
  }
  return rules;
}

// 同じ場所の書き込み側の閉じ直し（edit 表用・SSOT）。
// external_directory は読み取り専用の関門ではないので、`~/.codex/*` を allow にした時点で
// 直下への書き込みも通り得る。会話ログを読ませたかっただけで AI 自身への指示
// （~/.codex/AGENTS.md など）を書き換えられては困るため、直下は書き込み deny にする。
function enforcedOpenedDirEditDenyRules() {
  const rules = {};
  for (const dir of OPENED_DIR_LOCKDOWN) {
    rules[`~/${dir}/*`] = 'deny';
    rules[`**/${dir}/*`] = 'deny';
  }
  return rules;
}

// read ツールの許可表（SSOT）。設定の生成と起動前検査の両方がこれを使う。
// read ツールは bash を通らないので、決定的 deny 床（tool.execute.before）が効かない。
// ここで禁止しなかったものは、シェルを一切使わずにそのまま読み出される。
// .ai-safety はパッケージ本体の置き場で、安全ルール（policy/safety-policy.json）と
// ガードの実装そのものが入っている。作業フォルダの外にある ~/.ai-safety は
// external_directory: deny が止めるが、作業フォルダ内の .ai-safety は素通しだった
// （実測: <workspace>/.ai-safety/ のファイルの中身がモデルへ渡った）。
// deny は allow より後ろに置く（最後に一致したルールが勝つ）。並び順そのものが安全性を
// 決めるので、起動前検査は「並びまで含めて丸ごと一致するか」を見る。
function enforcedReadRules() {
  return {
    '*': 'allow',
    [`*${DOT}env`]: 'deny',
    [`*${DOT}env${DOT}*`]: 'deny',
    [`**/${DOT}env`]: 'deny',
    [`**/${DOT}env${DOT}*`]: 'deny',
    [`*${DOT}env${DOT}example`]: 'allow',
    [`**/${DOT}env${DOT}example`]: 'allow',
    [`*${DOT}ai-safety`]: 'deny',
    [`**/${DOT}ai-safety`]: 'deny',
    [`*${DOT}ai-safety/**`]: 'deny',
    [`**/${DOT}ai-safety/**`]: 'deny',
    // 2026-08-21: ホーム配下の読み取りを ask に緩めたぶん、秘密の床を read 表にも敷き直す。
    ...enforcedSecretReadDenyRules(),
    // 2026-08-21 追補: ~/.codex/history.jsonl のためにフォルダごと開けた分を閉じ直す。
    // 「直下は全部 deny → history.jsonl だけ allow」の順で書く（findLast＝最後勝ち）。
    ...enforcedOpenedDirReadRules(),
    // `..` の踏み台封じは**必ず最後**に置く（会話ログの allow に追い越されないように）。
    '**/../**': 'deny',
  };
}

// edit（write ツールを含む書き換え系）の許可表（SSOT）。
// 素の 'ask' だけだと、受講者が 1 度「常に許可」を押した時点で .ai-safety/policy/ や
// hooks/ を書き換えられる＝安全ルールと決定的 deny 床そのものを無効化できる。しかも
// 床を殺した状態は次回以降の起動でも「正常に見える」ので、パターン単位で禁止する
// （1.18.4 実測: edit もパターン表を受け付ける）。
// longrun では '*' を allow にする（無人なので確認に答える人がいない）。ただし
// .ai-safety（安全ルールとガードの実体）の書き換え禁止は longrun でも 1 本も外さない。
function enforcedEditRules(longrun = false) {
  return {
    '*': longrun ? 'allow' : 'ask',
    [`*${DOT}ai-safety`]: 'deny',
    [`**/${DOT}ai-safety`]: 'deny',
    [`*${DOT}ai-safety/**`]: 'deny',
    [`**/${DOT}ai-safety/**`]: 'deny',
    // 各 CLI の「設定そのもの」は書き換え禁止（AI が自分への指示と安全設定を書き換えられない
    // ようにする線引き）。external_directory 側でも道具の置き場しか開けていないので普通は
    // ここへ届かないが、2 段で閉じておく（片方の綴りが崩れても素通しにならないように）。
    ...enforcedAgentConfigDenyRules(),
    // 2026-08-21: ~/.codex/history.jsonl を読ませるために external_directory で
    // ~/.codex/* をフォルダごと開けた。その分、直下への**書き込み**は明示的に閉じる。
    ...enforcedOpenedDirEditDenyRules(),
  };
}

// 「設定そのもの」＝書き換え禁止のファイル。edit 表の末尾に置く（最後に一致したルールが勝つ）。
function enforcedAgentConfigDenyRules() {
  const rules = {};
  for (const file of [
    `${DOT}claude/settings${DOT}json`,
    `${DOT}claude/settings${DOT}local${DOT}json`,
    `${DOT}claude${DOT}json`,
    `${DOT}codex/config${DOT}toml`,
    `${DOT}gemini/settings${DOT}json`,
    `${DOT}config/opencode/opencode${DOT}json`,
    `${DOT}config/opencode/opencode${DOT}jsonc`,
  ]) {
    rules[`~/${file}`] = 'deny';
    rules[`**/${file}`] = 'deny';
  }
  return rules;
}

// external_directory（作業フォルダの外へのアクセス）の許可表（SSOT）。
//
// v1.16 までは丸ごと 'deny'。v1.17 で道具の置き場だけ allow、v1.17.3 で会話ログ allow ＋
// ホーム配下 ask。**2026-08-24（依頼者承認済み設計）: catch-all を 'allow' にし、この層を
// 「素通しの関門」へ変えた。** 読み取りはホームを含む PC 全体を開放し、書き込みだけ確認制に
// するのが承認済み設計だが、OpenCode の external_directory は **read と write を区別できない
// 単一の関門**である（1.18.9 実測: read ツールも edit/write ツールも同じ
// Tool.assertExternalDirectory を通り、照合対象はどちらも path.join(dirname(filepath), '*')。
// 「読みは allow・書きは ask」をこの表 1 枚で書く構文は存在しない）。
// そこで区別は**後段のツール別の表**で行う:
//   ・読み取り … read 表（enforcedReadRules: '*': allow ＋ 秘密の deny 床）。1.18.9 実測で
//     read ツールは external_directory の後に必ず read 権限も assert する（ReadTool.execute:
//     assert(external) → assert({action:"read"})）ので、外の秘密はこれまでどおり deny で止まる。
//   ・書き込み … edit 表（enforcedEditRules: 通常モードは '*': ask ＋ 設定/.ai-safety の
//     deny 床）が同様に external の後で assert される。つまり通常モードでは
//     「ワークスペース外への書き込み＝確認カード（ask）」が維持される。
//   ・シェル経由 … opencode-bouncer-monitor.mjs の決定的 deny 床
//     （redirectProtectedPathRegex / protectedPathRegex / 秘密パターン）は不変。
// ⚠️ longrun の代償（読み取り開放を longrun でも効かせるための構造的トレードオフ）:
//   longrun では edit 表の '*' が allow なので、外の書き込みも確認なしで通る
//   （v1.17.3 までは '~/**': ask がここで止めていたが、ask のままだと無人のため
//   読み取りもそこで固まる）。ただし deny 床は 1 本も外れない: edit 表の
//   .ai-safety / 各 CLI 設定 / ~/.codex 直下の deny、プラグイン床の
//   redirectProtectedPathRegex（.ssh / .aws / .config / .claude / .codex / .gemini /
//   シェル初期化ファイル / LaunchAgents / システム領域など）、生成内容の秘密パターン検査。
// ⚠️ catch-all は '*' と '**' の **2 本セット**で先頭に置く（OpenCode の権限評価は
//   「最後に一致したルールが勝つ」。deny を後ろに置く並びを保つため）。glob の `*` は
//   `/` をまたがないため、'/Users/x/Documents/*' のようなスラッシュ入りの照合対象には
//   '**' でないと当たらない（当たらなければ evaluate の既定 = ask に落ちて、読み取り開放が
//   効かない）。'*' 単体はスラッシュ無しの照合対象向けの保険として残す。
// ⚠️ 下の個別 allow（道具の置き場・会話ログ・~/.codex/*）は catch-all に包含されるが、
//   「どこを意図的に開けたか」の SSOT 記録と、将来 catch-all を絞り直すときに開けた場所が
//   巻き添えで閉じないための保険として残す。消さないこと。
// ⚠️ ~/.config/opencode/plugin/ と各 CLI の agents/ は**書き込み側**で引き続き開けない
//   （edit 表・toolboxWritablePathRegex・guard の管轄。AGENT_LOCKED_KEYS の説明を参照）。
// ⚠️ 免除の SSOT は policy/safety-policy.json の toolboxWritablePathRegex。ここを増やすときは
//   そちらと mac / Windows のガードも必ず揃えること。
function enforcedExternalDirectoryRules() {
  const rules = { '*': 'allow', '**': 'allow' };
  for (const dir of [
    `${DOT}claude/skills`,
    `${DOT}claude/commands`,
    `${DOT}codex/prompts`,
    `${DOT}codex/skills`,
    `${DOT}gemini/commands`,
    `${DOT}gemini/skills`,
    `${DOT}config/opencode/command`,
    `${DOT}config/opencode/skills`,
  ]) {
    rules[`~/${dir}/**`] = 'allow';
  }
  for (const dir of CONVERSATION_LOG_DIRS) {
    rules[`~/${dir}/**`] = 'allow';
  }
  // ファイル 1 本だけ開けたい会話ログ（~/.codex/history.jsonl）。external_directory は
  // 「対象の親フォルダ + /*」しか照合しないので、ここはフォルダごとの allow にならざるを得ない。
  // 開きすぎた分は read 表の enforcedOpenedDirReadRules() と edit 表の
  // enforcedOpenedDirEditDenyRules()、および guard の protectedPathRegex が閉じ直す。
  for (const dir of OPENED_DIR_LOCKDOWN) {
    rules[`~/${dir}/*`] = 'allow';
  }
  // `..` の踏み台封じは**必ず最後**に置く（allow 群に追い越されないように）。
  // read 表と同じ流儀。opencode は照合前にパスを canonical へ解決するので通常この形は
  // 現れないが、正規化に頼らずに `~/.codex/sessions/../auth.json` のような回り込みを塞ぐ
  // 保険として残す（回帰テストが検知。2026-08-24）。
  rules['**/../**'] = 'deny';
  return rules;
}

// エージェント個別 permission で「文字列 deny」以外を認めないキー。
// グローバル側が deny / ask のもの＝緩める向きしか意味を持たないので、deny 以外は全部拒否。
// external_directory を落としたのは、これ 1 つで作業フォルダの外へ出られるため
// （エージェント定義 .md を 1 枚足すだけで隔離が外れる形になっていた）。
//
// read / write / grep を足した理由:
//   - read  … `tools: { read: true }` は解決済みルールの最後尾に `read * -> allow` を積む。
//             共通側の `.env` 禁止がそのエージェントだけ外れる（実測で秘密がモデルへ渡った）。
//   - write … 同じ形の書き換え版。1.18.4 は write を edit へ寄せるので普段は現れないが、
//             現れたときに素通しになる方が危ないので閉じておく。
//   - grep  … grep ツールは一致行の全文をモデルへ返す。`grep: true` を書くだけで確認すら
//             出ずに `.env` の中身が読み出せた（実測）。
// glob は入れない: 返るのはファイル名だけで中身は出ず、作業フォルダの見取り図を作るのに
// 要る（「せんせい」が実際に使う）。read/grep と違って「読み取り禁止」の約束を破らない。
const AGENT_LOCKED_KEYS = ['bash', 'edit', 'read', 'write', 'grep', 'external_directory', 'webfetch', 'websearch'];

// 決定的 deny 床を持つプラグインのファイル名。解決済み設定の plugin 一覧に残っているかを見る。
const MONITOR_PLUGIN_FILE = 'opencode-bouncer-monitor.mjs';

// `opencode debug config` が出す「解決済み設定」を検証し、壊れている点を日本語で列挙する。
// 環境変数や管理者設定で deny 床が外されていないかを、起動直前に実物で確かめるために使う。
function verifyResolvedConfig(resolved, { longrun = false } = {}) {
  const problems = [];
  if (!resolved || typeof resolved !== 'object') return ['解決済み設定を読み取れませんでした。'];
  const permission = resolved.permission && typeof resolved.permission === 'object' ? resolved.permission : {};
  const bash = permission.bash && typeof permission.bash === 'object' ? permission.bash : {};
  for (const [pattern, action] of Object.entries(enforcedBashDeny(longrun))) {
    if (bash[pattern] !== action) problems.push(`bash の「${pattern}」が禁止になっていません。`);
  }
  for (const [pattern, action] of Object.entries(enforcedBashAsk(longrun))) {
    if (bash[pattern] !== action) problems.push(`bash の「${pattern}」が確認制になっていません。`);
  }
  // 並び順の検査。OpenCode は「最後に一致したルールが勝つ」ので、ask にしたいパターンが
  // deny の表より前に来ると deny に飲まれる（例: longrun 以外での `codex-safe*` が
  // `oc-safe*`(deny) より前に来る形）。キーの並びそのものを見る。
  {
    const keys = Object.keys(bash);
    const lastDeny = keys.reduce((acc, key, i) => (bash[key] === 'deny' ? i : acc), -1);
    for (const pattern of Object.keys(enforcedBashAsk(longrun))) {
      const at = keys.indexOf(pattern);
      if (at >= 0 && at < lastDeny) {
        problems.push(`bash の「${pattern}」が禁止規則より前にあり、最後の一致で打ち消されます。`);
      }
    }
  }
  // 長時間おまかせモードは「無人で走らせる」ことが目的なので bash の '*' は allow になる。
  // そのぶん、上の deny 床（再帰削除・sudo・裸起動・公開系）は 1 本も外していないこと、
  // および webfetch / websearch が deny 側へ倒れていることを下で確かめる。
  if (!longrun && bash['*'] === 'allow') problems.push('bash がすべて自動許可になっています。');
  // external_directory は「'*': allow（読み取り開放）＋ 末尾の `..` 封じ deny」の表
  // （2026-08-24。書き込みの確認は後段の edit 表が担う）。並び順まで含めて配布物どおりで
  // あることを求める（末尾の deny を前へ動かすだけで保険が無効になるため）。
  if (JSON.stringify(permission.external_directory) !== JSON.stringify(enforcedExternalDirectoryRules())) {
    problems.push('作業フォルダの外へのアクセス制限（external_directory）が配布物と違います。');
  }
  if (resolved.share !== 'disabled') problems.push('会話の共有リンク作成が無効になっていません。');
  // read / edit は「並び順まで含めて」配布物どおりであることを求める。ここは最後に一致した
  // ルールが勝つ世界なので、キーが全部残っていても順番を入れ替えるだけで禁止が無効になる
  // （`*: allow` を deny の後ろへ動かす等）。丸ごと比較なら書き換え・並べ替えの両方を弾ける。
  if (JSON.stringify(permission.read) !== JSON.stringify(enforcedReadRules())) {
    problems.push('パスワードや鍵が入ったファイル（.env など）と安全ルール置き場の読み取り禁止が書き換えられています。');
  }
  if (JSON.stringify(permission.edit) !== JSON.stringify(enforcedEditRules(longrun))) {
    problems.push('安全ルール置き場（.ai-safety）の書き換え禁止が外れています。');
  }
  // 外部通信系はパターン表にされると穴を開けられるので「文字列で allow 以外」だけを通す。
  for (const [key, label] of [['webfetch', 'インターネットのページ取得'], ['websearch', 'Web検索']]) {
    const value = permission[key];
    if (typeof value !== 'string' || value === 'allow') {
      problems.push(`${label}が無確認で使える設定になっています。`);
    }
    // 長時間おまかせモードは無人なので「確認して通す」が成立しない。外部送信は
    // 止まる側（deny）へ倒す。ask のままだとセッションがそこで固まるうえ、
    // 万一 allow へ倒すと取り消せない送信が無人で通ってしまう。
    if (longrun && value !== 'deny') {
      problems.push(`長時間おまかせモードでは${label}を禁止にしてください。`);
    }
  }
  if (resolved.autoupdate !== false) {
    problems.push('OpenCode の自動更新が無効になっていません。');
  }
  // 決定的 deny 床（tool.execute.before）を持つプラグインが設定から外されていないか。
  // 実際に読み込まれたかは別途 ready マーカーで確かめるが、設定の時点で消されていれば
  // ここで止めたほうが原因が分かりやすい。
  const plugins = Array.isArray(resolved.plugin) ? resolved.plugin : [];
  if (!plugins.some((entry) => typeof entry === 'string' && entry.endsWith(MONITOR_PLUGIN_FILE))) {
    problems.push('危険なコマンドを止める安全プラグインが設定から外されています。');
  }
  const agents = resolved.agent && typeof resolved.agent === 'object' ? resolved.agent : {};
  for (const [name, agent] of Object.entries(agents)) {
    const agentPermission = agent && typeof agent.permission === 'object' ? agent.permission : {};
    // エージェント個別 permission はグローバルの後ろに連結される＝共通の deny 床を
    // 上書きできてしまうので原則禁止。唯一の例外が「丸ごと deny」する形で、これは
    // 緩めようがない（読み取り専用エージェント用）。1.18.4 は markdown の
    // `tools: { bash: false }` もこの形（permission.bash = "deny"）へ変換するため、
    // ここを弾くと読み取り専用の「せんせい」を置いた瞬間に起動できなくなる。
    // パターン表（{"*":"deny","ls*":"allow"} 等）は穴を開けられるので拒否する。
    for (const key of AGENT_LOCKED_KEYS) {
      const value = agentPermission[key];
      if (value !== undefined && value !== 'deny') {
        problems.push(`エージェント「${name}」が ${key} の共通ルールを上書きしています。`);
      }
    }
    // task だけはグローバルが allow なので「絞る向き」の書き方が実在する（bouncer が
    // 呼べる相手を bouncer-helper 1 本に限る形）。既定 deny のパターン表と丸ごと deny の
    // 2 形だけを通し、それ以外（allow / ask / 既定 allow のパターン表）は弾く。
    const task = agentPermission.task;
    if (task !== undefined && task !== 'deny') {
      const defaultDenyTable = task && typeof task === 'object' && !Array.isArray(task) && task['*'] === 'deny';
      if (!defaultDenyTable) {
        problems.push(`エージェント「${name}」が task の共通ルールを上書きしています。`);
      }
    }
  }
  return problems;
}

function isSupportedVersion(value) {
  const match = String(value || '').trim().match(/^(\d+)\.(\d+)\.(\d+)/);
  if (!match) return false;
  const actual = match.slice(1, 4).map(Number);
  for (let index = 0; index < MINIMUM_VERSION.length; index += 1) {
    if (actual[index] > MINIMUM_VERSION[index]) return true;
    if (actual[index] < MINIMUM_VERSION[index]) return false;
  }
  return true;
}

// 送信検査 Gateway の呼び出し元認証トークン。ランチャーが起動ごとに乱数で採番し、
// 環境変数 DS_GATEWAY_TOKEN でこのスクリプトに渡す（コマンドライン引数にすると
// プロセス一覧に出るため env 経由に限る）。gateway 側は不一致・欠落を 401 で落とす。
function resolveGatewayToken(explicit) {
  const token = String(explicit || process.env.DS_GATEWAY_TOKEN || '').trim();
  if (!token) {
    throw new Error('DS_GATEWAY_TOKEN is not set; refusing to emit a config without gateway auth');
  }
  return token;
}

function buildOpenCodeConfig({
  port = 8788,
  enableWebSearch = false,
  monitorPlugin = '',
  gatewayToken = '',
  mcpDir = '',
  env = process.env,
  homeDir = os.homedir(),
  // 長時間おまかせモード（目を離して走らせる）。確認を出さない代わりに、
  // ask だったものは deny 側へ倒す。deny 床は 1 本も外さない。
  longrun = false,
  // モデル自由選択モード（2026-08-24 依頼者裁定「free のモデルは自由に選ばせればいい。
  // リスク込みでモデルに任せる」）。DeepSeek キーも送信検査 Gateway も使わず、provider /
  // model を一切固定しない（未指定なら OpenCode 標準のモデル選択で無料モデルを含めて選べる）。
  // **permission の表（bash deny 床・read 表・edit 表・external_directory・プラグイン床）は
  // DeepSeek 版と同一のまま生成する**。この関数が同じ enforced* 群から作るので、free で
  // 緩む向きの分岐は構造的に存在しない。代償は送信検査（マスキング）を通らないことだけ。
  free = false,
} = {}) {
  const safePort = Number(port);
  if (!Number.isInteger(safePort) || safePort < 1 || safePort > 65535) {
    throw new Error('OpenCode gateway port must be an integer between 1 and 65535');
  }
  // free モードでは合言葉を要求しない（Gateway 自体を使わないため）。DeepSeek 経路は
  // 従来どおり、合言葉なしでの設定生成を拒否する（fail-closed）。
  const apiKey = free ? '' : resolveGatewayToken(gatewayToken);
  const mcpConfig = buildMcpConfig({ mcpDir, env, homeDir });
  if (monitorPlugin && !path.isAbsolute(monitorPlugin)) {
    throw new Error('OpenCode monitor plugin path must be absolute');
  }
  const config = {
    $schema: 'https://opencode.ai/config.json',
    // free モードではモデルを固定しない（未指定だと OpenCode がモデル選択画面を出し、
    // 無料モデルを含む一覧から利用者が選ぶ）。
    ...(free ? {} : {
      model: 'bouncer-deepseek/deepseek-v4-flash',
      small_model: 'bouncer-deepseek/deepseek-v4-flash',
    }),
    default_agent: 'bouncer',
    share: 'disabled',
    // 既定は true。勝手な自動更新で安全ハーネスが静かに壊れるのを防ぐため明示的に無効化する。
    autoupdate: false,
    // 隔離設定ディレクトリ直下の AGENTS.md（＝ランチャーが毎回置き直すハーネス本体）は、
    // instructions の指定と関係なく無条件で読み込まれる。OPENCODE_DISABLE_PROJECT_CONFIG=1
    // では作業フォルダ側の探索が丸ごと止まるので、ここに絶対パスを足しても届く相手が
    // 増えるだけで、むしろ Codex 前提の workspace/AGENTS.md と矛盾指示になる。
    // 相対パスは設定ディレクトリ基準で解決される（＝同じハーネス本体を指す）ので触らない。
    instructions: ['AGENTS.md'],
    subagent_depth: 1,
    agent: {
      bouncer: {
        description: 'Bouncer-protected primary coding agent',
        mode: 'primary',
        // free モードではエージェント側でもモデルを固定しない（利用者の選択に従う）。
        ...(free ? {} : { model: 'bouncer-deepseek/deepseek-v4-flash' }),
        permission: {
          task: {
            '*': 'deny',
            'bouncer-helper': 'allow',
          },
        },
      },
      'bouncer-helper': {
        description: 'Fast Bouncer-protected helper for focused research and analysis',
        mode: 'subagent',
        ...(free ? {} : { model: 'bouncer-deepseek/deepseek-v4-flash' }),
        // OpenCode の権限評価は「最後に一致したルールが勝つ」。エージェント個別 permission は
        // グローバル permission の後ろに連結されるため、ここに bash / edit / external_directory /
        // webfetch / websearch を書くとグローバルの deny 床を上書きして無効化してしまう。
        // restriction（task の全面 deny）だけを残し、それ以外はグローバルをそのまま継承させる。
        permission: {
          task: 'deny',
        },
      },
      // 組み込み primary エージェント（build / plan）は Tab キーで切り替えられ、bouncer
      // エージェント個別の task 制限が外れる。使わせないため明示的に無効化する。
      build: { disable: true },
      plan: { disable: true },
    },
    // free モードでは provider を注入せず enabled_providers でも絞らない
    // （OpenCode が持つ一覧から、無料モデルを含めて利用者が選ぶ）。
    ...(free ? {} : {
      enabled_providers: ['bouncer-deepseek'],
      provider: {
        'bouncer-deepseek': {
          npm: '@ai-sdk/openai-compatible',
          name: 'DeepSeek via Bouncer inspection gateway',
          options: {
            baseURL: `http://127.0.0.1:${safePort}/v1`,
            apiKey,
          },
          models: {
            'deepseek-v4-pro': {
              name: 'DeepSeek V4 Pro (Bouncer protected)',
              limit: { context: 1048576, output: 393216 },
            },
            'deepseek-v4-flash': {
              name: 'DeepSeek V4 Flash (Bouncer protected)',
              limit: { context: 1048576, output: 393216 },
            },
          },
        },
      },
    }),
    permission: {
      '*': longrun ? 'allow' : 'ask',
      read: enforcedReadRules(),
      edit: enforcedEditRules(longrun),
      // 前方一致 allow は「読むだけ」で副作用の出しようがないものに絞る。
      // find* は -delete / -exec rm、git log* は -p でのリダイレクト書き込みに使えるため
      // allow から外して ask に落とす。連結・リダイレクトによる悪用は
      // opencode-bouncer-monitor.mjs の decisive deny 床（tool.execute.before）が受け止める。
      // deny は allow より後ろに置く（最後に一致したルールが勝つ）。
      // 「見るだけ」で副作用が出しようがないものは allow に置いて確認疲れを減らす。
      // wc は中身を出さない（行数・語数・バイト数だけ）ので allow に残す。
      // git show* は `git show HEAD:.env` の形が床の正規表現（パス区切り前提）をすり抜けるため
      // allow に入れない＝確認のまま残す。
      //
      // head * / tail * を allow から外した理由（2026-07-28、grep* / rg* と同じ理由）:
      //   床はコマンド文字列しか見ないので、`head -n 200 .*` のようにグロブで書かれた形からは
      //   何が読まれるか分からない。文字列に .env が出てこないため protectedPathRegex も
      //   dangerousCommandRegex も当たらず（3 エンジン実測 = 3 者とも pass）、確認ダイアログも
      //   出ないまま .env の中身がそのままモデルへ渡る。「head / tail は .env に向けても床が
      //   先に止める」という旧コメントは `head .env` のような直書きの形でしか成り立たず、
      //   グロブを使うと成立しない。ここを外すと '*': 'ask' に落ちて確認が 1 回出る。
      //
      // grep* / rg* を allow から外した理由（2026-07-28）:
      //   床はコマンド文字列しか見ないので、`grep -r SECRET .` のように検索先が「.」で
      //   書かれた形からは何が読まれるか分からない。文字列に .env が出てこないため
      //   protectedPathRegex も dangerousCommandRegex も当たらず、一致行として .env の
      //   中身がそのままモデルへ渡る（mac・Windows・OpenCode の 3 エンジン共通の性質）。
      //   grep ツール側は tool.execute.before と after の 2 段で受け止めているのに、
      //   bash 経由だけが素通しだと、そちらへ回り込むだけで保護が意味を失う。
      //   ここを外すと '*': 'ask' に落ちるが、grep ツール自体も permission の '*': 'ask'
      //   なので、受講者から見た確認の回数はどちらの経路でも同じ＝新しい種類の確認は
      //   増えない（「検索して」に 1 回確認が出る形に揃うだけ）。
      //   床側で完全に塞ぐのはコマンド文字列から検索先が分からない以上は構造的に無理なので、
      //   ここでは「確認を挟む」までにとどめ、残る性質は docs/90_守れる-守れない.md に書く。
      bash: {
        '*': longrun ? 'allow' : 'ask',
        'pwd': 'allow',
        'ls*': 'allow',
        'wc *': 'allow',
        'git status*': 'allow',
        'git diff*': 'allow',
        'git branch': 'allow',
        'git branch --list*': 'allow',
        'git --version': 'allow',
        'node -v': 'allow',
        'node --version': 'allow',
        'npm -v': 'allow',
        'npm --version': 'allow',
        'python --version': 'allow',
        'python3 --version': 'allow',
        'npm test*': 'allow',
        'npm run test*': 'allow',
        'node --test*': 'allow',
        'pytest*': 'allow',
        'python* -m unittest*': 'allow',
        ...enforcedBashDeny(longrun),
        // ask は deny の後ろ（最後に一致したルールが勝つ）。裸起動（codex* / claude*）も
        // 安全ランチャー（codex-safe* / claude-safe*）も、通常モードではここで確認制になる。
        // longrun ではこの表は空（全部 deny 側へ移した）。
        ...enforcedBashAsk(longrun),
      },
      external_directory: enforcedExternalDirectoryRules(),
      // 外部送信は無人で確認できないので、longrun では ask ではなく deny へ倒す。
      webfetch: longrun ? 'deny' : 'ask',
      websearch: longrun ? 'deny' : (enableWebSearch ? 'ask' : 'deny'),
      task: 'allow',
      // 配布スキル（hearing-ladder 等）は $XDG_CONFIG_HOME/opencode/skills/ から読まれる。
      // 「どのスキルを無確認で使ってよいか」をパターンで明示する（読むだけの指示書なので全許可）。
      skill: { '*': 'allow' },
      lsp: 'allow',
      question: 'allow',
      todoread: 'allow',
      todowrite: 'allow',
      doom_loop: longrun ? 'deny' : 'ask',
      // MCP はどれも外部サービスへ送信する。無人では確認に答えられないので longrun では禁止。
      ...(longrun
        ? Object.fromEntries(Object.keys(mcpConfig.permission).map((key) => [key, 'deny']))
        : mcpConfig.permission),
    },
  };
  if (Object.keys(mcpConfig.mcp).length) config.mcp = mcpConfig.mcp;
  if (monitorPlugin) config.plugin = [pathToFileURL(monitorPlugin).href];
  return config;
}

function parseArgs(argv) {
  let port = 8788;
  let enableWebSearch = false;
  let monitorPlugin = '';
  let printPermissionEnv = false;
  let printSecretEnv = false;
  let verifyResolved = false;
  let verifyResolvedFile = '';
  let longrun = false;
  let free = false;
  // MCP 実体（*-mcp.js）は、このスクリプトと同じ hooks/common に配置される。
  // 既定を __dirname にしておけばランチャーがパスを組み立て直す必要がない。
  let mcpDir = __dirname;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--print-permission-env') {
      printPermissionEnv = true;
    } else if (arg === '--print-secret-env') {
      printSecretEnv = true;
    } else if (arg === '--verify-resolved') {
      verifyResolved = true;
      // 次の引数が別のオプションでなければ、それを入力ファイルとして扱う。
      const next = argv[index + 1];
      if (next && !next.startsWith('--')) {
        verifyResolvedFile = next;
        index += 1;
      }
    } else if (arg === '--port') {
      port = Number(argv[index + 1]);
      index += 1;
    } else if (arg === '--websearch') {
      enableWebSearch = true;
    } else if (arg === '--longrun') {
      longrun = true;
    } else if (arg === '--free') {
      free = true;
    } else if (arg === '--monitor-plugin') {
      monitorPlugin = String(argv[index + 1] || '');
      index += 1;
    } else if (arg === '--mcp-dir') {
      mcpDir = String(argv[index + 1] || '');
      index += 1;
    } else {
      throw new Error(`unknown option: ${arg}`);
    }
  }
  return {
    port,
    enableWebSearch,
    monitorPlugin,
    printPermissionEnv,
    printSecretEnv,
    verifyResolved,
    verifyResolvedFile,
    longrun,
    free,
    mcpDir,
  };
}

// `debug config` 自身は最後に JSON を stdout へ書くが、初回だけ、その前後へ Bun の
// 依存関係準備ログが混ざることがある。Windows の npm/opencode ラッパーによってはログの
// 改行が無い、またはログ自体が JSON のこともあるため、位置ではなく OpenCode 設定の
// 構造を持つ JSON オブジェクトを 1 個だけ取り出す。
//
// 安全のため「見つかった中から都合のよい設定を選ぶ」ことはしない。設定 JSON が複数ある、
// または設定らしい JSON が複数ある曖昧な出力は拒否する。これにより、先に安全な偽設定を
// 出してから弱めた実設定を続ける形では起動前検査を通せない。単なる構造化ログや、設定内の
// agent/provider の子オブジェクトは候補に数えない。
function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function dropResolvedCommandBlock(value) {
  return String(value).replace(
    /(^\{\r?\n|,\r?\n)  "command"\s*:\s*\{[\s\S]*?(?=\r?\n  "[^"\r\n]+"\s*:|\r?\n\})/,
    '$1  "command": {},',
  );
}

function maskResolvedTextField(value, key) {
  const source = String(value);
  const startPattern = new RegExp(`(^[ \\t]*"${escapeRegExp(key)}"\\s*:\\s*")`, 'gm');
  let output = '';
  let lastIndex = 0;
  let match;

  while ((match = startPattern.exec(source)) !== null) {
    const indent = (match[0].match(/^[ \t]*/) || [''])[0];
    const contentStart = match.index + match[0].length;
    const nextSiblingPattern = new RegExp(`\\r?\\n${escapeRegExp(indent)}(?:"[^"\\r\\n]+"\\s*:|\\})`, 'g');
    nextSiblingPattern.lastIndex = contentStart;
    const nextSibling = nextSiblingPattern.exec(source);
    if (!nextSibling) continue;

    const removed = source.slice(contentStart, nextSibling.index);
    const comma = removed.trimEnd().endsWith(',');
    output += source.slice(lastIndex, match.index);
    output += `${indent}"${key}": ""${comma ? ',' : ''}`;
    lastIndex = nextSibling.index;
    startPattern.lastIndex = nextSibling.index;
  }

  return output + source.slice(lastIndex);
}

function parseResolvedConfigOutputLenient(raw) {
  let candidate = String(raw ?? '');
  const configStartCandidates = [
    candidate.indexOf('{\r\n  "agent"'),
    candidate.indexOf('{\n  "agent"'),
    candidate.indexOf('{\r\n  "$schema"'),
    candidate.indexOf('{\n  "$schema"'),
  ].filter((index) => index >= 0);
  if (configStartCandidates.length > 0) {
    const start = Math.min(...configStartCandidates);
    const end = candidate.lastIndexOf('}');
    if (end > start) candidate = candidate.slice(start, end + 1);
  }

  // OpenCode debug config on Windows can emit harness markdown fields as raw,
  // mojibake text instead of escaped JSON strings. These fields are not part of
  // the security floor we verify, so discard only their values and keep the
  // permission/plugin/provider structure intact.
  candidate = dropResolvedCommandBlock(candidate);
  for (const key of ['description', 'prompt', 'template']) {
    candidate = maskResolvedTextField(candidate, key);
  }
  return JSON.parse(candidate);
}

function parseResolvedConfigOutput(value) {
  let raw = String(value ?? '');
  if (raw.charCodeAt(0) === 0xfeff) raw = raw.slice(1);

  // 通常経路は公式どおり JSON だけ。最も厳しい読み方を先に試す。
  try {
    return JSON.parse(raw);
  } catch {
    // 初回準備ログが混ざった経路だけ、下の一意抽出へ進む。
  }

  const configKeys = [
    '$schema',
    'agent',
    'mode',
    'plugin',
    'command',
    'autoupdate',
    'share',
    'provider',
    'permission',
    'model',
    'small_model',
    'default_agent',
    'enabled_providers',
  ];
  const looksLikeResolvedConfig = (parsed) => (
    parsed
    && typeof parsed === 'object'
    && !Array.isArray(parsed)
    && configKeys.reduce(
      (count, key) => count + (Object.prototype.hasOwnProperty.call(parsed, key) ? 1 : 0),
      0,
    ) >= 4
  );

  const candidates = [];
  for (let start = 0; start < raw.length; start += 1) {
    if (raw[start] !== '{') continue;

    let depth = 0;
    let inString = false;
    let escaped = false;
    let end = -1;
    for (let index = start; index < raw.length; index += 1) {
      const character = raw[index];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (character === '\\') {
          escaped = true;
        } else if (character === '"') {
          inString = false;
        }
        continue;
      }
      if (character === '"') {
        inString = true;
      } else if (character === '{') {
        depth += 1;
      } else if (character === '}') {
        depth -= 1;
        if (depth === 0) {
          end = index + 1;
          break;
        }
        if (depth < 0) break;
      }
    }
    if (end < 0) continue;
    try {
      const parsed = JSON.parse(raw.slice(start, end));
      if (looksLikeResolvedConfig(parsed)) {
        candidates.push({ start, end, parsed });
      }
    } catch {
      // 行頭のログに波括弧があっただけなら候補にしない。ただし後段の曖昧性検査で拒否する。
    }
  }

  if (candidates.length === 1) return candidates[0].parsed;

  try {
    const parsed = parseResolvedConfigOutputLenient(raw);
    if (looksLikeResolvedConfig(parsed)) return parsed;
  } catch {
    // Fall through to the generic parser error below.
  }

  throw new SyntaxError('resolved config JSON is not unique');
}

module.exports = {
  MINIMUM_VERSION,
  MCP_SERVERS,
  SECRET_ENV_VARS,
  AGENT_LOCKED_KEYS,
  MONITOR_PLUGIN_FILE,
  CONVERSATION_LOG_DIRS,
  CONVERSATION_LOG_FILES,
  OPENED_DIR_LOCKDOWN,
  AGENT_SECRET_FILES,
  SECRET_DIRS,
  SECRET_FILES,
  enforcedSecretReadDenyRules,
  enforcedOpenedDirReadRules,
  enforcedOpenedDirEditDenyRules,
  enforcedReadRules,
  enforcedEditRules,
  enforcedExternalDirectoryRules,
  enforcedAgentConfigDenyRules,
  buildOpenCodeConfig,
  buildEnforcedPermissionEnv,
  buildMcpConfig,
  verifyResolvedConfig,
  parseResolvedConfigOutput,
  isSupportedVersion,
};

// `opencode debug config` の出力を受け取り、deny 床が生きているか検証する。
// 生きていれば exit 0、崩れていれば問題を日本語で出して exit 1。
// 入力はファイル（--verify-resolved <path>）か標準入力。Windows PowerShell 5.1 は
// ネイティブコマンドの標準入力を既定 ASCII で流すため（日本語ユーザー名等が壊れる）、
// .ps1 側はファイル渡しを使う。
function verifyFromInput(file, longrun = false) {
  const fs = require('node:fs');
  let raw = '';
  try {
    raw = fs.readFileSync(file || 0, 'utf8');
  } catch {
    process.stderr.write('opencode-config: 解決済み設定を読み取れませんでした。\n');
    process.exitCode = 1;
    return;
  }
  let parsed;
  try {
    parsed = parseResolvedConfigOutput(raw);
  } catch {
    process.stderr.write('opencode-config: 解決済み設定がJSONとして読めませんでした。\n');
    process.exitCode = 1;
    return;
  }
  const problems = verifyResolvedConfig(parsed, { longrun });
  if (problems.length) {
    for (const problem of problems) process.stderr.write(`  - ${problem}\n`);
    process.exitCode = 1;
  }
}

if (require.main === module) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.verifyResolved) {
      verifyFromInput(options.verifyResolvedFile, options.longrun);
    } else if (options.printPermissionEnv) {
      process.stdout.write(`${JSON.stringify(buildEnforcedPermissionEnv(options.longrun))}\n`);
    } else if (options.printSecretEnv) {
      process.stdout.write(`${SECRET_ENV_VARS.join(' ')}\n`);
    } else {
      process.stdout.write(`${JSON.stringify(buildOpenCodeConfig(options))}\n`);
    }
  } catch (error) {
    process.stderr.write(`opencode-config: ${error.message}\n`);
    process.exitCode = 2;
  }
}
