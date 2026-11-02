'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { prettyHaskell, renderCounterexample } = require('../src/pretty');

test('formats a nested Haskell ScriptContext without splitting quoted bytes', () => {
  const input = 'ScriptContext {scriptContextTxInfo = TxInfo {txInfoInputs = [], txInfoFee = 3}, scriptContextRedeemer = B "a,b", scriptContextScriptInfo = MintingScript 2}';
  const pretty = prettyHaskell(input);
  assert.match(pretty, /ScriptContext \{\n  scriptContextTxInfo = TxInfo \{\n    txInfoInputs = \[\],\n    txInfoFee = 3\n  \}/);
  assert.match(pretty, /scriptContextRedeemer = B "a,b"/);
  assert.match(pretty, /scriptContextScriptInfo = MintingScript 2\n\}/);
});

test('renders the decoded value for an inline hover and a full Haskell view', () => {
  const output = 'ScriptContext {scriptContextTxInfo = TxInfo {txInfoInputs = []}, scriptContextScriptInfo = MintingScript 2}\n("ctx","decodeData ctxData")\n';
  const rendered = renderCounterexample(output, {
    property: 'uncheckedPurpose_purpose_isolation', replay: 'confirmed',
    inputs: [{ name: 'ctx', sourceType: 'V3.ScriptContext' }]
  }, 'Counterexample0.hs');
  assert.match(rendered.value, /^counterexample :: V3.ScriptContext\ncounterexample =\n  ScriptContext \{/);
  assert.match(rendered.value, /scriptContextScriptInfo = MintingScript 2/);
  assert.match(rendered.content, /-- Compiled UPLC replay: confirmed/);
  assert.match(rendered.content, /-- \("ctx","decodeData ctxData"\)/);
  assert.throws(() => renderCounterexample('', { inputs: [] }, 'CEX.hs'), /no value/);
});
