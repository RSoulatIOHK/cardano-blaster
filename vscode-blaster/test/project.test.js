'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { findProject, generatorInvocation, projectResultsRoot, runFocused, runProcess } = require('../src/project');
const { collectResultFiles, mergeResults, propertyForSource, sourceState } = require('../src/results');

test('checks a Haskell property through its project generator and binds the native CEX to that source', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'blaster-project-'));
  const source = path.join(root, 'src', 'FormalSpec.hs');
  const contract = path.join(root, 'src', 'OnChain.hs');
  fs.mkdirSync(path.dirname(source));
  fs.writeFileSync(source, '{-@ PROPERTY [scope: auction] wrong_bid : False @-}\n');
  fs.writeFileSync(contract, 'module OnChain where\n');
  const generator = path.join(root, 'generate.js');
  fs.writeFileSync(generator, `
const fs = require('node:fs');
const path = require('node:path');
const root = process.cwd();
if (!fs.readFileSync(process.argv[2], 'utf8').includes('wrong_bid')) process.exit(3);
fs.writeFileSync(path.join(root, 'plutus.json'), '{}');
fs.writeFileSync(path.join(root, 'assurance.json'), JSON.stringify({properties: [{id:'wrong_bid'}]}));
`);
  const checker = path.join(root, 'fake-checker');
  fs.writeFileSync(checker, `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
if (args[0] !== 'check' || args[args.indexOf('--property') + 1] !== 'wrong_bid' ||
    args[args.indexOf('--profile') + 1] !== 'cardano-v3-cex') process.exit(3);
const run = path.join(args[args.indexOf('--output') + 1], 'run');
fs.mkdirSync(path.join(run, 'counterexamples'), {recursive: true});
const source = 'main = print "ctx"\\n';
const crypto = require('node:crypto');
fs.writeFileSync(path.join(run, 'counterexamples', 'Counterexample0.hs'), source);
const digest = crypto.createHash('sha256').update(source).digest('hex');
fs.writeFileSync(path.join(run, 'report.json'), JSON.stringify({
  format:'cardano-blaster-check-v1', results:[{property:'wrong_bid',outcome:'falsified',
  counterexample:{replay:{status:'confirmed'},source:{status:'exported',
  file:{uri:'counterexamples/Counterexample0.hs',hash:{alg:'sha256',digest}},
  inputs:[{name:'ctx',sourceType:'V3.ScriptContext'}]}}}]
}));
process.exit(1);
`);
  fs.chmodSync(checker, 0o755);
  fs.writeFileSync(path.join(root, 'cardano-blaster.project.json'), JSON.stringify({
    format: 'cardano-blaster-project-v1',
    blueprint: 'plutus.json',
    assurance: 'assurance.json',
    sources: ['src/OnChain.hs'],
    profile: 'cardano-v3-cex',
    generator: { command: process.execPath, args: ['${projectDir}/generate.js', '${sourceFile}'] }
  }));
  const project = findProject(source);
  assert.equal(project.directory, root);
  const output = path.join(root, 'results');
  const checked = await runFocused(project, source, 'wrong_bid', checker, output);
  assert.equal(checked.result.outcome, 'falsified');
  assert.equal(checked.result.replay, 'confirmed');
  assert.equal(checked.sidecar.source, source);
  const loaded = mergeResults(collectResultFiles(output));
  const property = propertyForSource(loaded, source, 'wrong_bid');
  assert.equal(property.outcome, 'falsified');
  assert.equal(property.counterexample.ctx, 'V3.ScriptContext');
  assert.equal(property.counterexampleTypes.ctx, 'V3.ScriptContext');
  assert.equal(sourceState(source, loaded.sourceHashes, undefined, property).stale, false);
  const manifest = fs.readFileSync(project.file, 'utf8');
  fs.appendFileSync(project.file, ' ');
  assert.equal(sourceState(source, loaded.sourceHashes, undefined, property).stale, true);
  fs.writeFileSync(project.file, manifest);
  assert.equal(sourceState(source, loaded.sourceHashes, undefined, property).stale, false);
  fs.appendFileSync(contract, '-- modified contract\n');
  assert.equal(sourceState(source, loaded.sourceHashes, undefined, property).stale, true);
  assert.match(sourceState(source, loaded.sourceHashes, undefined, property).reason, /OnChain.hs/);
  fs.appendFileSync(source, '-- edited\n');
  assert.equal(sourceState(source, loaded.sourceHashes, undefined, property).stale, true);
  assert.equal(propertyForSource(loaded, path.join(root, 'Unrelated.hs'), 'wrong_bid'), undefined);
  fs.writeFileSync(checker, fs.readFileSync(checker, 'utf8')
    .replace("format:'cardano-blaster-check-v1'", "error:'property not found: modules',format:'cardano-blaster-check-v1'")
    .replace('process.exit(1);', 'process.exit(3);'));
  await assert.rejects(runFocused(project, source, 'wrong_bid', checker, output),
    /cardano-blaster: property not found: modules \(report:/);
});

test('Plutus generator builds before running and writes to an isolated bundle directory', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'blaster-cabal-'));
  fs.writeFileSync(path.join(root, 'cabal.assurance.project'), 'packages: .\n');
  const example = path.join(root, 'example');
  const bundle = path.join(example, '.local', 'cardano-blaster');
  fs.mkdirSync(example);
  fs.writeFileSync(path.join(example, 'environment.json'), '{}');
  const producer = path.join(root, 'producer');
  fs.writeFileSync(producer, `#!${process.execPath}\nconst fs=require('node:fs');if(!fs.existsSync('${root}/built')) process.exit(4);if(!fs.existsSync('environment.json')) process.exit(5);fs.writeFileSync('plutus.json','{}');fs.writeFileSync('assurance.json','{}');`);
  fs.chmodSync(producer, 0o755);
  const cabal = path.join(root, 'fake-cabal');
  fs.writeFileSync(cabal, `#!${process.execPath}\nconst fs=require('node:fs');if(process.argv[2]==='build')fs.writeFileSync('${root}/built','yes');else if(process.argv[2]==='list-bin')console.log('${producer}');else process.exit(3);`);
  fs.chmodSync(cabal, 0o755);
  const result = await runProcess({
    command: process.execPath,
    args: [path.resolve(__dirname, '../scripts/generate-plutus-ual.js'), 'example:exe:producer', example, '', bundle],
    cwd: root,
    env: { ...process.env, BLASTER_CABAL: cabal }
  });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(fs.existsSync(path.join(bundle, 'plutus.json')), true);
  assert.equal(fs.existsSync(path.join(example, 'plutus.json')), false);
});

test('generator paths are portable and project result directories do not collide', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'blaster-multiproject-'));
  const projects = ['Auction', 'PurposeIsolation'].map((name) => {
    const directory = path.join(root, name);
    fs.mkdirSync(directory);
    const file = path.join(directory, 'cardano-blaster.project.json');
    fs.writeFileSync(file, JSON.stringify({
      format: 'cardano-blaster-project-v1', blueprint: 'plutus.json', assurance: 'assurance.json',
      generator: { command: 'node', args: ['${extensionDir}/scripts/generate-plutus-ual.js',
        '${sourceFile}', '${ghcPath}'], env: { BLASTER_CABAL: '${cabalPath}' } }
    }));
    return findProject(path.join(directory, 'FormalSpec.hs'));
  });
  const [auction, purpose] = projects;
  assert.notEqual(projectResultsRoot(path.join(root, 'results'), auction),
    projectResultsRoot(path.join(root, 'results'), purpose));
  const invocation = generatorInvocation(auction, path.join(auction.directory, 'FormalSpec.hs'), {
    extensionDir: '/installed/extension', ghcPath: '/toolchain/ghc', cabalPath: '/toolchain/cabal'
  });
  assert.deepEqual(invocation.args, ['/installed/extension/scripts/generate-plutus-ual.js',
    path.join(auction.directory, 'FormalSpec.hs'), '/toolchain/ghc']);
  assert.equal(invocation.env.BLASTER_CABAL, '/toolchain/cabal');
  assert.throws(() => generatorInvocation(auction, 'FormalSpec.hs'), /extensionDir.*unavailable/);
});
