'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  collectNativeReportFiles,
  counterexamples,
  fileState,
  inputState,
  loadNativeReports,
  readNativeReport
} = require('../src/native');

const digest = (text) => crypto.createHash('sha256').update(text).digest('hex');

function fixture(uri = 'counterexamples/Counterexample0.hs') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cardano-blaster-vscode-'));
  const run = path.join(root, 'run-1');
  const source = path.join(run, 'counterexamples', 'Counterexample0.hs');
  fs.mkdirSync(path.dirname(source), { recursive: true });
  fs.writeFileSync(source, 'module Main where\nmain = print "decoded"\n');
  const blueprint = path.join(root, 'plutus.json');
  fs.writeFileSync(blueprint, '{}');
  const report = path.join(run, 'report.json');
  fs.writeFileSync(report, JSON.stringify({
    format: 'cardano-blaster-check-v1',
    inputs: { [blueprint]: digest('{}') },
    results: [{
      property: 'uncheckedPurpose_purpose_isolation', outcome: 'falsified',
      counterexample: {
        replay: { status: 'confirmed' },
        source: {
          status: 'exported', file: { uri, hash: { alg: 'sha256', digest: digest(fs.readFileSync(source)) } },
          inputs: [{ name: 'ctx', sourceType: 'V3.ScriptContext', expression: 'decodeData ctxData' }]
        }
      }
    }]
  }));
  return { root, report, source, blueprint };
}

test('loads an exported, confirmed ScriptContext CEX and checks source/input digests', () => {
  const { root, report, source, blueprint } = fixture();
  assert.deepEqual(collectNativeReportFiles(root), [report]);
  const loaded = loadNativeReports([report]);
  assert.deepEqual(loaded.errors, []);
  const [choice] = counterexamples(loaded.reports);
  assert.equal(choice.property, 'uncheckedPurpose_purpose_isolation');
  assert.equal(choice.sourceFile, source);
  assert.equal(choice.inputs[0].sourceType, 'V3.ScriptContext');
  assert.equal(fileState(source, choice.sourceHash).matches, true);
  assert.deepEqual(inputState(choice.report), []);
  fs.writeFileSync(blueprint, '{"changed":true}');
  assert.deepEqual(inputState(choice.report), [blueprint]);
  fs.appendFileSync(source, '-- altered\n');
  assert.equal(fileState(source, choice.sourceHash).matches, false);
});

test('does not offer unconfirmed or unavailable CEX as Haskell', () => {
  const { report } = fixture();
  const raw = JSON.parse(fs.readFileSync(report, 'utf8'));
  raw.results[0].counterexample.replay.status = 'unconfirmed';
  fs.writeFileSync(report, JSON.stringify(raw));
  assert.deepEqual(counterexamples([readNativeReport(report)]), []);
  raw.results[0].counterexample.replay.status = 'confirmed';
  raw.results[0].counterexample.source.status = 'unavailable';
  fs.writeFileSync(report, JSON.stringify(raw));
  assert.deepEqual(counterexamples([readNativeReport(report)]), []);
});

test('rejects counterexample paths that escape the report directory', () => {
  const { report } = fixture('../other.hs');
  assert.throws(() => readNativeReport(report), /escapes the report directory/);
});

test('rejects a symlinked Haskell source outside the run', () => {
  const { root, report } = fixture('outside.hs');
  const outside = path.join(root, 'outside.hs');
  fs.writeFileSync(outside, 'main = print "outside"\n');
  fs.symlinkSync(outside, path.join(path.dirname(report), 'outside.hs'));
  assert.throws(() => readNativeReport(report), /through a symlink/);
});
