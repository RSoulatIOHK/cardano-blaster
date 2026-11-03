# Cardano Blaster for VS Code

This extension checks UAL properties from a Haskell project and displays the
result at the annotation. A falsified property gets an inline ✗ marker and a
diagnostic. Hovering over the annotation runs the generated module through
Plutus `FromData` and shows the decoded, formatted Haskell value directly in
the tooltip. A link in the tooltip and the **Pretty-print Haskell CEX** CodeLens
open the same value beside the specification. Decoded values are cached for
that verification run. The older report viewer remains available for
inspecting runs separately.

## Install

For releases containing the extension, download `blaster-assurance-*.vsix` and use
**Extensions → Install from VSIX…** in VS Code, or run:

```sh
code --install-extension blaster-assurance-*.vsix
```

Install a native `cardano-blaster` archive separately and put its `bin` directory
on `PATH`, or set `blaster.executablePath` to the extracted binary. Checking
existing blueprint/assurance JSON needs only that CLI. Checking a Haskell
property from source also needs the corresponding Plutus checkout, Node.js,
Cabal and GHC to rebuild its bundle; set `blaster.cabalPath`, `blaster.ghcPath`
and `blaster.plutusPath` if they are not discoverable from `PATH` or the open
workspace. No path to the extension author's checkout is required.

To build the VSIX from source:

```sh
cd vscode-blaster
npm ci
npm test
npm run package
```

## Develop with a local checkout

From the `cardano-blaster` repository root:

```sh
ln -s "$PWD/vscode-blaster" "$HOME/.vscode/extensions/iohk.blaster-assurance-0.2.0"
```

Reload the VS Code window. If an older `iohk.blaster-assurance-*` link is
installed, replace that link so VS Code loads only this copy. The extension has
no npm runtime dependencies; `npm test` runs its parser and report tests.

## Check from a Haskell property

For Plutus UAL examples, click **Set up and check this property with Blaster**.
When an unambiguous Cabal executable has `Main.hs` calling a
`writeInterfaceBundle` function, the extension
finds its Cabal target and local Haskell sources, then
creates `cardano-blaster.project.json` beside `Main.hs` before compiling and
checking the selected property. If the example has no `environment.json`, the
generator creates a bootstrap reference in `.local/cardano-blaster`; the checker
captures the actual Lean environment with `--refresh-environment`. This also works from a detached
`FormalSpec.hs`. The generated file can be reviewed and committed with the
contract. If Cabal has multiple matching executables or the project uses a
different bundle generator, configure the build recipe explicitly.

The manifest format is:

```json
{
  "format": "cardano-blaster-project-v1",
  "blueprint": "plutus.json",
  "assurance": "assurance.json",
  "sources": ["Main.hs", "OnChain.hs", "FormalSpec.hs"],
  "refreshEnvironment": true,
  "profile": "cardano-v3-cex",
  "generator": {
    "command": "./generate-assurance",
    "args": ["${sourceFile}"],
    "cwd": "${projectDir}"
  }
}
```

Without a manifest or an inferable Plutus bundle producer, the CodeLens says
**Configure a Blaster project to check**; the native source check needs a
generator target for that Haskell project.

The generator must **recompile the current Haskell sources**, including Plinth
code, and write the configured blueprint and assurance files. Arguments,
working directory and environment values may use `${projectDir}`,
`${sourceDir}`, `${sourceFile}`, `${extensionDir}`, `${ghcPath}` and
`${cabalPath}`. The last two come from the corresponding `blaster.*Path`
settings; the extension path points to the installed copy of this extension.
An unknown placeholder is an error. The generator inherits
`blaster.haskellEnvironment` from the source file's workspace folder. The
extension checks that both JSON files
were regenerated and contain the selected property. Put every contract and
specification source relevant to the output in `sources`; changes to those
files invalidate the displayed evidence. The manifest and selected `.hs` file
are always tracked even when omitted from `sources`.
Set `profile` when the generator starts with an illustrative environment that
has no `modules` map: use `cardano-v3-cex` for V3 scripts with typed CEX export,
`cardano-v3` for V3 verification only, or `core` for generic UPLC.

Open `FormalSpec.hs` or a `Main.hs` containing a UAL `PROPERTY` annotation and
click **Check this property** above the annotation, or place the cursor in it
and run **Blaster: Rerun This Property**. This generates the JSON, runs the
native checker for that property, and attaches the result to that exact source
file. The badge and CEX tooltip become stale if the source changes. A detached
`FormalSpec.hs` works the same way. Template properties such as
`[scope: uncheckedPurpose] [template: purpose-isolation spending]` are matched
to their generated ID `uncheckedPurpose_purpose_isolation`.

For the Plutus UAL examples, `scripts/generate-plutus-ual.js` is a ready
generator that builds a Cabal executable from source, finds its binary, and
runs it in the example directory. Set the manifest's `generator.command` to
`node` and `args` to the script path, Cabal target, `${projectDir}`, an
optional GHC path, and an optional output directory for generated JSON. The
example directory may contain an `environment.json` reference; otherwise the
generator derives one from the manifest profile in its output directory.
Building Plutus can take time on a cold Cabal cache; a cached executable is
never substituted for a failed build.

Put a separate manifest beside each independent contract example. The extension
finds the nearest manifest for the selected Haskell file, uses that folder's
Blaster settings, and stores its focused runs under a project-specific
directory in `blaster.outputPath`. It loads reports from every open workspace
folder. A result without a matching source-file binding cannot label an
annotation in a manifest project, even if another project has the same property
ID. Changes to any source listed in that manifest mark that project's result
stale. For example, the Plutus `Auction` and `PurposeIsolation` examples can
coexist in one VS Code workspace without sharing badges or CEX pickers.

To decode a confirmed CEX, point `blaster.plutusPath` to a Plutus checkout
with `cabal.project`, or open that checkout as the workspace. The extension
invokes `cabal exec ... ghci` there, runs the generated `FromData` decoder,
and formats its Haskell `Show` output. Configure `blaster.cabalPath` and
`blaster.haskellEnvironment` for the checkout when necessary (for example,
`PKG_CONFIG_PATH` on macOS). The decoder checks the Data round trip and
reports a failed decode instead of showing an invented typed value.

## Check existing JSON inputs

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
choose **Decode** or **Pretty-print Haskell CEX**. It does not claim that a
`BuiltinData` datum or redeemer has an application-specific Haskell type: that
needs an explicit mapping from the
blueprint schema to the defining Haskell module and type. Currently the CLI
exports `V3.ScriptContext`, `V3.TxInfo` and `V3.ScriptInfo` with their real Plutus
`FromData` instances.

## Existing UAL annotation display

The extension still loads `verified-assurance.json` and focused
`property-result.json` files. It displays their source-bound evidence beside
UAL `PROPERTY` annotations, including detached `FormalSpec.hs` modules. The
older **Run Assurance Demo** and focused replay still use the coordinated
PlutusCoreBlaster demo and its Python runner when the legacy paths are
configured and no project manifest is present. A standalone native
`report.json` has no Haskell source binding, so loading one does not label an
annotation merely because its property ID matches. Running from a project
manifest creates that binding and records source hashes.
