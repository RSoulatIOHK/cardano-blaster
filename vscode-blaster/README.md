# Plinth Blaster

Check Plinth UAL properties against compiled UPLC without leaving your Haskell
editor. Plinth Blaster runs the native cardano-blaster verifier and attaches
the result to the property that produced it. When a claim is falsified and UPLC
replay confirms the witness, you can inspect the counterexample in the editor.

## What you see in VS Code

- **Run a property inline.** Click the CodeLens above a UAL PROPERTY annotation.
  A detached FormalSpec.hs works as well as an annotation in Main.hs.
- **See the verdict at its source.** Verified, falsified and stale results appear
  beside the corresponding property; stale evidence never counts as a current
  result. A generated `accepts-some-context` property shows an acceptance
  witness only when its expected falsification is confirmed by compiled replay.
- **Inspect a Haskell counterexample.** For supported encoded types, hover over
  a falsified property to see a value decoded with Plutus FromData, or open the
  formatted value beside the specification. If Haskell rejects a Lean model's
  raw `Data` fields, the hover and editor show the exact replayed `Data` instead.
  A decoded value is checked against the Data used in the confirmed UPLC
  replay. When the Plinth generator supplies `source-types.json`, the inline
  view can also show contract-defined datum and redeemer values using their
  own `FromData` instances.
- **Check existing bundles.** Open a plutus.json or assurance.json and run
  **Blaster: Check Blueprint and Assurance**. A native report can be opened
  independently of the Haskell source.

## Get started

1. Install the matching native cardano-blaster [release](https://github.com/RSoulatIOHK/cardano-blaster/releases). Put its bin directory on PATH, or set the VS Code setting **blaster.executablePath** to the binary.
2. Open a Plutus checkout containing UAL annotations, then open a Haskell file with a PROPERTY block. The Game example is a small first check.
3. Click **Check this property with Blaster** above the annotation. The extension rebuilds the Cabal producer, generates fresh blueprint and assurance JSON, and checks the selected property.
4. If the verdict is falsified, hover over the annotation or click **Pretty-print Haskell CEX** to inspect the witness.

For the Plutus UAL examples, the first click can create the project manifest
automatically from the Cabal executable. It also works when the example has no
source JSON files: a bootstrap environment reference is generated in the local
output directory, and cardano-blaster captures the actual Lean environment
before verification. The checker selects Ledger imports from the generated
blueprint's Plutus version, so no profile needs to be guessed from Haskell
source. Other build layouts can provide a small
cardano-blaster.project.json with their generator command.

## Requirements and scope

Checking an existing plutus.json and assurance.json needs the native CLI.
Checking a Haskell property from current source also needs the matching Plutus
checkout, Node.js, Cabal and GHC to compile its generator. The extension finds
tools on PATH or uses the **blaster.cabalPath**, **blaster.ghcPath** and
**blaster.plutusPath** settings. A cold Plutus build can take time.

Blaster verifies the generated claim under its declared execution bounds. A
confirmed counterexample is replayed against compiled UPLC; Haskell decoding
is available for supported types and is reported as unavailable when a type
cannot be reconstructed. A result is tied to its source and generator inputs;
editing them makes that result stale. These checks do not establish ledger
validity for every possible ScriptContext.

The [project configuration and command reference](https://github.com/RSoulatIOHK/cardano-blaster/blob/main/vscode-blaster/docs/reference.md)
describes custom manifests, settings, JSON checks and counterexample exports.
The [CLI README](https://github.com/RSoulatIOHK/cardano-blaster#readme)
explains the verifier, runtime pins and standalone bundles.

## Build the extension

~~~sh
cd vscode-blaster
npm ci
npm test
npm run package
~~~

The generated VSIX can be installed with **Extensions → Install from VSIX…**.
The extension has no npm runtime dependencies. Report issues in the
[cardano-blaster repository](https://github.com/RSoulatIOHK/cardano-blaster/issues).

The icon adapts the [Lean-blaster logo](https://github.com/input-output-hk/Lean-blaster).
