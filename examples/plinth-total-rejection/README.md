# Plinth total rejection

The source is the Plutus
[`example-ual-total-rejection`](https://github.com/RSoulatIOHK/plutus/tree/feat/ual-property-templates/doc/docusaurus/static/code/Example/Ual/TotalRejection).
Its `locked` validator decodes the V3 script purpose, then requires its
constructor tag to be both `1` and `0`. No input can satisfy both checks. The
sole `[template: accepts-some-context]` annotation causes
Plutus to generate the assurance property; this fixture does not hand-write a
Lean formula.

From the repository root:

```sh
lake exe cardano-blaster check \
  examples/plinth-total-rejection/plutus.json \
  examples/plinth-total-rejection/assurance.json \
  --refresh-environment
```

The intentional result is exit code 1: the universal rejection proposition is
`verified`, while its expected acceptance witness is absent
(`expectationMet: false`). This is a bounded compiled-UPLC check for total
rejection, not a proof that every possible execution is rejected.

The native unit suite also runs the exact compiled UPLC on a structurally
shaped context and checks that it reaches a CEK `Error` within the 1,000-step
bound. This guards against a vacuous result caused solely by step exhaustion;
the dummy transaction info in that calibration input is not a ledger-valid
`ScriptContext`.
