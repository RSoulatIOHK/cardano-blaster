# Cardano Blaster for VS Code

This extension runs the native `cardano-blaster` checker and opens confirmed
counterexamples at the Haskell level. It also retains the original CodeLens,
hover and diagnostic display for UAL `PROPERTY` annotations and the older
`verified-assurance.json` demo workflow.

## Install locally

From the `cardano-blaster` repository root:

```sh
ln -s "$PWD/vscode-blaster" "$HOME/.vscode/extensions/iohk.blaster-assurance-0.2.0"
```

Reload the VS Code window. If an older `iohk.blaster-assurance-*` link is
installed, replace that link so VS Code loads only this copy. The extension has
no npm runtime dependencies; `npm test` runs its parser and report tests.

## Check a blueprint

Build `cardano-blaster` or configure `blaster.executablePath` to a native release.
Open `plutus.json` or `assurance.json` and run **Blaster: Check Blueprint and
Assurance**. The command uses the adjacent file when present and asks you to
select any missing input. It writes fresh runs under the first workspace folder's
`cardano-blaster-results/` directory by default; `blaster.outputPath` overrides
this. Set `blaster.refreshEnvironment` to `true` for example bundles produced on
another installation.

An exit code of 1 means Blaster found a falsified property. If compiled replay
is confirmed and the CLI exported a Haskell source, the extension offers **Open
Haskell CEX**. You can also run **Blaster: Load Assurance Results** to select a
run directory or `report.json`, then use **Blaster: Open Haskell
Counterexample** from the command palette. The extension checks the generated
source SHA-256 before opening it and warns if checked input files changed.
Opening a native `report.json` also shows **Open Haskell CEX** and **Decode
Haskell CEX** CodeLenses for its confirmed exports.

To see the decoded value, open a Plutus checkout with `cabal.project` as a
workspace folder or configure `blaster.plutusPath`, then run **Blaster: Decode
Haskell Counterexample**. This
launches `cabal exec ... ghci` in a VS Code task and runs the generated module's
`main`, which calls Plutus `FromData` and prints the typed values. The generated
decoder also checks `toData decoded == replayedData`; a failed decode or changed
round trip raises an explicit Haskell error. The task requires a working GHC and
Cabal environment for that Plutus checkout. `blaster.cabalPath` and
`blaster.haskellEnvironment` can select a Cabal executable and add environment
variables (for example, a project-specific `PKG_CONFIG_PATH` or `SDKROOT`).

The CLI's `report.json` records the SMT verdict, confirmed UPLC replay and
generated `.hs` file separately. The extension executes Haskell only when you
choose **Decode**. It does not claim that a `BuiltinData` datum or redeemer has
an application-specific Haskell type: that needs an explicit mapping from the
blueprint schema to the defining Haskell module and type. Currently the CLI
exports `V3.ScriptContext`, `V3.TxInfo` and `V3.ScriptInfo` with their real Plutus
`FromData` instances.

## Existing UAL annotation display

The extension still loads `verified-assurance.json` and focused
`property-result.json` files. It displays their source-bound evidence beside
UAL `PROPERTY` annotations, including detached `FormalSpec.hs` modules. The
older **Run Assurance Demo** and **Rerun This Property** commands still use the
coordinated PlutusCoreBlaster demo and its Python runner when the legacy paths
are configured. Native `report.json` files currently have hashes for blueprint
and assurance inputs, not for the originating Haskell source. The extension
therefore lists their results and CEX files without attaching a native verdict
to a Haskell annotation merely because its property ID matches.
