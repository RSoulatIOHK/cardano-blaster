'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const FORMAT = 'cardano-blaster-check-v1';

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function withinRun(run, uri) {
  if (typeof uri !== 'string' || !uri || path.isAbsolute(uri)) {
    throw new Error('Counterexample file must have a relative URI');
  }
  const file = path.resolve(run, uri);
  const relative = path.relative(run, file);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error('Counterexample file escapes the report directory');
  }
  if (fs.existsSync(file)) {
    const realRun = fs.realpathSync(run);
    const realFile = fs.realpathSync(file);
    const realRelative = path.relative(realRun, realFile);
    if (realRelative === '..' || realRelative.startsWith(`..${path.sep}`) || path.isAbsolute(realRelative)) {
      throw new Error('Counterexample file escapes the report directory through a symlink');
    }
  }
  return file;
}

function readNativeReport(file) {
  const document = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (document.format !== FORMAT || !Array.isArray(document.results)) {
    throw new Error('Not a cardano-blaster check report');
  }
  const run = path.dirname(path.resolve(file));
  const results = document.results.map((result) => {
    const source = result.counterexample?.source;
    const exported = result.outcome === 'falsified' &&
      result.counterexample?.replay?.status === 'confirmed' &&
      source?.status === 'exported' && source.file?.uri;
    if (exported && source.file.hash?.alg !== 'sha256') {
      throw new Error('Counterexample source has no SHA-256 digest');
    }
    return {
      property: result.property,
      outcome: result.outcome,
      replay: result.counterexample?.replay?.status,
      sourceStatus: source?.status,
      sourceReason: source?.reason,
      sourceFile: exported ? withinRun(run, source.file.uri) : undefined,
      sourceHash: exported ? source.file.hash?.digest : undefined,
      inputs: Array.isArray(source?.inputs) ? source.inputs : []
    };
  });
  return {
    file: path.resolve(file),
    created: document.created,
    inputs: document.inputs || {},
    results
  };
}

function collectNativeReportFiles(root) {
  if (!root || !fs.existsSync(root)) return [];
  const found = [];
  const visit = (entry) => {
    const stat = fs.statSync(entry);
    if (stat.isDirectory()) {
      for (const child of fs.readdirSync(entry)) visit(path.join(entry, child));
    } else if (path.basename(entry) === 'report.json') {
      found.push(entry);
    }
  };
  visit(root);
  return found.sort();
}

function loadNativeReports(files) {
  const reports = [];
  const errors = [];
  for (const file of files) {
    try {
      reports.push(readNativeReport(file));
    } catch (error) {
      errors.push({ file, message: error.message });
    }
  }
  return { reports, errors };
}

function counterexamples(reports) {
  return reports.flatMap((report) => report.results
    .filter((result) => result.sourceFile)
    .map((result) => ({ ...result, report })));
}

function fileState(file, expectedHash) {
  if (!file || !fs.existsSync(file)) return { available: false, matches: false };
  const matches = typeof expectedHash === 'string' &&
    sha256(file) === expectedHash.toLowerCase();
  return { available: true, matches };
}

function inputState(report) {
  const changed = [];
  for (const [file, hash] of Object.entries(report.inputs)) {
    if (!fileState(file, hash).matches) changed.push(file);
  }
  return changed;
}

module.exports = {
  collectNativeReportFiles,
  counterexamples,
  fileState,
  inputState,
  loadNativeReports,
  readNativeReport
};
