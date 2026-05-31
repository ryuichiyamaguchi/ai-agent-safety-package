// secret-scan.sh / secret-scan.ps1 と同一の検出仕様（9 種）。
// 型ラベル精度のため特異なパターンを先に適用する。
'use strict';

// countAs: undefined → count under rule.type; countAs:'x' → count under 'x'; countAs: null → don't count (used for PEM _end markers)
const RULES = [
  { type: 'anthropic',          re: /sk-ant-[A-Za-z0-9_-]{20,}/g,                          label: '[MASKED:anthropic]' },
  { type: 'openai',             re: /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/g,                     label: '[MASKED:openai]' },
  { type: 'google',             re: /AIza[0-9A-Za-z_-]{25,}/g,                              label: '[MASKED:google]' },
  { type: 'aws',                re: /(?:AKIA|ASIA)[0-9A-Z]{16}/g,                           label: '[MASKED:aws]' },
  { type: 'github',             re: /gh[pousr]_[A-Za-z0-9_]{36,255}/g,                      label: '[MASKED:github]' },
  { type: 'slack',              re: /xox[baprs]-[A-Za-z0-9-]{10,}/g,                        label: '[MASKED:slack]' },
  { type: 'jwt',                re: /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g,   label: '[MASKED:jwt]' },
  { type: 'private_key_begin',  re: /-----BEGIN (?:RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----/g, label: '[MASKED:private_key_begin]', countAs: 'private_key' },
  { type: 'private_key_end',    re: /-----END (?:RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----/g,   label: '[MASKED:private_key_end]',   countAs: null },
  { type: 'generic',            re: /(api[_-]?key|secret|token|password|passwd|pwd)(\s*[:=]\s*)['"]?[A-Za-z0-9_.+/=-]{12,}['"]?/gi, label: null },
];

const COUNT_KEYS = ['openai','anthropic','google','aws','github','slack','jwt','private_key','generic'];

function emptyCounts() {
  const c = { total: 0 };
  for (const k of COUNT_KEYS) c[k] = 0;
  return c;
}

function maskSecrets(input) {
  let masked = String(input);
  const counts = emptyCounts();

  for (const rule of RULES) {
    rule.re.lastIndex = 0;
    if (rule.type === 'generic') {
      masked = masked.replace(rule.re, (m, name, sep) => {
        counts.generic += 1; counts.total += 1;
        return `${name}${sep}[MASKED:generic]`;
      });
      continue;
    }
    masked = masked.replace(rule.re, () => {
      const key = rule.countAs === undefined ? rule.type : rule.countAs;
      if (key) { counts[key] += 1; counts.total += 1; }
      return rule.label;
    });
  }
  return { masked, counts };
}

module.exports = { maskSecrets, COUNT_KEYS };
