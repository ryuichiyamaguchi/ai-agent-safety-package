// token-map.js — 可逆マスキングのトークン採番（プロセス内メモリのみ・ディスク保存なし）
'use strict';
function createTokenMap({ max = 5000 } = {}) {
  let seq = 0;
  const byValue = new Map();  // value -> token
  const byToken = new Map();  // token -> value（挿入順 = 古い順）
  function evictIfNeeded() {
    while (byToken.size > max) {
      const oldestToken = byToken.keys().next().value;
      const oldestValue = byToken.get(oldestToken);
      byToken.delete(oldestToken);
      if (byValue.get(oldestValue) === oldestToken) byValue.delete(oldestValue);
    }
  }
  return {
    alloc(value, _category) {
      const v = String(value);
      if (byValue.has(v)) return byValue.get(v);
      seq += 1;
      const token = `〔R${seq}〕`;
      byValue.set(v, token);
      byToken.set(token, v);
      evictIfNeeded();
      return token;
    },
    getOriginal(token) { return byToken.get(token); },
    get size() { return byToken.size; },
  };
}
module.exports = { createTokenMap };
