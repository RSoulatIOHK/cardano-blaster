# Aiken total rejection

[`source/validators/locked.ak`](source/validators/locked.ak) is a Plutus V3
spending validator written in Aiken 1.1.24. It decodes an integer datum and
redeemer, then requires the redeemer to be both greater than and less than or
equal to the same datum. Neither branch can succeed, although the compiled
program still includes Aiken's normal spending wrapper and Data decoding.

[`source/plutus.json`](source/plutus.json) is Aiken's unmodified CIP-57 output.
The adjacent [`plutus.json`](plutus.json) preserves its `compiledCode` and script
hash exactly, adds a stable validator ID and the CIP-57 compiled-interface
description for the V3 context argument, and selects the spending entry. The
[`assurance.json`](assurance.json) uses the same formula as the Plinth
`accepts-some-context` template, scoped to that compiled Aiken validator. It
asks for a valid context on which the script succeeds by expecting a replayed
falsification of the universal rejection claim. This example supplies the
assurance document explicitly; it does not claim that the Plinth source-template
generator reads Aiken code.

Rebuild the Aiken blueprint from the source (Aiken 1.1.24 and its standard
library are needed for this step):

```sh
aiken build examples/aiken-total-rejection/source
```

Then run the checked bundle from the `cardano-blaster` repository root:

```sh
lake exe cardano-blaster check \
  examples/aiken-total-rejection/plutus.json \
  examples/aiken-total-rejection/assurance.json \
  --refresh-environment
```

The command exits with code 1 **by design**. The property itself is `verified`:
under the declared 10,000-step UPLC budget, Blaster finds no valid context
accepted by the compiled script. Because the assurance expects an acceptance
witness, `expectationMet` is `false` and the overall status is `falsified`. The
source and compiled UPLC have the same hash in both blueprints. This detects
*total rejection*; it does not establish that a particular UTxO is spendable.

As a separate sanity check, a simple Aiken spending validator returning `True`
produced a confirmed UPLC replay witness when the `validScriptContext` premise
was removed. With that premise, the witness search was inconclusive even for
the `True` body. This limits what the present example demonstrates: the
negative result is conclusive, but positive Aiken witness generation under the
full ledger-validity predicate still needs work.
