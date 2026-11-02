'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { prettyHaskell } = require('../src/pretty');

test('formats a nested Haskell ScriptContext without splitting quoted bytes', () => {
  const input = 'ScriptContext {scriptContextTxInfo = TxInfo {txInfoInputs = [], txInfoFee = 3}, scriptContextRedeemer = B "a,b", scriptContextScriptInfo = MintingScript 2}';
  const pretty = prettyHaskell(input);
  assert.match(pretty, /ScriptContext \{\n  scriptContextTxInfo = TxInfo \{\n    txInfoInputs = \[\],\n    txInfoFee = 3\n  \}/);
  assert.match(pretty, /scriptContextRedeemer = B "a,b"/);
  assert.match(pretty, /scriptContextScriptInfo = MintingScript 2\n\}/);
});
