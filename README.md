# cardano-blaster

A native Lean 4 CLI for checking a compiled Plutus blueprint and its assurance:

```sh
cardano-blaster check plutus.json assurance.json
```

The executable embeds Lean's elaborator and the existing `#verify_blueprint`
checker. It runs Blaster directly and reconstructs and replays supported typed
counterexamples. There is no Python wrapper or invocation of `lean` or `lake`
during verification with a native distribution.

## Native distribution

The [releases](https://github.com/RSoulatIOHK/cardano-blaster/releases) provide
archives for Linux x86-64 and macOS ARM64, with SHA-256 checksums. Publication
requires the native integration tests to pass on both platforms. Download the
archive and matching `.sha256` file, verify it, and extract it:

```sh
shasum -a 256 -c cardano-blaster-PLATFORM.tar.gz.sha256
tar -xzf cardano-blaster-PLATFORM.tar.gz
./cardano-blaster/bin/cardano-blaster --version
./cardano-blaster/bin/cardano-blaster check plutus.json assurance.json
```

Keep the extracted directory together. It contains the compiled executable, the
Lean modules needed to elaborate claims, and Z3. Running it requires no Python,
Git, installed Lean/Lake, or C/C++ compiler. Linux binaries target Ubuntu 24.04
(glibc 2.39+); macOS binaries target Apple Silicon with macOS 14+.

The distribution checks its runtime file inventory before and after verification.
The three libraries are pinned to exact commits, including commits on open PRs;
installation does not depend on their merge status. The [runtime lock](runtime-lock.json)
and [Lake manifest](lake-manifest.json) record the complete selection.

## Replay the examples

The archive includes the compiled examples:

```sh
cd cardano-blaster
bin/cardano-blaster check examples/game/plutus.json examples/game/assurance.json --refresh-environment
bin/cardano-blaster check examples/auction/plutus.json examples/auction/assurance.json --refresh-environment
bin/cardano-blaster check examples/helper-counterexample/plutus.json examples/helper-counterexample/assurance.json --refresh-environment
```

Game and Auction verify 3 and 31 properties. The helper counterexample deliberately
reverses a comparison in a formal claim, leaving the compiled helper unchanged.
It exits with code 1 and reports a typed witness and compiled replay status.
`examples/auction-counterexample` changes the claimed minimum bid from 100 to 101.
`examples/parameters` covers native/Data encoding and applied parameters;
`examples/recursive` covers a recursive Tree schema. See
[example provenance](examples/README.md).

`--refresh-environment` creates derived checking contexts for this installation
and performs fresh verification. It preserves the original inputs, claims,
execution bounds and parameter bytes. Example contexts were captured in the
producer's environment, so use the flag when replaying them elsewhere. Without
it, the checker requires the bound environment to match the loaded executable,
modules and solver exactly. Historical evidence never substitutes for a fresh
successful check.

## Results

Each invocation creates a fresh directory under `cardano-blaster-results/`,
containing `report.json`, `verification.log`, the generated Lean driver,
the verifier's JSON report and derived input snapshots. No old success is reused.
Reports bind the original and checked inputs, contexts, applied parameter
artifacts, executable, dependency revisions and solver by their digests.

| Exit code | Meaning |
| --- | --- |
| 0 | Every selected property was verified |
| 1 | At least one property was falsified |
| 2 | No falsification, but verification is inconclusive or a property was not checked |
| 3 | Invalid input, incompatible environment, timeout or execution error |

Natural-language-only and unsupported statements do not count as verified.
Counterexample reconstruction and replay status remain separate from the SMT
verdict. Verification uses SMT and the declared CEK step bounds; it does not
reconstruct a Lean proof or establish ledger acceptance or CPU/memory budgets.

```sh
cardano-blaster check plutus.json assurance.json --property outbids_exact --refresh-environment
cardano-blaster check plutus.json assurance.json --json --output results
```

`--property ID` is repeatable. `--json` prints only the final report on stdout.
`--timeout SECONDS` bounds each verification worker and terminates its solver
processes on expiry. `--profile auto` selects fixed Core/Cardano V3 imports from
the digest-checked environment. `--profile cardano-v3-cex` can be selected for a
producer placeholder that does not yet list its required modules. `--z3 PATH`
selects another solver and is recorded as an override.

## Build from source

Developers need Git, elan and a C/C++ toolchain (Xcode command line tools on macOS;
`build-essential` on Ubuntu). Lean's native backend uses that toolchain to build
the executable. It is not needed when using a precompiled archive.

```sh
git clone https://github.com/RSoulatIOHK/cardano-blaster.git
cd cardano-blaster
lake build cardano-blaster native-tests
lake exe cardano-blaster setup
lake exe native-tests unit
lake exe cardano-blaster bundle dist/cardano-blaster
lake exe native-tests integration "$PWD/dist/cardano-blaster/bin/cardano-blaster" "$PWD/examples" "$PWD/cardano-blaster-results/integration"
```

`setup` downloads the official Z3 5.3.1 release after checking the archive's pinned
SHA-256. This source-build setup uses `curl` and `unzip`; the native archive already
includes Z3. Source runs also check that dependency checkouts are clean and match
their exact pinned revisions. No adjacent repository clones are required.

All CLI and test code is Lean 4. The integration tests run the relocated native
bundle from another directory with failing stubs for Python, Lean, Lake, Git and
C/C++ compilers on `PATH`. They verify 44 true properties, confirm both typed
counterexamples against compiled UPLC, recheck a bound context without refreshing,
and exercise invalid input, unsupported claims and timeout behavior.

When updating dependencies, change the Lake requirements, manifest and runtime
lock together, then rerun the native integration suite.
