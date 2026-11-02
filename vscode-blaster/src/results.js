'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const PROPERTY = /\{-@\s*PROPERTY(?:\s+\[[^\]]*\])*\s+([A-Za-z_][A-Za-z0-9_'.-]*)[\s\S]*?@-\}/g;

function propertyBlocks(text) {
  const lines = [0];
  for (let i = 0; i < text.length; i += 1) {
    if (text.charCodeAt(i) === 10) lines.push(i + 1);
  }
  const at = (offset) => {
    let low = 0;
    let high = lines.length;
    while (low + 1 < high) {
      const middle = (low + high) >> 1;
      if (lines[middle] <= offset) low = middle;
      else high = middle;
    }
    return { line: low, character: offset - lines[low] };
  };
  return [...text.matchAll(PROPERTY)].map((match) => {
    const idOffset = match.index + match[0].indexOf(match[1]);
    return {
      id: match[1],
      start: at(match.index),
      idStart: at(idOffset),
      idEnd: at(idOffset + match[1].length),
      end: at(match.index + match[0].length)
    };
  });
}

function evidenceStatus(property) {
  const evidence = Array.isArray(property.evidence) ? property.evidence : [];
  if (evidence.length === 0) return { outcome: 'unchecked', label: 'No verification evidence' };
  const preferred = evidence.find((item) => item.outcome && item.outcome !== 'verified') || evidence[0];
  const outcome = String(preferred.outcome || 'unchecked').toLowerCase();
  return {
    outcome,
    label: outcome === 'verified' ? 'Verified by Blaster' : `Blaster: ${outcome}`,
    method: preferred.method,
    date: preferred.date,
    notes: preferred.notes,
    scriptHash: preferred.scriptHash
  };
}

function readResult(file) {
  const document = JSON.parse(fs.readFileSync(file, 'utf8'));
  const properties = new Map();
  if (path.basename(file) === 'property-result.json') {
    if (typeof document.property !== 'string' || typeof document.sourceSha256 !== 'string') {
      throw new Error('Invalid focused property result');
    }
    properties.set(document.property, {
      id: document.property,
      outcome: document.outcome,
      label: document.outcome === 'verified' ? 'Verified by Blaster' : `Blaster: ${document.outcome}`,
      method: document.method,
      date: document.date,
      notes: document.reusedCompiledCode ? 'Reused compiled UPLC from a source-matched verified bundle.' : undefined,
      counterexample: document.counterexample || {},
      replay: document.structuredCounterexample && document.structuredCounterexample.replay,
      haskell: document.haskell,
      resultFile: file,
      logFile: document.log,
      source: path.resolve(document.source),
      sourceHash: document.sourceSha256.toLowerCase()
    });
    return { properties, sourceHashes: new Map() };
  }
  for (const property of document.properties || []) {
    if (!property || typeof property.id !== 'string') continue;
    properties.set(property.id, {
      id: property.id,
      statement: property.statement,
      scope: property.scope,
      resultFile: file,
      ...evidenceStatus(property)
    });
  }
  const sourceHashes = new Map();
  const reportFile = path.join(path.dirname(file), 'run-report.json');
  if (fs.existsSync(reportFile)) {
    const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
    const sources = report.provenance && report.provenance.sources;
    if (sources && typeof sources === 'object') {
      for (const [source, hash] of Object.entries(sources)) {
        if (hash && hash.alg === 'sha256' && typeof hash.digest === 'string') {
          sourceHashes.set(path.resolve(source), hash.digest.toLowerCase());
        }
      }
    }
  }
  return { properties, sourceHashes };
}

function collectResultFiles(root) {
  const found = [];
  if (!root || !fs.existsSync(root)) return found;
  const visit = (entry) => {
    const stat = fs.statSync(entry);
    if (stat.isDirectory()) {
      for (const child of fs.readdirSync(entry)) visit(path.join(entry, child));
    } else if (['verified-assurance.json', 'property-result.json'].includes(path.basename(entry))) {
      found.push(entry);
    }
  };
  visit(root);
  return found.sort((a, b) => {
    const aFocused = path.basename(a) === 'property-result.json';
    const bFocused = path.basename(b) === 'property-result.json';
    return Number(aFocused) - Number(bFocused) || a.localeCompare(b);
  });
}

function mergeResults(files) {
  const properties = new Map();
  const sourceHashes = new Map();
  const bySource = new Map();
  const errors = [];
  for (const file of files) {
    try {
      const result = readResult(file);
      for (const [id, property] of result.properties) properties.set(id, property);
      for (const [source, hash] of result.sourceHashes) {
        if (!source.endsWith('.hs') || !fs.existsSync(source)) continue;
        const ids = propertyBlocks(fs.readFileSync(source, 'utf8')).map((block) => block.id);
        const bound = bySource.get(source) || new Map();
        for (const id of ids) {
          const property = result.properties.get(id);
          if (property) bound.set(id, { ...property, source, sourceHash: hash });
        }
        bySource.set(source, bound);
      }
      for (const [id, property] of result.properties) {
        if (!property.source) continue;
        const bound = bySource.get(property.source) || new Map();
        bound.set(id, property);
        bySource.set(property.source, bound);
      }
      for (const [source, hash] of result.sourceHashes) sourceHashes.set(source, hash);
    } catch (error) {
      errors.push({ file, message: error.message });
    }
  }
  const allProperties = [...bySource.values()].flatMap((bound) => [...bound.values()]);
  const boundIds = new Set(allProperties.map((property) => property.id));
  for (const property of properties.values()) {
    if (!boundIds.has(property.id)) allProperties.push(property);
  }
  return { properties, bySource, allProperties, sourcedIds: boundIds, sourceHashes, errors, files };
}

function propertyForSource(state, source, id) {
  const resolved = path.resolve(source);
  const bound = state.bySource.get(resolved);
  if (bound) return bound.get(id);
  // A result bound to another file must not label an annotation copy by ID.
  if (state.sourcedIds.has(id)) return undefined;
  return state.properties.get(id);
}

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function sourceState(file, sourceHashes, text, property) {
  const resolved = path.resolve(file);
  if (property && property.source && property.source !== resolved) {
    return { tracked: false, stale: true, reason: 'Blaster result belongs to a different source file.' };
  }
  const expected = property && property.source === resolved
    ? property.sourceHash : sourceHashes.get(resolved);
  if (!expected) return { tracked: false, stale: false };
  const actual = text === undefined ? sha256File(file)
    : crypto.createHash('sha256').update(text).digest('hex');
  return { tracked: true, stale: actual !== expected, expected, actual };
}

module.exports = {
  collectResultFiles,
  evidenceStatus,
  mergeResults,
  propertyBlocks,
  propertyForSource,
  readResult,
  sha256File,
  sourceState
};
