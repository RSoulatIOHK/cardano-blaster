'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { collectNativeReportFiles, readNativeReport } = require('./native');
const { propertyBlocks, sha256File } = require('./results');

const FORMAT = 'cardano-blaster-project-v1';
const NAME = 'cardano-blaster.project.json';

function findProject(source) {
  let directory = path.dirname(path.resolve(source));
  while (true) {
    const file = path.join(directory, NAME);
    if (fs.existsSync(file)) return readProject(file);
    const parent = path.dirname(directory);
    if (parent === directory) return undefined;
    directory = parent;
  }
}

function readProject(file) {
  const config = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (config.format !== FORMAT || typeof config.blueprint !== 'string' ||
      typeof config.assurance !== 'string' || !config.generator ||
      typeof config.generator.command !== 'string' ||
      !Array.isArray(config.generator.args) ||
      !config.generator.args.every((arg) => typeof arg === 'string') ||
      (config.profile !== undefined && !['core', 'cardano-v3', 'cardano-v3-cex'].includes(config.profile)) ||
      (config.sources !== undefined && (!Array.isArray(config.sources) ||
        !config.sources.every((entry) => typeof entry === 'string')))) {
    throw new Error(`Invalid ${NAME}`);
  }
  const directory = path.dirname(path.resolve(file));
  return {
    file: path.resolve(file),
    directory,
    blueprint: path.resolve(directory, config.blueprint),
    assurance: path.resolve(directory, config.assurance),
    sources: (config.sources || []).map((entry) => path.resolve(directory, entry)),
    generator: config.generator,
    profile: config.profile,
    refreshEnvironment: config.refreshEnvironment === true
  };
}

function expand(value, project, source) {
  return value.replaceAll('${projectDir}', project.directory)
    .replaceAll('${sourceFile}', source)
    .replaceAll('${sourceDir}', path.dirname(source));
}

function generatorInvocation(project, source) {
  const spec = project.generator;
  const command = expand(spec.command, project, source);
  const cwd = path.resolve(project.directory, expand(spec.cwd || '.', project, source));
  const environment = {};
  for (const [key, value] of Object.entries(spec.env || {})) {
    if (typeof value !== 'string') throw new Error(`Generator environment ${key} must be a string`);
    environment[key] = expand(value, project, source);
  }
  return {
    command: command.includes(path.sep) ? path.resolve(cwd, command) : command,
    args: spec.args.map((arg) => expand(arg, project, source)),
    cwd,
    env: { ...process.env, ...environment }
  };
}

function runProcess(invocation, onOutput = () => {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(invocation.command, invocation.args, {
      cwd: invocation.cwd, env: invocation.env, shell: false
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (bytes) => { const part = bytes.toString(); stdout += part; onOutput(part); });
    child.stderr.on('data', (bytes) => { const part = bytes.toString(); stderr += part; onOutput(part); });
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
}

async function runFocused(project, source, property, executable, outputRoot, onOutput = () => {}) {
  source = path.resolve(source);
  const sourceText = fs.readFileSync(source, 'utf8');
  if (propertyBlocks(sourceText).filter((block) => block.id === property).length !== 1) {
    throw new Error(`Expected exactly one ${property} annotation in ${source}`);
  }
  const sourceHash = sha256File(source);
  const sourceHashes = Object.fromEntries([source, ...project.sources].map((file) => [file, sha256File(file)]));
  const started = Date.now();
  onOutput(`Generating blueprint and assurance from ${source}\n`);
  const generated = await runProcess(generatorInvocation(project, source), onOutput);
  if (generated.code !== 0) throw new Error(`Generator exited with code ${generated.code}`);
  for (const file of [project.blueprint, project.assurance]) {
    if (!fs.existsSync(file) || fs.statSync(file).mtimeMs < started - 1000) {
      throw new Error(`Generator did not refresh ${file}`);
    }
  }
  const assurance = JSON.parse(fs.readFileSync(project.assurance, 'utf8'));
  if (assurance.properties?.filter((item) => item.id === property).length !== 1) {
    throw new Error(`Generated assurance does not contain exactly one ${property} property`);
  }
  for (const [file, hash] of Object.entries(sourceHashes)) {
    if (sha256File(file) !== hash) throw new Error(`Haskell source changed during generation: ${file}`);
  }
  const output = path.join(outputRoot, 'editor-runs', crypto.randomUUID());
  fs.mkdirSync(output, { recursive: true });
  const args = ['check', project.blueprint, project.assurance, '--property', property, '--output', output];
  if (project.refreshEnvironment) args.push('--refresh-environment');
  if (project.profile) args.push('--profile', project.profile);
  onOutput(`Checking ${property} against compiled UPLC\n`);
  const checked = await runProcess({
    command: executable, args, cwd: project.directory, env: process.env
  }, onOutput);
  const reports = collectNativeReportFiles(output);
  if (reports.length !== 1) throw new Error(`cardano-blaster exited with code ${checked.code}; expected one native report, found ${reports.length}`);
  if (![0, 1, 2].includes(checked.code)) {
    const failure = JSON.parse(fs.readFileSync(reports[0], 'utf8'));
    throw new Error(`cardano-blaster: ${failure.error || `exit code ${checked.code}`} (report: ${reports[0]})`);
  }
  const report = readNativeReport(reports[0]);
  for (const [file, hash] of Object.entries(sourceHashes)) {
    if (sha256File(file) !== hash) throw new Error(`Haskell source changed during verification: ${file}`);
  }
  const result = report.results.find((item) => item.property === property);
  if (!result) throw new Error(`Native report has no result for ${property}`);
  const sidecar = {
    property,
    outcome: result.outcome,
    method: 'Blaster SMT and compiled UPLC replay',
    date: new Date().toISOString(),
    source,
    sourceSha256: sourceHash,
    sourceHashes,
    nativeReport: report.file,
    nativeReportSha256: sha256File(report.file),
    haskellFile: result.sourceFile,
    counterexample: Object.fromEntries(result.inputs.map((input) =>
      [input.name, input.sourceType || input.expression])),
    structuredCounterexample: { replay: { status: result.replay } },
    log: path.join(path.dirname(report.file), 'verification.log')
  };
  const sidecarFile = path.join(path.dirname(report.file), 'property-result.json');
  fs.writeFileSync(sidecarFile, `${JSON.stringify(sidecar, null, 2)}\n`);
  return { report, result, sidecar, sidecarFile };
}

module.exports = { findProject, generatorInvocation, readProject, runFocused, runProcess };
