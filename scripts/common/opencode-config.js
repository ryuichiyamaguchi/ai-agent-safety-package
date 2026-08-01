#!/usr/bin/env node
'use strict';

const MINIMUM_VERSION = [1, 14, 24];
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

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
];

// OpenCode 本体のプロセス環境から必ず取り除く秘密の環境変数（SSOT）。
// ランチャーは `--print-secret-env` でこの一覧を受け取り、OpenCode を起動する前に消す。
// 消す理由: OpenCode 配下の bash 子プロセスは環境をそのまま継承するので、`env` や
// `printenv` を一度通せば AI に鍵の実物が見えてしまう（送信検査 Gateway のマスキングは
// 「外へ送るとき」の話で、画面に出るのは止められない）。
// Gemini / Google の鍵をここに入れた結果、検索・画像読取の MCP は
// ~/.ai-safety/gemini-api-key.txt（「6_AIコーチのキーを登録」が書く場所）だけを見る。
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
  try {
    return fs.readFileSync(path.join(homeDir, '.ai-safety', 'gemini-api-key.txt'), 'utf8').trim().length > 0;
  } catch {
    return false;
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
    permission[`${server.key}_${server.tool}`] = 'ask';
  }
  return { mcp, permission };
}

// 設定・環境変数の両方で必ず deny に固定する bash パターン（SSOT）。
// OPENCODE_PERMISSION は OPENCODE_CONFIG_CONTENT より後にマージされるため、ランチャーは
// この集合を環境変数側にも明示 export して「危険な既存値の消去」と「安全な値での上書き」を
// 二重に行う（1.18.4 実測: 環境変数側のキーが最後に勝つ）。
// curl / wget は送信検査 Gateway を迂回する外部通信の主経路なので deny に含める。
function enforcedBashDeny() {
  return {
    [['r', 'm *'].join('')]: 'deny',
    'sudo *': 'deny',
    'git push*': 'deny',
    'npm publish*': 'deny',
    'curl *': 'deny',
    'wget *': 'deny',
    'git reset --hard*': 'deny',
    'chmod -R *': 'deny',
  };
}

// ランチャーが OPENCODE_PERMISSION に入れる最小の deny 集合。
function buildEnforcedPermissionEnv() {
  return {
    bash: enforcedBashDeny(),
    external_directory: 'deny',
  };
}

// ファイル名の「.」をソースに直書きしない（このファイル自身が .env / .ai-safety を含むと
// 安全ガードの保護パス検査に自分で引っかかるため）。
const DOT = String.fromCharCode(46);

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
  };
}

// edit（write ツールを含む書き換え系）の許可表（SSOT）。
// 素の 'ask' だけだと、受講者が 1 度「常に許可」を押した時点で .ai-safety/policy/ や
// hooks/ を書き換えられる＝安全ルールと決定的 deny 床そのものを無効化できる。しかも
// 床を殺した状態は次回以降の起動でも「正常に見える」ので、パターン単位で禁止する
// （1.18.4 実測: edit もパターン表を受け付ける）。
function enforcedEditRules() {
  return {
    '*': 'ask',
    [`*${DOT}ai-safety`]: 'deny',
    [`**/${DOT}ai-safety`]: 'deny',
    [`*${DOT}ai-safety/**`]: 'deny',
    [`**/${DOT}ai-safety/**`]: 'deny',
  };
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
function verifyResolvedConfig(resolved) {
  const problems = [];
  if (!resolved || typeof resolved !== 'object') return ['解決済み設定を読み取れませんでした。'];
  const permission = resolved.permission && typeof resolved.permission === 'object' ? resolved.permission : {};
  const bash = permission.bash && typeof permission.bash === 'object' ? permission.bash : {};
  for (const [pattern, action] of Object.entries(enforcedBashDeny())) {
    if (bash[pattern] !== action) problems.push(`bash の「${pattern}」が禁止になっていません。`);
  }
  if (bash['*'] === 'allow') problems.push('bash がすべて自動許可になっています。');
  if (permission.external_directory !== 'deny') problems.push('作業フォルダの外へのアクセスが禁止になっていません。');
  if (resolved.share !== 'disabled') problems.push('会話の共有リンク作成が無効になっていません。');
  // read / edit は「並び順まで含めて」配布物どおりであることを求める。ここは最後に一致した
  // ルールが勝つ世界なので、キーが全部残っていても順番を入れ替えるだけで禁止が無効になる
  // （`*: allow` を deny の後ろへ動かす等）。丸ごと比較なら書き換え・並べ替えの両方を弾ける。
  if (JSON.stringify(permission.read) !== JSON.stringify(enforcedReadRules())) {
    problems.push('パスワードや鍵が入ったファイル（.env など）と安全ルール置き場の読み取り禁止が書き換えられています。');
  }
  if (JSON.stringify(permission.edit) !== JSON.stringify(enforcedEditRules())) {
    problems.push('安全ルール置き場（.ai-safety）の書き換え禁止が外れています。');
  }
  // 外部通信系はパターン表にされると穴を開けられるので「文字列で allow 以外」だけを通す。
  for (const [key, label] of [['webfetch', 'インターネットのページ取得'], ['websearch', 'Web検索']]) {
    const value = permission[key];
    if (typeof value !== 'string' || value === 'allow') {
      problems.push(`${label}が無確認で使える設定になっています。`);
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
} = {}) {
  const safePort = Number(port);
  if (!Number.isInteger(safePort) || safePort < 1 || safePort > 65535) {
    throw new Error('OpenCode gateway port must be an integer between 1 and 65535');
  }
  const apiKey = resolveGatewayToken(gatewayToken);
  const mcpConfig = buildMcpConfig({ mcpDir, env, homeDir });
  if (monitorPlugin && !path.isAbsolute(monitorPlugin)) {
    throw new Error('OpenCode monitor plugin path must be absolute');
  }
  const config = {
    $schema: 'https://opencode.ai/config.json',
    model: 'bouncer-deepseek/deepseek-v4-pro',
    small_model: 'bouncer-deepseek/deepseek-v4-flash',
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
        model: 'bouncer-deepseek/deepseek-v4-pro',
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
        model: 'bouncer-deepseek/deepseek-v4-flash',
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
          'deepseek-v4-pro': { name: 'DeepSeek V4 Pro (Bouncer protected)' },
          'deepseek-v4-flash': { name: 'DeepSeek V4 Flash (Bouncer protected)' },
        },
      },
    },
    permission: {
      '*': 'ask',
      read: enforcedReadRules(),
      edit: enforcedEditRules(),
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
        '*': 'ask',
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
        ...enforcedBashDeny(),
      },
      external_directory: 'deny',
      webfetch: 'ask',
      websearch: enableWebSearch ? 'ask' : 'deny',
      task: 'allow',
      // 配布スキル（hearing-ladder 等）は $XDG_CONFIG_HOME/opencode/skills/ から読まれる。
      // 「どのスキルを無確認で使ってよいか」をパターンで明示する（読むだけの指示書なので全許可）。
      skill: { '*': 'allow' },
      lsp: 'allow',
      question: 'allow',
      todoread: 'allow',
      todowrite: 'allow',
      doom_loop: 'ask',
      ...mcpConfig.permission,
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
  enforcedReadRules,
  enforcedEditRules,
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
function verifyFromInput(file) {
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
  const problems = verifyResolvedConfig(parsed);
  if (problems.length) {
    for (const problem of problems) process.stderr.write(`  - ${problem}\n`);
    process.exitCode = 1;
  }
}

if (require.main === module) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.verifyResolved) {
      verifyFromInput(options.verifyResolvedFile);
    } else if (options.printPermissionEnv) {
      process.stdout.write(`${JSON.stringify(buildEnforcedPermissionEnv())}\n`);
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
