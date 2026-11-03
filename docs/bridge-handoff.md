# Plinth bridge: adding a property and reviewing the evidence

The source of truth is the Haskell contract and its UAL annotation. Plutus
compiles the on-chain definition to UPLC and generates `plutus.json` plus
`assurance.json`. `cardano-blaster check` imports those exact bytes, checks the
formal proposition with Blaster, and records the SMT verdict separately from
compiled UPLC replay and Haskell counterexample export. The VS Code extension
attaches the fresh result to its source annotation.

## Add the next automatic property

1. Define the annotation syntax and semantics in the [UAL template proposal](https://github.com/input-output-hk/UniversalAnnotationLanguage/blob/feat/property-templates/PropertyTemplates.md). Specify the quantified inputs, what counts as script rejection, and a case that should falsify the claim. UAL 1.0.0 itself does not yet include this proposed syntax.
2. Add the parsed template constructor and errors in Plutus `plutus-tx/src/PlutusTx/Ual/Syntax.hs` and `Parser.hs`. Expand it to an ordinary Lean proposition in `Templates.hs`; `plutus-tx/src/PlutusTx/Assurance/Build.hs` already invokes `expandPropertyTemplates` before assurance serialization. Keep the checker independent of template names.
3. Add parser/expansion tests in `plutus-tx/test/Ual/TemplatesSpec.hs`. Include both a conforming compiled script and a deliberately nonconforming compiled script in an example under `doc/docusaurus/static/code/Example/Ual/`. `PurposeIsolation/Main.hs` and its README show the existing pattern. Include a positive acceptance property if the negative property would also hold for a script that always rejects.
4. Generate the bundle from the rebuilt Haskell executable, then run `cardano-blaster check plutus.json assurance.json --refresh-environment`. A falsified example needs a confirmed compiled UPLC replay; an SMT witness alone is insufficient. Exercise the source annotation with the VS Code project manifest as well.

The [purpose-isolation proposal](https://github.com/input-output-hk/UniversalAnnotationLanguage/blob/feat/property-templates/PropertyTemplates.md) and [Plutus branch](https://github.com/RSoulatIOHK/plutus/tree/feat/ual-property-templates) are the concrete starting points. The generated assertion ranges over typed V3 `ScriptContext` values and script parameters. Its allowed purposes come entirely from the annotation, not blueprint invocation metadata. Exhausted CEK execution does not count as rejection. This is a claim about compiled evaluation on typed contexts, not a claim that every context is ledger-valid.

## Reproduce and review

The [CLI README](../README.md) gives release and source-build commands. Run the bundled Game and Auction examples for successful checks, then `purpose-isolation-counterexample` for a deliberate failure with a typed `ScriptContext` and confirmed replay. The [VS Code guide](../vscode-blaster/README.md) explains how to check one source property, inspect a stale badge, and open the formatted Haskell CEX. The [example provenance](../examples/README.md) identifies the producer source for each checked bundle.

For a milestone review, retain the source annotation, generated blueprint and assurance, the CLI `report.json`, `verification.log`, and any generated `Counterexample*.hs`. In the report, distinguish `verified`, `falsified`, `inconclusive`, and `not-checked`; inspect `replay.status` and Haskell export independently. Check the input, environment, executable and solver digests before attributing an old result to a new source. `--refresh-environment` creates a fresh derived checking context when replaying examples on another installation; it does not change the proposition or compiled script.

The current boundary is explicit: source export and compiled replay are supported for the documented types, including V3 `ScriptContext`, but arbitrary contract-specific Haskell datum/redeemer types are not inferred. A generated Haskell module performs the `FromData` decode and round-trip check when run; the CLI's `check` command does not compile that Haskell module. A second automatic vulnerability property remains to be specified and demonstrated before claiming that milestone item is complete.

Relevant review branches are [Plutus #7980](https://github.com/IntersectMBO/plutus/pull/7980), [Core #64](https://github.com/input-output-hk/PlutusCoreBlaster/pull/64), [Ledger #24](https://github.com/input-output-hk/CardanoLedgerApiBlaster/pull/24), [Lean Blaster #445](https://github.com/input-output-hk/Lean-blaster/pull/445), and [the CLI PR](https://github.com/RSoulatIOHK/cardano-blaster/pull/1). The purpose-isolation Plutus work is stacked on the Plutus #7980 branch. Review mergeability and CI on those PRs at review time; the example evidence alone does not imply that all upstream changes have merged.

## Checker syntax follow-up

The Core assurance checker currently uses a closed parser-node allowlist for formal expressions, then audits elaborated declarations. This blocks elaborator programs and unsafe definitions in externally supplied formal fragments, but ordinary notation aliases can be accidentally omitted. [Core #74](https://github.com/input-output-hk/PlutusCoreBlaster/pull/74) adds `<=` and `>=` with regression coverage. A separate review should preserve the trust boundary while reducing dependence on an exhaustive list of Lean parser node names.
