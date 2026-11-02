#!/usr/bin/env python3
"""Rebuild one UAL example and check one property with the current Haskell source.

Run inside the matching Lean project's `lake env` and Plutus's GHC 9.6 shell.
The focused result is a local editor result, not a release assurance artifact.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(command, cwd, env, timeout=1800):
    print('Running', ' '.join(map(str, command)), flush=True)
    return subprocess.run([str(part) for part in command], cwd=cwd, env=env,
                          text=True, capture_output=True, timeout=timeout)


def write_json(path, document):
    path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + '\n')


def parse_verdict(log, property_id, exit_code):
    if re.search(r"Property '" + re.escape(property_id) + r"': verified", log):
        return 'verified'
    if re.search(r"Property '" + re.escape(property_id) + r"': falsified", log):
        return 'falsified'
    if re.search(r"Property '" + re.escape(property_id) + r"': inconclusive", log):
        return 'inconclusive'
    return 'error' if exit_code else 'unchecked'


def parse_counterexample(log):
    if 'Counterexample:' not in log:
        return {}
    tail = log.split('Counterexample:', 1)[1]
    result = {}
    for line in tail.splitlines():
        match = re.search(r'error:\s+-\s+([^:]+):\s*(.*)$', line)
        if match:
            result[match.group(1).strip()] = match.group(2).strip()
        elif result:
            break
    return result


def property_block(source, property_id):
    pattern = re.compile(r'\{-@\s*PROPERTY(?:\s+\[[^\]]*\])*\s+' +
                         re.escape(property_id) + r'\b[\s\S]*?@-\}')
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        raise ValueError(f'Expected one PROPERTY block for {property_id!r}, found {len(matches)}')
    return matches[0]


def formal_source(block):
    separator = re.search(r'(?m)^\s*:\s*', block)
    if not separator:
        raise ValueError('PROPERTY block has no formal proposition')
    return block[separator.end():block.rfind('@-}')].strip()


def reuse_verified_bundle(args, repo, env, lean, header):
    baseline = args.reuse_bundle.resolve(strict=True)
    report = json.loads((baseline / 'run-report.json').read_text())
    if report.get('status') != 'verified':
        raise ValueError('Baseline bundle has no successful run report')
    sources = report['provenance']['sources']
    selected = str(args.source)
    if selected not in sources:
        raise ValueError('The selected Haskell source is absent from baseline provenance')
    for source, record in sources.items():
        if source == selected or not source.endswith(('.hs', '/CardanoLedgerApi/Examples/Auction.lean',
                                                    '/PlutusCore/UPLC/BlueprintEncoding/Assurance.lean')):
            continue
        if not Path(source).is_file() or digest(source) != record['digest']:
            raise ValueError(f'Compiled code or checking model changed: {source}; rebuild first')
    rel = args.source.relative_to(args.plutus)
    commit = report['provenance']['repositories']['plutus']['commit']
    previous = subprocess.check_output(['git', 'show', commit + ':' + rel.as_posix()],
                                       cwd=args.plutus, text=True)
    if hashlib.sha256(previous.encode()).hexdigest() != sources[selected]['digest']:
        raise ValueError('Baseline FormalSpec source differs from its recorded revision; rebuild first')
    current = args.source.read_text()
    before = property_block(previous, args.property)
    after = property_block(current, args.property)
    if previous[:before.start()] + previous[before.end():] != current[:after.start()] + current[after.end():]:
        raise ValueError('Other annotations or Haskell code changed; rebuild first')
    for filename in ['assurance.json', 'plutus.json', 'environment.json']:
        shutil.copy2(baseline / filename, args.output / filename)
    assurance = json.loads((args.output / 'assurance.json').read_text())
    selected_properties = [p for p in assurance['properties'] if p['id'] == args.property]
    if len(selected_properties) != 1:
        raise ValueError('Selected property is absent from the verified baseline')
    for ref in assurance.get('checkingContexts', {}).values():
        shutil.copy2(baseline / ref['uri'], args.output / ref['uri'])
    selected_properties[0]['statement']['formal']['source'] = formal_source(after.group())
    assurance['properties'] = selected_properties
    claim_file = args.output / 'claim.json'
    write_json(claim_file, assurance)
    return claim_file, report.get('generatorHash', {}).get('digest')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plutus', type=Path, required=True)
    parser.add_argument('--core', type=Path, required=True)
    parser.add_argument('--ledger', type=Path, required=True)
    parser.add_argument('--z3', type=Path, required=True)
    parser.add_argument('--ghc', default='ghc')
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--property', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--reuse-bundle', type=Path,
                        help='Reuse compiled UPLC only if every other relevant source matches a verified run')
    args = parser.parse_args()
    args.source = args.source.resolve(strict=True)
    args.plutus = args.plutus.resolve(strict=True)
    args.core = args.core.resolve(strict=True)
    args.ledger = args.ledger.resolve(strict=True)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)

    example = args.source.parent.name.lower()
    if example not in {'auction', 'recursive', 'game', 'parameters'}:
        parser.error('Focused replay supports Auction, Recursive, Game and Parameters examples')
    property_block(args.source.read_text(), args.property)
    result_file = args.output / 'property-result.json'
    result_file.unlink(missing_ok=True)
    env = os.environ.copy()
    env['PATH'] = str(args.z3.resolve(strict=True).parent) + os.pathsep + env['PATH']
    env['PYTHONDONTWRITEBYTECODE'] = '1'

    repo = args.ledger if example == 'auction' else args.core
    sys.path.insert(0, str(args.core / 'Tests/BlueprintVerify'))
    from runtime import lean_command
    lean = lean_command()
    # lean_command discovers the native Blaster library and exports its path.
    # The manifest pins that library, so pass the updated environment to Lean.
    if os.environ.get('ASSURANCE_NATIVE_LIBRARY'):
        env['ASSURANCE_NATIVE_LIBRARY'] = os.environ['ASSURANCE_NATIVE_LIBRARY']
    header = 'import PlutusCore.UPLC.BlueprintEncoding.Assurance\n'
    if example == 'auction':
        header += '''import CardanoLedgerApi.V3
open PlutusCore.ByteString
open PlutusCore.Integer
open PlutusCore.Data (Data)
open CardanoLedgerApi.IsData.Class
open CardanoLedgerApi.V3
open CardanoLedgerApi.V3.Contexts
open CardanoLedgerApi.V3.Tx
'''
    if args.reuse_bundle:
        if example != 'auction':
            parser.error('Verified bundle reuse currently supports Auction only')
        claim_file, generator_hash = reuse_verified_bundle(args, repo, env, lean, header)
    else:
        project = '--project-file=cabal.assurance.project'
        target = f'docusaurus-examples:exe:example-ual-{example}'
        build = run(['cabal', 'build', project, '--with-compiler=' + args.ghc, target], args.plutus, env, 7200)
        (args.output / 'build.log').write_text(build.stdout + build.stderr)
        if build.returncode:
            print(build.stdout + build.stderr, file=sys.stderr)
            return 2
        binary = run(['cabal', 'list-bin', project, '--with-compiler=' + args.ghc, target], args.plutus, env)
        if binary.returncode:
            print(binary.stderr, file=sys.stderr)
            return 2
        generator = Path(binary.stdout.strip()).resolve(strict=True)
        generator_hash = digest(generator)
        environment_file = args.output / 'environment.json'
        driver = args.output / 'Environment.lean'
        driver.write_text(header + '#write_checking_environment ' + json.dumps(str(environment_file)) + '\n')
        captured = run(lean + [driver], repo, env)
        (args.output / 'environment.log').write_text(captured.stdout + captured.stderr)
        if captured.returncode:
            print(captured.stdout + captured.stderr, file=sys.stderr)
            return 2
        generated = run([generator, environment_file.name], args.output, env)
        (args.output / 'generator.log').write_text(generated.stdout + generated.stderr)
        if generated.returncode:
            print(generated.stdout + generated.stderr, file=sys.stderr)
            return 2
        assurance = json.loads((args.output / 'assurance.json').read_text())
        selected = [p for p in assurance['properties'] if p['id'] == args.property]
        if len(selected) != 1:
            parser.error(f'Expected one generated property {args.property!r}, found {len(selected)}')
        assurance['properties'] = selected
        claim_file = args.output / 'claim.json'
        write_json(claim_file, assurance)
    check_file = args.output / 'Check.lean'
    check_file.write_text(header + '#verify_blueprint Focus ' + json.dumps(str(claim_file)) + '\n')
    check = run(lean + [check_file], repo, env)
    log = check.stdout + check.stderr
    log_file = args.output / 'check.log'
    log_file.write_text(log)
    outcome = parse_verdict(log, args.property, check.returncode)
    result = {
        'property': args.property,
        'outcome': outcome,
        'date': datetime.now(timezone.utc).date().isoformat(),
        'method': 'Blaster SMT' if outcome in {'verified', 'falsified', 'inconclusive'} else None,
        'source': str(args.source),
        'sourceSha256': digest(args.source),
        'generatorSha256': generator_hash,
        'reusedCompiledCode': bool(args.reuse_bundle),
        'assuranceSha256': digest(args.output / 'assurance.json'),
        'blueprintSha256': digest(args.output / 'plutus.json'),
        'counterexample': parse_counterexample(log),
        'log': str(log_file),
    }
    write_json(result_file, result)
    print(log, end='', flush=True)
    print('Focused result:', result_file, flush=True)
    # A falsified property is a completed check with a model, not a runner crash.
    return 0 if outcome in {'verified', 'falsified', 'inconclusive'} else 1


if __name__ == '__main__':
    sys.exit(main())
