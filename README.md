# cardano-blaster

Check a compiled Plutus blueprint and its assurance document:

```sh
cardano-blaster check plutus.json assurance.json
```

This repository owns the CLI and pins the Lean libraries it uses to exact Git
commits. Those commits can be on open pull requests: installing this tool does
not depend on their merge status. The command runs the existing
`#verify_blueprint` checker, with typed counterexample reconstruction and native
replay when supported by the property.

## Install

Prerequisites: Python 3.10+, Git, [elan](https://github.com/leanprover/elan),
and a C/C++ toolchain for Lean's native libraries (Xcode command line tools on
macOS; `build-essential` on Ubuntu). The locked Z3 binaries support macOS 13.3+
on Apple Silicon/Intel, Linux x86-64 with glibc 2.39+, and Linux ARM64 with
glibc 2.38+.

```sh
git clone https://github.com/RSoulatIOHK/cardano-blaster.git
cd cardano-blaster
python3 -m venv .venv
.venv/bin/python -m pip install -e .
source .venv/bin/activate
cardano-blaster setup
```

Setup fetches and builds the exact Lean dependencies and downloads the official
Z3 5.3.1 binary after checking its pinned archive SHA-256. The Lean toolchain is
4.24.0. The first build takes several minutes. No Haskell compiler, Nix setup,
or adjacent repository clone is needed to check compiled bundles.

The runtime and solver live in `~/Library/Caches/cardano-blaster` on macOS and
`${XDG_CACHE_HOME:-~/.cache}/cardano-blaster` on Linux. Set
`CARDANO_BLASTER_CACHE` to choose another location. Runtime caches are keyed by
the complete lock and project files. Installed wheels include those files too.

## Replay the examples

```sh
cardano-blaster check examples/game/plutus.json examples/game/assurance.json --refresh-environment
cardano-blaster check examples/auction/plutus.json examples/auction/assurance.json --refresh-environment
cardano-blaster check examples/helper-counterexample/plutus.json examples/helper-counterexample/assurance.json --refresh-environment
```

The first two verify 3 and 31 properties. The third deliberately changes
`old < proposed` to `old > proposed`: it exits with code 1, shows a typed
counterexample, and reports whether replay confirmed it against compiled UPLC.
`examples/auction-counterexample` similarly changes the minimum bid from 100 to
101 in the claim. `examples/parameters` covers native/Data parameters and their
application; `examples/recursive` covers a recursive Tree schema. See
[example provenance](examples/README.md).

`--refresh-environment` explicitly creates new checking contexts for this
installation. It preserves the original inputs and rechecks the same claims.
Without that flag, the checker requires the environment bound by the input
contexts to match the loaded checker, including module and solver digests.
Example contexts come from the original producer run, so use the flag when
replaying them on another installation. A fresh check does not validate historical
evidence for an older context.

## Results

Each invocation creates a fresh directory under `cardano-blaster-results/` with
`report.json`, `verification.log`, the Lean driver, the verifier's bound JSON
report, and derived input snapshots. Original input files are never overwritten.
Reports bind the checked blueprint, assurance, checking contexts, parameter
artifacts, runtime revisions, and solver by their digests. The pinned runtime is
checked for source or revision drift before and after verification.

| Exit code | Meaning |
| --- | --- |
| 0 | Every selected property was verified |
| 1 | At least one property was falsified |
| 2 | No falsification, but verification is inconclusive or a property was not checked |
| 3 | Invalid input, environment mismatch, build/process error or interruption |

Natural-language-only and unsupported statements do not count as verified.
Counterexample reconstruction and replay status are reported separately from
the SMT verdict. An unavailable reconstruction does not erase a falsification.

Useful options:

```sh
cardano-blaster check plutus.json assurance.json --property outbids_exact --refresh-environment
cardano-blaster check plutus.json assurance.json --json --output results
```

`--property ID` can be repeated. `--json` prints only the final report on stdout.
`--timeout SECONDS` bounds each build/check process. Interruption terminates the
verifier and its solver children together on POSIX systems. `--no-build` reuses
the prepared runtime. `--profile auto` selects fixed Core/Cardano V3 imports
from the digest-checked input environment. Use `--profile cardano-v3-cex` for a
producer placeholder environment that does not yet list its required modules.

For library development, `--project PATH` selects a custom Lake project and
`--z3 PATH` selects another solver. Reports explicitly mark these overrides;
they do not claim the default pinned configuration was used.

Verification uses Blaster SMT and the declared CEK step bounds. It does not
reconstruct a Lean proof or establish ledger acceptance or CPU/memory budgets.

## Pinned dependencies

The source of truth is [the runtime lock](cardano_blaster/runtime/lock.json),
alongside the committed Lake project and manifest. All three packages are direct
requirements, so a transitive dependency cannot silently choose another revision.

| Library | Commit |
| --- | --- |
| Lean-blaster | `1cb5a63e0416f336caa3104c2654718e6f971bc9` |
| PlutusCoreBlaster | `8ceb98c71a279a2796bbffe26720a454971fdddc` |
| CardanoLedgerApiBlaster | `5492bb0d8e5ee01587303c153440636e5f8ee933` |

Update the lock, Lake requirements and manifest together, then run the complete
integration suite. There are no floating branches or local path dependencies.

## Development

```sh
python -m unittest discover -s tests -p 'test_*.py'
python tests/integration.py
```

The integration suite uses the installed CLI and compiled examples, including
both deliberately false claims and a strict recheck of a newly bound context.
It requires `cardano-blaster setup` first.
