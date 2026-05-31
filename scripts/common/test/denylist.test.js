const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs'); const os = require('node:os'); const path = require('node:path');
const { loadDenylist } = require('../denylist.js');

test('loads terms, ignores comments and blank lines', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dl-'));
  const f = path.join(dir, 'denylist.txt');
  fs.writeFileSync(f, '田中商事\n# コメント\n\n  〇〇市△△町1-2-3  \n');
  const terms = loadDenylist(f);
  assert.deepStrictEqual(terms, ['田中商事', '〇〇市△△町1-2-3']);
});

test('returns empty array when file is missing', () => {
  assert.deepStrictEqual(loadDenylist('/no/such/file.txt'), []);
});
