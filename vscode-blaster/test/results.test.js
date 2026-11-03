'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  collectResultFiles,
  evidenceStatus,
  mergeResults,
  propertyBlocks,
  propertyForSource,
  sha256File,
  sourceState
} = require('../src/results');

test('finds property IDs and source ranges in detached Haskell specs', () => {
  const source = [
    'module FormalSpec where',
    '{-@ PROPERTY [scope: auction] first_bid_exact',
    '  : True',
    '@-}',
    '{-@ PROPERTY malformed_context : True @-}'
  ].join('\n');
  const blocks = propertyBlocks(source);
  assert.deepEqual(blocks.map((block) => block.id), ['first_bid_exact', 'malformed_context']);
  assert.equal(blocks[0].idStart.line, 1);
  assert.equal(source.split('\n')[blocks[0].idStart.line].slice(blocks[0].idStart.character, blocks[0].idEnd.character), 'first_bid_exact');
});

test('locates the generated id of a purpose-isolation template at its scope', () => {
  const source = '{-@ PROPERTY [scope: uncheckedPurpose] [template: purpose-isolation spending] @-}\n';
  const [block] = propertyBlocks(source);
  assert.equal(block.id, 'uncheckedPurpose_purpose_isolation');
  assert.equal(source.slice(block.idStart.character, block.idEnd.character), 'uncheckedPurpose');
});

test('summarizes fresh verified evidence', () => {
  assert.deepEqual(evidenceStatus({ evidence: [{ outcome: 'verified', method: 'smt-check', date: '2026-10-07' }] }), {
    outcome: 'verified',
    label: 'Verified by Blaster',
    method: 'smt-check',
    date: '2026-10-07',
    notes: undefined,
    scriptHash: undefined
  });
  assert.equal(evidenceStatus({}).outcome, 'unchecked');
});

test('loads result trees and detects modified source', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'blaster-vscode-'));
  const source = path.join(root, 'FormalSpec.hs');
  const results = path.join(root, 'auction');
  fs.mkdirSync(results);
  fs.writeFileSync(source, '{-@ PROPERTY p : True @-}\n');
  const digest = sha256File(source);
  fs.writeFileSync(path.join(results, 'verified-assurance.json'), JSON.stringify({
    properties: [{ id: 'p', evidence: [{ outcome: 'verified', method: 'smt-check' }] }]
  }));
  fs.writeFileSync(path.join(results, 'run-report.json'), JSON.stringify({
    provenance: { sources: { [source]: { alg: 'sha256', digest } } }
  }));
  const files = collectResultFiles(root);
  const loaded = mergeResults(files);
  assert.equal(files.length, 1);
  assert.equal(loaded.properties.get('p').outcome, 'verified');
  assert.equal(sourceState(source, loaded.sourceHashes).stale, false);
  fs.appendFileSync(source, '-- changed\n');
  assert.equal(sourceState(source, loaded.sourceHashes).stale, true);
});

test('a focused counterexample overrides one property without refreshing others', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'blaster-focused-'));
  const source = path.join(root, 'FormalSpec.hs');
  const original = '{-@ PROPERTY p : True @-}\n';
  const changed = '{-@ PROPERTY p : False @-}\n';
  fs.writeFileSync(source, original);
  const base = path.join(root, 'auction');
  fs.mkdirSync(base);
  fs.writeFileSync(path.join(base, 'verified-assurance.json'), JSON.stringify({
    properties: [
      { id: 'p', evidence: [{ outcome: 'verified' }] },
      { id: 'q', evidence: [{ outcome: 'verified' }] }
    ]
  }));
  fs.writeFileSync(path.join(base, 'run-report.json'), JSON.stringify({
    provenance: { sources: { [source]: { alg: 'sha256', digest: sha256File(source) } } }
  }));
  fs.writeFileSync(source, changed);
  const focused = path.join(root, 'property-runs', 'auction', 'p');
  fs.mkdirSync(focused, { recursive: true });
  fs.writeFileSync(path.join(focused, 'property-result.json'), JSON.stringify({
    property: 'p', outcome: 'falsified', source,
    sourceSha256: sha256File(source), counterexample: { x: '0' }
  }));
  const loaded = mergeResults(collectResultFiles(root));
  assert.equal(loaded.properties.get('p').outcome, 'falsified');
  assert.deepEqual(loaded.properties.get('p').counterexample, { x: '0' });
  assert.equal(sourceState(source, loaded.sourceHashes, changed, loaded.properties.get('p')).stale, false);
  assert.equal(sourceState(source, loaded.sourceHashes, changed, loaded.properties.get('q')).stale, true);
  assert.equal(sourceState(source, loaded.sourceHashes, changed + '-- unsaved\n', loaded.properties.get('p')).stale, true);
});


test('a copied annotation result cannot label the original file with the same property ID', () => {
  const source = path.resolve('/tmp/original/FormalSpec.hs');
  const copy = path.resolve('/tmp/counterexample/FormalSpec.hs');
  const property = { source: copy, sourceHash: 'abc' };
  const result = sourceState(source, new Map(), 'same content', property);
  assert.equal(result.stale, true);
  assert.match(result.reason, /different source file/);
});


test('original and copied annotations with the same ID retain independent fresh results', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'blaster-source-copies-'));
  const original = path.join(root, 'Original.hs');
  const copy = path.join(root, 'FormalSpec.hs');
  fs.writeFileSync(original, '{-@ PROPERTY p : True @-}\n');
  fs.writeFileSync(copy, '{-@ PROPERTY p : False @-}\n');
  const base = path.join(root, 'base');
  const focus = path.join(root, 'copy');
  fs.mkdirSync(base);
  fs.mkdirSync(focus);
  fs.writeFileSync(path.join(base, 'verified-assurance.json'), JSON.stringify({
    properties: [{ id: 'p', evidence: [{ outcome: 'verified' }] }]
  }));
  fs.writeFileSync(path.join(base, 'run-report.json'), JSON.stringify({
    provenance: { sources: { [original]: { alg: 'sha256', digest: sha256File(original) } } }
  }));
  fs.writeFileSync(path.join(focus, 'property-result.json'), JSON.stringify({
    property: 'p', outcome: 'falsified', source: copy, sourceSha256: sha256File(copy),
    structuredCounterexample: { replay: { status: 'confirmed' } }
  }));
  const state = mergeResults(collectResultFiles(root));
  const verified = propertyForSource(state, original, 'p');
  const falsified = propertyForSource(state, copy, 'p');
  assert.equal(verified.outcome, 'verified');
  assert.equal(falsified.outcome, 'falsified');
  assert.equal(falsified.replay.status, 'confirmed');
  assert.equal(sourceState(original, state.sourceHashes, undefined, verified).stale, false);
  assert.equal(sourceState(copy, state.sourceHashes, undefined, falsified).stale, false);
  assert.equal(state.allProperties.length, 2);
  assert.equal(propertyForSource(state, path.join(root, 'Unknown.hs'), 'p'), undefined);
  state.properties.set('unbound', { id: 'unbound', outcome: 'verified' });
  assert.equal(propertyForSource(state, copy, 'unbound'), undefined);
});

test('two projects with the same property ID keep their own verdicts', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'blaster-two-projects-'));
  const output = path.join(root, 'results');
  for (const [name, outcome] of [['Auction', 'verified'], ['PurposeIsolation', 'falsified']]) {
    const project = path.join(root, name);
    const run = path.join(output, 'projects', name, 'editor-runs', 'run');
    fs.mkdirSync(project);
    fs.mkdirSync(run, { recursive: true });
    const source = path.join(project, 'FormalSpec.hs');
    fs.writeFileSync(source, '{-@ PROPERTY [scope: validator] shared : True @-}\n');
    fs.writeFileSync(path.join(run, 'property-result.json'), JSON.stringify({
      property: 'shared', outcome, source, sourceSha256: sha256File(source)
    }));
  }
  const loaded = mergeResults(collectResultFiles(output));
  assert.equal(propertyForSource(loaded, path.join(root, 'Auction', 'FormalSpec.hs'), 'shared', true).outcome, 'verified');
  assert.equal(propertyForSource(loaded, path.join(root, 'PurposeIsolation', 'FormalSpec.hs'), 'shared', true).outcome, 'falsified');
  assert.equal(propertyForSource(loaded, path.join(root, 'Third', 'FormalSpec.hs'), 'shared', true), undefined);

  fs.writeFileSync(path.join(output, 'verified-assurance.json'), JSON.stringify({
    properties: [{ id: 'unbound', evidence: [{ outcome: 'verified' }] }]
  }));
  const withHistoricalReport = mergeResults(collectResultFiles(output));
  assert.equal(propertyForSource(withHistoricalReport, path.join(root, 'Auction', 'FormalSpec.hs'), 'unbound', true), undefined);
});
