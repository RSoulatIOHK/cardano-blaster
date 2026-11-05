# Plinth bridge: adding a property and reviewing the evidence

The source of truth is the Haskell contract and its UAL annotation. Plutus
compiles the on-chain definition to UPLC and generates `plutus.json`,
`assurance.json` and a blueprint-bound `source-types.json`. The last file
records Haskell datum/redeemer type provenance for counterexample display; it
does not change the portable CIP-57 or assurance formats.
`cardano-blaster check` imports the blueprint and assurance bytes, checks the
formal proposition with Blaster, and records the SMT verdict separately from
compiled UPLC replay and Haskell counterexample export. The VS Code extension
attaches the fresh result to its source annotation.

## Add the next automatic property

1. Define the annotation syntax and semantics in the [UAL template proposal](https://github.com/input-output-hk/UniversalAnnotationLanguage/blob/feat/property-templates/PropertyTemplates.md). Specify the quantified inputs, what counts as script rejection, and a case that should falsify the claim. UAL 1.0.0 itself does not yet include this proposed syntax.
2. Add the parsed template constructor and errors in Plutus `plutus-tx/src/PlutusTx/Ual/Syntax.hs` and `Parser.hs`. Expand it to an ordinary Lean proposition in `Templates.hs`; `plutus-tx/src/PlutusTx/Assurance/Build.hs` already invokes `expandPropertyTemplates` before assurance serialization. Keep the checker independent of template names.
3. Add parser/expansion tests in `plutus-tx/test/Ual/TemplatesSpec.hs`. Include both a conforming compiled script and a deliberately nonconforming compiled script in an example under `doc/docusaurus/static/code/Example/Ual/`. `PurposeIsolation/Main.hs` and its README show the existing pattern. The independent `accepts-some-context` template checks that some typed context succeeds, so a script that always rejects cannot pass both claims.
4. Generate the bundle from the rebuilt Haskell executable, then run `cardano-blaster check plutus.json assurance.json --refresh-environment`. A falsified example needs a confirmed compiled UPLC replay; an SMT witness alone is insufficient. Exercise the source annotation with the VS Code project manifest as well.

The [template proposal](https://github.com/input-output-hk/UniversalAnnotationLanguage/blob/feat/property-templates/PropertyTemplates.md) and [Plutus branch](https://github.com/RSoulatIOHK/plutus/tree/feat/ual-property-templates) are the concrete starting points. Purpose isolation universally quantifies typed V3 `ScriptContext` values and script parameters; its allowed purposes come entirely from the annotation, not blueprint invocation metadata. Acceptance is a separate existential over contexts and parameters, with no purpose premise. Both current templates restrict their domain with the version-specific `validScriptContext` predicate. An acceptance witness must succeed within the declared CEK budget and survive compiled UPLC replay. Existence of one such witness does not establish spendability of every UTxO or every parameter choice.

## Reproduce and review

The [CLI README](../README.md) gives release and source-build commands. Run the bundled Game and Auction examples for successful checks, then `purpose-isolation-counterexample` for a deliberate failure with a typed `ScriptContext` and confirmed replay. The [Aiken total-rejection fixture](../examples/aiken-total-rejection/README.md) demonstrates that the same acceptance check detects a compiled spending validator that cannot accept any valid context; this independently exercises the checker, not Plinth annotation generation. The [VS Code guide](../vscode-blaster/README.md) explains how to check one source property, inspect a stale badge, and open the formatted Haskell CEX. The [example provenance](../examples/README.md) identifies the producer source for each checked bundle.

For the contract-defined redeemer, open the Plutus
[`PurposeIsolation/Main.hs`](https://github.com/RSoulatIOHK/plutus/blob/feat/ual-property-templates/doc/docusaurus/static/code/Example/Ual/PurposeIsolation/Main.hs)
in VS Code and check `uncheckedPurpose_purpose_isolation`. The rebuilt generator
writes `source-types.json` beside its blueprint; the CLI finds it automatically
and exports `Counterexample*.hs` after confirmed replay. Run that module in the
same Plutus Cabal/GHC environment, including
`doc/docusaurus/static/code` on the Haskell import path. It should print the
complete `ScriptContext` and `redeemer = WitnessRedeemer "ABC"`. The
[`PurposeIsolation` README](https://github.com/RSoulatIOHK/plutus/blob/feat/ual-property-templates/doc/docusaurus/static/code/Example/Ual/PurposeIsolation/README.md)
gives the generator and checker commands.

For a milestone review, retain the source annotation, generated blueprint and assurance, the CLI `report.json`, `verification.log`, and any generated `Counterexample*.hs`. In the report, distinguish `verified`, `falsified`, `inconclusive`, and `not-checked`; inspect `replay.status` and Haskell export independently. Check the input, environment, executable and solver digests before attributing an old result to a new source. `--refresh-environment` creates a fresh derived checking context when replaying examples on another installation; it does not change the proposition or compiled script.

Source export and compiled replay support V3 `ScriptContext` and contract-defined
datum/redeemer types when the Plinth generator supplied a matching
`source-types.json`. The Haskell module invokes the project's actual `FromData`
instance and checks `ToData` against the replayed wire bytes; the CLI's `check`
command does not compile that module. Other arbitrary nested Haskell source
types are not inferred. In the purpose-isolation example, the intentionally
failing property replays a byte-string redeemer and the source module displays
it as `WitnessRedeemer "ABC"`. The acceptance template can be presented as a
total-rejection check, but the Aiken fixture alone does not demonstrate
automatic generation for Aiken, and positive Aiken witness search under the
full `validScriptContext` predicate remains inconclusive. Record those limits
before claiming the second milestone item is complete.

Relevant review branches are [Plutus #7980](https://github.com/IntersectMBO/plutus/pull/7980), [the Plutus fork PR](https://github.com/RSoulatIOHK/plutus/pull/1), [Core #64](https://github.com/input-output-hk/PlutusCoreBlaster/pull/64), [Ledger #24](https://github.com/input-output-hk/CardanoLedgerApiBlaster/pull/24), [Ledger #27](https://github.com/input-output-hk/CardanoLedgerApiBlaster/pull/27), [Lean Blaster #445](https://github.com/input-output-hk/Lean-blaster/pull/445), and [the CLI PR](https://github.com/RSoulatIOHK/cardano-blaster/pull/1). The Plutus fork work is stacked on Plutus #7980; the Ledger validity branch is stacked on Ledger #24. The CLI pins exact revisions for each dependency. Review mergeability and CI on those PRs at review time; the example evidence alone does not imply that all upstream changes have merged.

## Checker syntax follow-up

The Core assurance checker currently uses a closed parser-node allowlist for formal expressions, then audits elaborated declarations. This blocks elaborator programs and unsafe definitions in externally supplied formal fragments, but ordinary notation aliases can be accidentally omitted. [Core #74](https://github.com/input-output-hk/PlutusCoreBlaster/pull/74) adds `<=` and `>=` with regression coverage. A separate review should preserve the trust boundary while reducing dependence on an exhaustive list of Lean parser node names.
