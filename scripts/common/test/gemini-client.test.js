'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const client = require(path.resolve(__dirname, '..', 'gemini-client.js'));

test('GeminiのMAX_TOKENS応答を完成回答として表示しない', () => {
  const result = client.parseGeminiResponse({
    candidates: [{
      finishReason: 'MAX_TOKENS',
      content: { parts: [{ text: '①この操作は具体的に何をするか\n「OpenCode」が、あなたのパソコンの「/Users/ryuichi/Documents/my' }] },
    }],
  });
  assert.equal(result.ok, false);
  assert.equal(result.truncated, true);
  assert.doesNotMatch(result.text, /Documents\/my$/, '途中で切れた本文を利用者へ返さない');
  assert.match(result.text, /途中で切れ/);
});

test('自然終了したGemini応答だけを完成回答として返す', () => {
  const result = client.parseGeminiResponse({
    candidates: [{
      finishReason: 'STOP',
      content: { parts: [{ text: '対象を検索するだけです。\n許可してよい' }] },
    }],
  });
  assert.deepEqual(result, { ok: true, text: '対象を検索するだけです。\n許可してよい' });
});
