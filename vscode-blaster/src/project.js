'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { collectNativeReportFiles, readNativeReport } = require('./native');
const { propertyBlocks, sha256File } = require('./results');

const FORMAT = 'cardano-blaster-project-v1';
const NAME = 'cardano-blaster.project.json';

function within(directory, file) {
  const relative = path.relative(directory, file);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

function cabalFields(lines) {
  const fields = new Map();
  let current;
  for (const line of lines) {
    const match = /^\s+([A-Za-z][\w-]*):\s*(.*?)\s*$/.exec(line);
    if (match) {
      current = match[1];
      fields.set(current, match[2]);
    } else if (current && /^\s+\S/.test(line) && !/^\s*--/.test(line)) {
      fields.set(current, `${fields.get(current)} ${line.trim()}`);
    }
  }
  return fields;
}

function cabalExecutables(file) {
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  const packageName = /^name:\s*(\S+)/mi.exec(lines.join('\n'))?.[1];
  if (!packageName) return [];
  const executables = [];
  for (let i = 0; i < lines.length; i++) {
    const match = /^executable\s+(\S+)\s*(?:--.*)?$/i.exec(lines[i]);
    if (!match) continue;
    const body = [];
    while (++i < lines.length && (!/^\S/.test(lines[i]) || /^\s*--/.test(lines[i]))) body.push(lines[i]);
    i--;
    const fields = cabalFields(body);
    const main = fields.get('main-is');
    if (!main || !/\.hs$/.test(main)) continue;
    const roots = (fields.get('hs-source-dirs') || '.').split(/\s+/).filter(Boolean);
    for (const root of roots) {
      const sourceRoot = path.resolve(path.dirname(file), root);
      const mainFile = path.resolve(sourceRoot, main);
      if (fs.existsSync(mainFile)) executables.push({
        target: `${packageName}:exe:${match[1]}`, mainFile, sourceRoot,
        otherModules: (fields.get('other-modules') || '').split(/\s+/).filter(Boolean),
        cabalFile: file
      });
    }
  }
  return executables;
}

function haskellFiles(directory) {
  const found = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) found.push(...haskellFiles(file));
    else if (entry.isFile() && entry.name.endsWith('.hs')) found.push(file);
  }
  return found;
}

// This convention is specific to Plutus UAL bundle-producing Cabal executables.
// Other Haskell projects still need to provide their own generator recipe.
function inferPlutusProject(source) {
  source = path.resolve(source);
  let directory = path.dirname(source);
  const cabalFiles = [];
  while (true) {
    cabalFiles.push(...fs.readdirSync(directory).filter((name) => name.endsWith('.cabal'))
      .map((name) => path.join(directory, name)));
    if (fs.existsSync(path.join(directory, 'cabal.assurance.project'))) break;
    const parent = path.dirname(directory);
    if (parent === directory) return undefined;
    directory = parent;
  }
  const candidates = cabalFiles.flatMap(cabalExecutables).filter(({ mainFile }) => {
    const projectDir = path.dirname(mainFile);
    return within(projectDir, source) &&
      fs.existsSync(path.join(projectDir, 'environment.json')) &&
      /\bwriteInterfaceBundle(?:With[A-Za-z0-9_]*)?\b/.test(fs.readFileSync(mainFile, 'utf8'));
  });
  if (!candidates.length) return undefined;
  candidates.sort((a, b) => path.dirname(b.mainFile).length - path.dirname(a.mainFile).length);
  const best = candidates[0];
  if (candidates[1] && path.dirname(candidates[1].mainFile) === path.dirname(best.mainFile)) {
    throw new Error(`Multiple Cabal executables produce a UAL bundle for ${source}; add ${NAME} explicitly`);
  }
  const projectDir = path.dirname(best.mainFile);
  const moduleFiles = best.otherModules.map((name) =>
    path.join(best.sourceRoot, ...name.split('.')) + '.hs').filter((file) => fs.existsSync(file));
  const sources = [...new Set([...haskellFiles(projectDir), ...moduleFiles,
    best.cabalFile, path.join(projectDir, 'environment.json')])]
    .map((file) => path.relative(projectDir, file)).sort();
  const requiredImports = JSON.parse(fs.readFileSync(path.join(projectDir, 'environment.json'), 'utf8')).requiredImports || [];
  const profile = requiredImports.includes('CardanoLedgerApi.V3') ? 'cardano-v3-cex' : 'core';
  return {
    directory: projectDir,
    config: {
      format: FORMAT,
      blueprint: '.local/cardano-blaster/plutus.json',
      assurance: '.local/cardano-blaster/assurance.json',
      sources,
      profile,
      refreshEnvironment: true,
      generator: {
        command: 'node',
        args: ['${extensionDir}/scripts/generate-plutus-ual.js', best.target,
          '${projectDir}', '${ghcPath}', '${projectDir}/.local/cardano-blaster'],
        env: { BLASTER_CABAL: '${cabalPath}' }
      }
    }
  };
}

function createInferredProject(source) {
  const inferred = inferPlutusProject(source);
  if (!inferred) return undefined;
  const file = path.join(inferred.directory, NAME);
  try {
    fs.writeFileSync(file, `${JSON.stringify(inferred.config, null, 2)}\n`, { flag: 'wx' });
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }
  return readProject(file);
}

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

function expand(value, project, source, runtime = {}) {
  const variables = {
    projectDir: project.directory,
    sourceFile: source,
    sourceDir: path.dirname(source),
    extensionDir: runtime.extensionDir,
    ghcPath: runtime.ghcPath || 'ghc',
    cabalPath: runtime.cabalPath || 'cabal'
  };
  return value.replace(/\$\{([^}]+)\}/g, (match, name) => {
    if (!(name in variables)) throw new Error(`Unknown generator variable ${match}`);
    if (!variables[name]) throw new Error(`Generator variable ${match} is unavailable`);
    return variables[name];
  });
}

function generatorInvocation(project, source, runtime = {}) {
  const spec = project.generator;
  const command = expand(spec.command, project, source, runtime);
  const cwd = path.resolve(project.directory, expand(spec.cwd || '.', project, source, runtime));
  const environment = {};
  for (const [key, value] of Object.entries(spec.env || {})) {
    if (typeof value !== 'string') throw new Error(`Generator environment ${key} must be a string`);
    environment[key] = expand(value, project, source, runtime);
  }
  return {
    command: command.includes(path.sep) ? path.resolve(cwd, command) : command,
    args: spec.args.map((arg) => expand(arg, project, source, runtime)),
    cwd,
    env: { ...process.env, ...runtime.environment, ...environment }
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

function projectResultsRoot(outputRoot, project) {
  const key = crypto.createHash('sha256').update(project.file).digest('hex').slice(0, 16);
  return path.join(outputRoot, 'projects', `${path.basename(project.directory)}-${key}`);
}

async function runFocused(project, source, property, executable, outputRoot, onOutput = () => {}, runtime = {}) {
  source = path.resolve(source);
  const sourceText = fs.readFileSync(source, 'utf8');
  if (propertyBlocks(sourceText).filter((block) => block.id === property).length !== 1) {
    throw new Error(`Expected exactly one ${property} annotation in ${source}`);
  }
  const sourceHash = sha256File(source);
  const sourceHashes = Object.fromEntries([source, project.file, ...project.sources]
    .map((file) => [file, sha256File(file)]));
  const started = Date.now();
  onOutput(`Generating blueprint and assurance from ${source}\n`);
  const generated = await runProcess(generatorInvocation(project, source, runtime), onOutput);
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
    counterexampleTypes: Object.fromEntries(result.inputs.filter((input) => input.sourceType)
      .map((input) => [input.name, input.sourceType])),
    structuredCounterexample: { replay: { status: result.replay } },
    log: path.join(path.dirname(report.file), 'verification.log')
  };
  const sidecarFile = path.join(path.dirname(report.file), 'property-result.json');
  fs.writeFileSync(sidecarFile, `${JSON.stringify(sidecar, null, 2)}\n`);
  return { report, result, sidecar, sidecarFile };
}

module.exports = { createInferredProject, findProject, generatorInvocation, inferPlutusProject,
  projectResultsRoot, readProject, runFocused, runProcess };
