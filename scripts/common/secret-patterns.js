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

function nearContext(whole, offset, len, words) {
  const start = Math.max(0, offset - 20);
  const end = Math.min(whole.length, offset + len + 20);
  const around = whole.slice(start, end);
  return words.some((w) => around.includes(w));
}

// 順序: 特異なハード秘密 → PII。reversible と category を明示。
const RULES = [
  { category: 'private_key', reversible: false, re: /-----BEGIN (?:RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----/g },
  { category: 'anthropic',   reversible: false, re: /sk-ant-[A-Za-z0-9_-]{20,}/g },
  { category: 'openai',      reversible: false, re: /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/g },
  { category: 'google',      reversible: false, re: /AIza[0-9A-Za-z_-]{25,}/g },
  { category: 'aws',         reversible: false, re: /(?:AKIA|ASIA)[0-9A-Z]{16}/g },
  { category: 'github',      reversible: false, re: /gh[pousr]_[A-Za-z0-9_]{36,255}/g },
  { category: 'slack',       reversible: false, re: /xox[baprs]-[A-Za-z0-9-]{10,}/g },
  { category: 'jwt',         reversible: false, re: /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g },
  // PII
  { category: 'email',       reversible: true,  re: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g },
  { category: 'credit_card', reversible: false, re: /\b(?:\d[ -]?){13,19}\b/g, luhn: true },
  { category: 'mynumber',    reversible: false, re: /\b\d{12}\b/g, context: ['マイナンバー', '個人番号', 'マイナ'] },
  { category: 'phone',       reversible: true,  re: /0\d{1,4}[-(]?\d{1,4}[-)]?\d{3,4}/g, context: ['電話', 'TEL', 'Tel', 'tel', '℡', '携帯', '連絡先'] },
  { category: 'postal',      reversible: true,  re: /〒?\s?\d{3}-?\d{4}/g, context: ['〒', '郵便', '住所'] },
  // generic は値部分のみ置換（特殊処理）
  { category: 'generic', reversible: false, generic: true, re: /(["']?(?:api[_-]?key|secret|token|password|passwd|pwd)["']?\s*[:=]\s*["']?)([A-Za-z0-9_.+/=-]{12,})/gi },
];

const COUNT_KEYS = ['openai','anthropic','google','aws','github','slack','jwt','private_key','generic','email','phone','postal','credit_card','mynumber','denylist'];

function emptyCounts() { const c = { total: 0 }; for (const k of COUNT_KEYS) c[k] = 0; return c; }
function escapeRegExp(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function maskText(text, { alloc, denylistTerms = [] } = {}) {
  let masked = String(text);
  const counts = emptyCounts();

  const replaceOne = (category, reversible, value) => {
    counts[category] = (counts[category] || 0) + 1; counts.total += 1;
    return (reversible && alloc) ? alloc(value, category) : `[MASKED:${category}]`;
  };

  for (const rule of RULES) {
    rule.re.lastIndex = 0;
    if (rule.generic) {
      masked = masked.replace(rule.re, (m, prefix) => {
        counts.generic += 1; counts.total += 1;
        return `${prefix}[MASKED:generic]`;
      });
      continue;
    }
    masked = masked.replace(rule.re, (...a) => {
      const m = a[0];
      const offset = a[a.length - 2];
      const whole = a[a.length - 1];
      if (rule.context && !nearContext(whole, offset, m.length, rule.context)) return m;
      if (rule.luhn && !luhnValid(m)) return m;
      return replaceOne(rule.category, rule.reversible, m);
    });
  }

  // denylist（部分一致・大小無視・可逆）
  for (const term of denylistTerms) {
    if (!term) continue;
    const re = new RegExp(escapeRegExp(term), 'gi');
    masked = masked.replace(re, (m) => replaceOne('denylist', true, m));
  }
  return { masked, counts };
}

function maskSecrets(text) { return maskText(text, {}); }

module.exports = { maskText, maskSecrets, COUNT_KEYS, luhnValid };
