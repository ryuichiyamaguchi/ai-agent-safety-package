// secret-scan.sh / secret-scan.ps1 と同等のハード秘密検出 + 半構造 PII。
// reversible:true のカテゴリは alloc が与えられればトークン化（可逆）、無ければ [MASKED] 固定。
'use strict';

function luhnValid(num) {
  const d = String(num).replace(/[^0-9]/g, '');
  if (d.length < 13 || d.length > 19) return false;
  let sum = 0, alt = false;
  for (let i = d.length - 1; i >= 0; i--) {
    let n = d.charCodeAt(i) - 48;
    if (alt) { n *= 2; if (n > 9) n -= 9; }
    sum += n; alt = !alt;
  }
  return sum % 10 === 0;
}

// 文脈語ゲート: 一致の前後 ±20 文字の窓に文脈語が「重なる」かを判定。
// 語の一部でも窓に掛かれば near とみなす（M1: 複数文字語が窓境界で取りこぼされる off-by-one を解消）。
function nearContext(whole, offset, len, words) {
  const PAD = 20;
  const winStart = Math.max(0, offset - PAD);
  const winEnd = Math.min(whole.length, offset + len + PAD);
  for (const w of words) {
    let idx = whole.indexOf(w);
    while (idx !== -1) {
      if (idx + w.length > winStart && idx < winEnd) return true; // 語の span が窓と重なる
      idx = whole.indexOf(w, idx + 1);
    }
  }
  return false;
}

// 順序: 特異なハード秘密 → PII。reversible と category を明示。
// label: 出力ラベル上書き（既定 [MASKED:category]）。countAs: 集計キー上書き（null=集計しない）。
const RULES = [
  // private_key: ペアブロックを先に消費。残った未対応 BEGIN/END もフォールバックでマスク（C1）。
  { category: 'private_key', reversible: false, re: /-----BEGIN (?:RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----/g },
  { category: 'private_key', reversible: false, re: /-----BEGIN (?:RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----/g, label: '[MASKED:private_key_begin]' },
  { category: 'private_key', reversible: false, re: /-----END (?:RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----/g, label: '[MASKED:private_key_end]', countAs: null },
  { category: 'anthropic',   reversible: false, re: /sk-ant-[A-Za-z0-9_-]{20,}/g },
  { category: 'openai',      reversible: false, re: /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/g },
  { category: 'google',      reversible: false, re: /AIza[0-9A-Za-z_-]{25,}/g },
  { category: 'aws',         reversible: false, re: /(?:AKIA|ASIA)[0-9A-Z]{16}/g },
  { category: 'github',      reversible: false, re: /gh[pousr]_[A-Za-z0-9_]{36,255}/g },
  { category: 'slack',       reversible: false, re: /xox[baprs]-[A-Za-z0-9-]{10,}/g },
  { category: 'jwt',         reversible: false, re: /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g },
  // --- v1.17.0 で追加した各社 API キーの形（いずれも接頭辞が固有で誤検出しにくいものだけ） ---
  // これらは「知っている形」だけを拾う。伏せられたから安全、ではないことを利用者に必ず伝えること。
  { category: 'vendor_key',  reversible: false, re: /GOCSPX-[A-Za-z0-9_-]{20,}/g },                       // Google OAuth client secret
  { category: 'vendor_key',  reversible: false, re: /\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}/g },   // Stripe
  { category: 'vendor_key',  reversible: false, re: /\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}/g },    // SendGrid
  { category: 'vendor_key',  reversible: false, re: /\b(?:AC|SK)[0-9a-fA-F]{32}\b/g },                    // Twilio SID / API key
  { category: 'vendor_key',  reversible: false, re: /\bnpm_[A-Za-z0-9]{36}\b/g },                         // npm
  { category: 'vendor_key',  reversible: false, re: /\bpypi-[A-Za-z0-9_-]{16,}/g },                       // PyPI
  { category: 'vendor_key',  reversible: false, re: /\bhf_[A-Za-z0-9]{30,}/g },                           // Hugging Face
  { category: 'vendor_key',  reversible: false, re: /\b(?:secret_|ntn_)[A-Za-z0-9]{40,}/g },              // Notion
  { category: 'vendor_key',  reversible: false, re: /\bgsk_[A-Za-z0-9]{40,}/g },                          // Groq
  { category: 'vendor_key',  reversible: false, re: /\bxai-[A-Za-z0-9]{40,}/g },                          // xAI
  { category: 'vendor_key',  reversible: false, re: /\bglpat-[A-Za-z0-9_-]{20,}/g },                      // GitLab
  { category: 'vendor_key',  reversible: false, re: /\bshp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}\b/g },          // Shopify
  { category: 'vendor_key',  reversible: false, re: /\bsbp_[a-f0-9]{40}\b/g },                            // Supabase
  { category: 'vendor_key',  reversible: false, re: /\bdp\.pt\.[A-Za-z0-9]{40,}/g },                      // Doppler
  { category: 'vendor_key',  reversible: false, re: /\bdo[po]_v1_[a-f0-9]{64}\b/g },                      // DigitalOcean
  { category: 'vendor_key',  reversible: false, re: /\blin_api_[A-Za-z0-9]{40,}/g },                      // Linear
  { category: 'vendor_key',  reversible: false, re: /\bfigd_[A-Za-z0-9_-]{40,}/g },                       // Figma
  { category: 'vendor_key',  reversible: false, re: /\bdapi[a-f0-9]{32}\b/g },                            // Databricks
  { category: 'vendor_key',  reversible: false, re: /\bATATT3[A-Za-z0-9_=-]{50,}/g },                     // Atlassian
  { category: 'vendor_key',  reversible: false, re: /\b\d{8,10}:[A-Za-z0-9_-]{35}\b/g },                  // Telegram bot token
  { category: 'vendor_key',  reversible: false, re: /https:\/\/hooks\.slack\.com\/services\/[A-Za-z0-9/+=_-]{20,}/g },
  { category: 'vendor_key',  reversible: false, re: /https:\/\/discord(?:app)?\.com\/api\/webhooks\/\d+\/[A-Za-z0-9_-]{20,}/g },
  // Authorization ヘッダの Bearer / Basic（値だけ伏せる）
  { category: 'bearer',      reversible: false, generic: true,
    re: /((?:authorization|proxy-authorization)\s*[:=]\s*["']?(?:bearer|basic|token)\s+)([A-Za-z0-9._~+/=-]{16,})/gi },
  // URL に埋め込まれた資格情報 https://user:pass@host（ユーザー名とパスワードだけ伏せる）
  { category: 'url_credentials', reversible: false, urlcred: true,
    // スキーム部は長さ上限つき（[a-zA-Z0-9+.-]* にすると 10万文字の 'a' で O(n^2) になる = ReDoS）
    re: /([a-zA-Z][a-zA-Z0-9+.-]{0,20}:\/\/)([^\s/:@]{1,64}):([^\s/@]{1,128})@/g },
  // PII
  // email: ReDoS 対策で local/label を長さ境界化し、ラベル反復を {0,8} に固定（M2: 破滅的バックトラック回避）。
  { category: 'email',       reversible: true,  re: /[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(?:\.[A-Za-z0-9-]{1,63}){0,8}\.[A-Za-z]{2,24}/g },
  // credit_card: spec §3 の決定により「Luhn 通過のみ・文脈ゲート無し」を維持（M3）。
  // Luhn が誤検出を抑制する。稀に Luhn 偶然一致の数字 ID(注文番号等)を不可逆破壊し得るが spec 採用済みのトレードオフ。
  { category: 'credit_card', reversible: false, re: /\b(?:\d[ -]?){13,19}\b/g, luhn: true },
  { category: 'mynumber',    reversible: false, re: /\b\d{12}\b/g, context: ['マイナンバー', '個人番号', 'マイナ'] },
  { category: 'phone',       reversible: true,  re: /0\d{1,4}[-(]?\d{1,4}[-)]?\d{3,4}/g, context: ['電話', 'TEL', 'Tel', 'tel', '℡', '携帯', '連絡先'] },
  { category: 'postal',      reversible: true,  re: /〒?\s?\d{3}-?\d{4}/g, context: ['〒', '郵便', '住所'] },
  // generic は値部分のみ置換（特殊処理）
  { category: 'generic', reversible: false, generic: true, re: /(["']?(?:api[_-]?key|apikey|secret|token|password|passwd|pwd|credential|authorization)["']?\s*[:=]\s*["']?)([A-Za-z0-9_.+/=-]{12,})/gi },
];

const COUNT_KEYS = ['openai','anthropic','google','aws','github','slack','jwt','private_key','vendor_key','bearer','url_credentials','generic','email','phone','postal','credit_card','mynumber','denylist'];
// 発行済みの可逆トークンは、後段の denylist 置換から必ず守る。
// ds-gateway 経路は 〔Rn〕、クリップボードのマスキングツールは __SECRET_n__ を使う。
const TOKEN_RE_SPLIT = /(〔R\d+〕|__SECRET_\d+__)/;

function emptyCounts() { const c = { total: 0 }; for (const k of COUNT_KEYS) c[k] = 0; return c; }
function escapeRegExp(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

// opts.pii === 'strict' のとき、文脈語ゲート（電話 / 郵便番号）を外して拾いにいく。
// 既定（gateway 経路）は従来どおりゲートあり。strict はクリップボードのマスキングツール専用で、
// これらのカテゴリは可逆（復元ボタンで元に戻せる）ため、多めに拾っても取り返しがつく。
function maskText(text, { alloc, denylistTerms = [], pii = 'default' } = {}) {
  let masked = String(text);
  const counts = emptyCounts();
  const strictPii = pii === 'strict';
  const bump = (countKey) => { if (countKey) { counts[countKey] = (counts[countKey] || 0) + 1; counts.total += 1; } };

  for (const rule of RULES) {
    rule.re.lastIndex = 0;
    if (rule.generic) {
      const cat = rule.category || 'generic';
      masked = masked.replace(rule.re, (m, prefix) => { bump(cat); return `${prefix}[MASKED:${cat}]`; });
      continue;
    }
    if (rule.urlcred) {
      masked = masked.replace(rule.re, (m, scheme) => { bump(rule.category); return `${scheme}[MASKED:${rule.category}]@`; });
      continue;
    }
    masked = masked.replace(rule.re, (...a) => {
      const m = a[0];
      const offset = a[a.length - 2];
      const whole = a[a.length - 1];
      const gated = rule.context && !(strictPii && rule.reversible);
      if (gated && !nearContext(whole, offset, m.length, rule.context)) return m;
      if (rule.luhn && !luhnValid(m)) return m;
      const countKey = rule.countAs === undefined ? rule.category : rule.countAs;
      bump(countKey);
      if (rule.reversible && alloc) return alloc(m, rule.category);
      return rule.label || `[MASKED:${rule.category}]`;
    });
  }

  // denylist（部分一致・大小無視・可逆）。
  // C2: 既に発行済みの可逆トークン 〔R\d+〕 の内部には絶対にマッチさせない（split で保護）。
  if (denylistTerms.length) {
    const parts = masked.split(TOKEN_RE_SPLIT);
    for (let i = 0; i < parts.length; i++) {
      if (/^〔R\d+〕$/.test(parts[i])) continue; // 発行済みトークンは保護
      for (const term of denylistTerms) {
        if (!term) continue;
        const re = new RegExp(escapeRegExp(term), 'gi');
        parts[i] = parts[i].replace(re, (m) => { bump('denylist'); return (alloc) ? alloc(m, 'denylist') : '[MASKED:denylist]'; });
      }
    }
    masked = parts.join('');
  }
  return { masked, counts };
}

function maskSecrets(text) { return maskText(text, {}); }

module.exports = { maskText, maskSecrets, COUNT_KEYS, luhnValid };
