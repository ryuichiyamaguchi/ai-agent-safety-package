// opencode-redaction.test.js — OpenCode の `debug config` の伏せ字（***）で起動前検査が止まらないことの検査。
//
// OpenCode 1.18.26 以降の `opencode debug config` は、名前に credential / secret / password / api-key /
// private-key / oauth-token などを含む設定項目の値を `***` に伏せて表示する（1.18.33 で実測）。
// 起動前検査は debug config の値を配布物と突き合わせるため、読み取りの規則に
// `~/.claude/.credentials.json` と `…/antigravity-oauth-token` があるだけで
// 「読み取り禁止が書き換えられています」と止まり、OpenCode が起動できなくなった
// （2026-09-29 受講者の Windows。OpenCode を最新版に更新した直後）。
'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const path = require('node:path');

const OC = require(path.join(__dirname, '..', 'opencode-config.js'));

// 1.18.33 で実測した「伏せ字になる名前」（REDACTED）と「ならない名前」（ok）を覆う形。
// token 単体・auth・creds・key 単体は伏せ字にならなかったが、将来増えても分かるように少し広めに取る。
const REDACTED_WORD = /(credential|secret|password|api[-_]?key|private[-_]?key|oauth[-_]?token|access[-_]?token|refresh[-_]?token)/i;

test('どの許可表の名前にも、OpenCode が伏せ字にする単語が入っていない', () => {
  const tables = {
    read: OC.enforcedReadRules(),
    edit: OC.enforcedEditRules(false),
    editLongrun: OC.enforcedEditRules(true),
    external_directory: OC.enforcedExternalDirectoryRules(),
  };
  const bad = [];
  for (const [name, table] of Object.entries(tables)) {
    for (const key of Object.keys(table)) if (REDACTED_WORD.test(key)) bad.push(`${name}: ${key}`);
  }
  assert.deepStrictEqual(bad, []);
});

test('伏せ字（***）で返ってきたら、原因の分かる文面で止める', () => {
  const read = { ...OC.enforcedReadRules() };
  const firstDeny = Object.keys(read).find((k) => read[k] === 'deny');
  read[firstDeny] = '***';
  const problems = OC.verifyResolvedConfig({
    permission: { read, edit: OC.enforcedEditRules(false), external_directory: OC.enforcedExternalDirectoryRules() },
  });
  assert.ok(problems.some((p) => p.includes('伏せ字') && p.includes(firstDeny)), problems.join('\n'));
});
