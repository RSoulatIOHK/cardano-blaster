#!/usr/bin/env node
'use strict';

// Project generator for the Plutus UAL examples. Rebuild first so an edited
// FormalSpec.hs or on-chain module cannot be checked against an old executable.
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const [target, exampleDir, compiler, bundleDir] = process.argv.slice(2);
if (!target || !exampleDir) {
  process.stderr.write('usage: generate-plutus-ual.js CABAL_TARGET EXAMPLE_DIR [GHC_PATH] [BUNDLE_DIR]\n');
  process.exit(2);
}

let root = path.resolve(exampleDir);
while (!fs.existsSync(path.join(root, 'cabal.assurance.project'))) {
  const parent = path.dirname(root);
  if (parent === root) {
    process.stderr.write(`Cannot find cabal.assurance.project above ${exampleDir}\n`);
    process.exit(2);
  }
  root = parent;
}
const example = path.resolve(exampleDir);
const environment = path.join(example, 'environment.json');
const cabal = process.env.BLASTER_CABAL || 'cabal';
const bundle = bundleDir ? path.resolve(bundleDir) : example;
fs.mkdirSync(bundle, { recursive: true });
if (fs.existsSync(environment)) {
  if (bundle !== example) fs.copyFileSync(environment, path.join(bundle, 'environment.json'));
} else {
  const manifest = path.join(example, 'cardano-blaster.project.json');
  if (!fs.existsSync(manifest)) {
    process.stderr.write(`Missing ${environment} and ${manifest}\n`);
    process.exit(2);
  }
  const profile = JSON.parse(fs.readFileSync(manifest, 'utf8')).profile;
  const imports = {
    core: ['PlutusCore.UPLC.BlueprintEncoding.Assurance'],
    'cardano-v3': ['PlutusCore.UPLC.BlueprintEncoding.Assurance', 'CardanoLedgerApi.V3'],
    'cardano-v3-cex': ['PlutusCore.UPLC.BlueprintEncoding.Assurance', 'CardanoLedgerApi.V3']
  }[profile];
  if (!imports) {
    process.stderr.write(`Cannot generate environment.json for profile ${profile}\n`);
    process.exit(2);
  }
  fs.writeFileSync(path.join(bundle, 'environment.json'), `${JSON.stringify({
    format: 'illustrative-unpinned-environment',
    requiredImports: imports,
    description: 'Bootstrap reference only; cardano-blaster captures the actual checking environment before verification.'
  }, null, 2)}\n`);
}
const flags = [`--project-file=${path.join(root, 'cabal.assurance.project')}`];
if (compiler) flags.push(`--with-compiler=${compiler}`);

function run(command, args, cwd) {
  return new Promise((resolve, reject) => {
    process.stdout.write(`$ ${command} ${args.join(' ')}\n`);
    const child = spawn(command, args, { cwd, env: process.env, shell: false });
    let stdout = '';
    child.stdout.on('data', (data) => { stdout += data.toString(); process.stdout.write(data); });
    child.stderr.on('data', (data) => process.stderr.write(data));
    child.on('error', reject);
    child.on('close', (code) => code === 0 ? resolve(stdout) : reject(new Error(`${command} exited with code ${code}`)));
  });
}

async function main() {
  await run(cabal, ['build', ...flags, target], root);
  const binary = (await run(cabal, ['list-bin', ...flags, target], root)).trim().split(/\r?\n/).at(-1);
  if (!binary || !fs.existsSync(binary)) throw new Error(`Cabal did not return an executable for ${target}`);
  await run(binary, ['environment.json'], bundle);
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
