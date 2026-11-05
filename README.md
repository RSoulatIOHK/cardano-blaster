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
bin/cardano-blaster check examples/purpose-isolation/plutus.json examples/purpose-isolation/assurance.json --refresh-environment
bin/cardano-blaster check examples/purpose-isolation-counterexample/plutus.json examples/purpose-isolation-counterexample/assurance.json --refresh-environment
bin/cardano-blaster check examples/aiken-total-rejection/plutus.json examples/aiken-total-rejection/assurance.json --refresh-environment
bin/cardano-blaster check examples/plinth-total-rejection/plutus.json examples/plinth-total-rejection/assurance.json --refresh-environment
```

Game and Auction verify 3 and 31 properties. The helper counterexample deliberately
reverses a comparison in a formal claim, leaving the compiled helper unchanged.
It exits with code 1 and reports a typed witness and compiled replay status.
`examples/auction-counterexample` changes the claimed minimum bid from 100 to 101.
`examples/parameters` covers native/Data encoding and applied parameters;
`examples/recursive` covers a recursive Tree schema. See
[example provenance](examples/README.md).

`examples/aiken-total-rejection` contains an Aiken validator with contradictory
spending conditions. The compiled script is checked against the acceptance
template's universal rejection claim. Blaster verifies that claim, so the
expected acceptance witness is absent and the command exits with code 1. See
the [Aiken example](examples/aiken-total-rejection/README.md) for the source
and the exact scope of this result.

`examples/plinth-total-rejection` applies the same acceptance template to a
Plinth validator with contradictory script-purpose checks. Its
blueprint and assurance are generated from the annotated Haskell source. The
universal rejection claim verifies and the expected acceptance witness is
absent, giving the same intentional exit code 1. See the
[Plinth example](examples/plinth-total-rejection/README.md).

`examples/purpose-isolation` contains three verified purpose-isolation claims
and three acceptance witnesses. Each witness falsifies a generated universal
rejection claim and is confirmed against the compiled UPLC. It includes a native integer parameter and a script
that intentionally accepts both spending and minting even though its blueprint
lists a spending invocation. `examples/purpose-isolation-counterexample` has a
compiled script that omits the purpose guard. Its isolation claim is falsified
while its independent acceptance claim yields a confirmed witness. The CLI replays the wrong-purpose witness against UPLC and exports the exact `Data` with a Haskell
`ScriptContext` decoding attempt. The template parameter alone declares the allowed
purposes; blueprint purpose metadata does not constrain the claim.

The report keeps the raw `falsified` verdict for each generated negative claim,
plus `expectedOutcome: "falsified"` and `expectationMet: true` when the compiled
replay confirms it. The overall status is `witnessed` with exit code 0 when all
selected claims are either verified or have confirmed expected witnesses.
The Lean V1–V3 ledger models retain some transaction fields as raw `Data`;
therefore a replayed witness is not guaranteed to decode with Haskell `FromData`.
The exported source preserves the exact wire value even when decoding fails.

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

## Haskell counterexamples

A falsified property with a confirmed compiled replay automatically exports a
Haskell module under the run's `counterexamples/` directory. The terminal shows
the source file and the original input names. For encoded ledger values it shows
their Haskell types; the complete Data remains in the generated module and report:

```text
falsified  first_bid_exact
  replay: confirmed
  Haskell: .../counterexamples/Counterexample0.hs
  proposed = (100 :: Integer)
  locked = (100 :: Integer)
  tokens = (1 :: Integer)
  hi = (0 :: Integer)
```

The module preserves valid input names (`proposed`, `locked`, etc.). For an
encoded `ScriptContext`, it defines a `V3.Data` binding with the exact argument
used in the confirmed UPLC replay, then a `V3.ScriptContext` binding using the
ledger API's `fromData` instance. The generated decoder checks that `toData` of
the decoded context equals the original wire value. A failed decode or changed
round trip raises an explicit Haskell error; the raw Data remains available.
Invalid or colliding Haskell identifiers receive a safe replacement or suffix;
the original name remains in the JSON report.

The CLI generates this source in Lean without GHC or Python. It knows the Haskell
types of V3 `ScriptContext`, `TxInfo` and `ScriptInfo` arguments. A Plinth
generator can also write `source-types.json` beside `plutus.json`, recording
which contract-defined Haskell datum and redeemer types correspond to the
blueprint definitions. The CLI accepts that manifest only when its
`blueprintSha256` matches the exact blueprint it checks. It then emits source
that extracts the Data from a replayed context and decodes it through the
project's own `FromData` instance. Raw `BuiltinData` remains Data. The manifest
does not change the proof or UPLC replay; a decode failure is reported by the
generated Haskell module rather than hidden or treated as a verified result.
The default is the `source-types.json` beside the blueprint; use
`--source-types PATH` to select another manifest.

Each exported context must match a replayed wire argument exactly. The complete
wire value and confirmed UPLC replay remain in `verifier-report.json`; the
generated `main` decodes and prints the typed values. The Haskell decode and
round trip happen when that module runs, not during `check`.

The [VS Code extension](vscode-blaster/README.md) can run a property directly
from a Haskell project, show its verdict at the UAL annotation, and decode a
confirmed counterexample with Plutus `FromData` directly in the property's
tooltip or in a formatted Haskell editor view.
It can also inspect a standalone `report.json`. New releases built with this
extension include an installable VSIX; source-level checks additionally need that project's Plutus,
Cabal, GHC and Node.js build environment. Standalone JSON checks use only the
native CLI.

To compile and run an exported module, use a GHC environment containing the
Plutus project's `plutus-ledger-api`, `plutus-tx` and `bytestring` packages.
For contract-defined types, include the source directory that contains their
Haskell module:

```sh
ghc -package plutus-ledger-api -package plutus-tx -package bytestring \
  -i/absolute/path/to/project/source -main-is Counterexample0.main \
  /absolute/path/Counterexample0.hs -o replay-context
./replay-context
```

The VS Code extension discovers source import paths from the project file and
uses its Cabal environment to evaluate the generated module for inline display.

`counterexample.source` in `report.json` records `status`, the Haskell file URI
and SHA-256, input names/expressions, and the contexts' call targets and argument
indices. `wireArgumentSha256` hashes the canonical portable Data JSON from the
verifier (`wireArgumentEncoding: tocex-json-v1`). The original verifier report
is preserved and its digest is also recorded.

`compilation: not-run` distinguishes source export from compiling or running the
Haskell module. The CLI confirms execution through UPLC replay. Unknown source
types, incomplete values, unfinished replay and mismatched wire arguments produce
`source.status: unavailable` with a reason; the SMT verdict remains unchanged.
Supported source values include integers, naturals, booleans, strings, bytes,
unit, lists, pairs, options, Plutus Data and the three explicit V3 codecs above.

```sh
cardano-blaster check plutus.json assurance.json --property outbids_exact --refresh-environment
cardano-blaster check plutus.json assurance.json --json --output results
```

`--property ID` is repeatable. `--json` prints only the final report on stdout.
`--timeout SECONDS` bounds each verification worker and terminates its solver
processes on expiry. For a compiled Plutus blueprint, the checker reads
`preamble.plutusVersion`, loads the Ledger codecs and checks that a generated
`ScriptContext` property uses the matching version. A legacy project manifest's
`core` profile cannot suppress those imports. For bundles without a Plutus
version, `--profile auto` uses the digest-checked environment. The
`cardano-v3-cex` import profile includes the V1 and V2 codecs as well; the
report records the actual `plutusVersion` separately. `--z3 PATH`
selects another solver and is recorded as an override.

## Build from source

Developers need Git, elan and a C/C++ toolchain (Xcode command line tools on macOS;
`build-essential` on Ubuntu). Lean's native backend uses that toolchain to build
the executable. It is not needed when using a precompiled archive.

```sh
git clone https://github.com/RSoulatIOHK/cardano-blaster.git
cd cardano-blaster
lake build cardano-blaster
.lake/build/bin/cardano-blaster setup
.lake/build/bin/cardano-blaster check examples/game/plutus.json examples/game/assurance.json --refresh-environment
```

Run the built executable directly for checks. `lake exe` also replays dependency
build diagnostics, including warnings from earlier builds.

Source builds use Lean's default macOS deployment target for both the executable
and its dependencies. Release CI sets `MACOSX_DEPLOYMENT_TARGET=14.0` for the
entire build, including dependencies, and checks the resulting executable's target.
Setting a minimum version only on the root package would mix incompatible build
targets and generate linker warnings.

To run the developer checks and create a native distribution:

```sh
lake build native-tests
lake exe native-tests unit
.lake/build/bin/cardano-blaster bundle dist/cardano-blaster
lake exe native-tests integration "$PWD/dist/cardano-blaster/bin/cardano-blaster" "$PWD/examples" "$PWD/cardano-blaster-results/integration"
```

`setup` downloads the official Z3 5.3.1 release after checking the archive's pinned
SHA-256. This source-build setup uses `curl` and `unzip`; the native archive already
includes Z3. Source runs also check that dependency checkouts are clean and match
their exact pinned revisions. No adjacent repository clones are required.

All CLI and test code is Lean 4. The integration tests run the relocated native
bundle from another directory with failing stubs for Python, Lean, Lake, Git,
GHC/Cabal, Nix and C/C++ compilers on `PATH`. They verify 51 true properties, confirm three typed
counterexamples against compiled UPLC, recheck a bound context without refreshing,
export three Haskell counterexamples with bound file hashes, and exercise invalid
input, unsupported claims, mismatched/incomplete source values and timeout behavior.

When updating dependencies, change the Lake requirements, manifest and runtime
lock together, then rerun the native integration suite.
