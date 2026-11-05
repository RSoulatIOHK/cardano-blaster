# Compiled Plinth bridge examples

The Plinth bundles are produced by the UAL blueprint generators in
[Plutus at f39439265c603d379bf5836596dccee8311b5189](https://github.com/IntersectMBO/plutus/tree/f39439265c603d379bf5836596dccee8311b5189/doc/docusaurus/static/code/Example/Ual).
The purpose-isolation bundles were produced by the Plutus branch
`feat/ual-property-templates`, using the proposed UAL source template extension
on `feat/property-templates`. Their generated assurance claims use the released
UAL 1.0 format. Exact producer revisions are recorded in `provenance.json`.
The Auction uses its detached
[FormalSpec.hs](https://github.com/IntersectMBO/plutus/blob/f39439265c603d379bf5836596dccee8311b5189/doc/docusaurus/static/code/Example/Ual/Auction/FormalSpec.hs),
with compiled library helpers stored in assurance, rather than in the script
blueprint. Required fragments are included in the assurance document; checking
does not import a handwritten Auction proof module.

Compiled blueprints, helper programs, parameter artifacts and formal claims come
from the coordinated bridge run. Packaging compacts the generated environment
JSON, selects the relevant generated properties and checking contexts for each
purpose-isolation bundle, and updates affected SHA-256 references. Every referenced local artifact
is included. Producer revisions, original hashes and packaged hashes are recorded
in `provenance.json`.

| Bundle | Properties | Expected outcome |
| --- | --- | --- |
| game | 3 | verified |
| parameters | 6 | verified |
| recursive | 4 | verified |
| auction | 31 | verified |
| purpose-isolation | 6 | three isolation claims verified; three acceptance witnesses confirmed |
| helper-counterexample | 1 | falsified, with confirmed compiled replay |
| auction-counterexample | 1 | falsified, with confirmed compiled replay |
| purpose-isolation-counterexample | 2 | isolation falsified with confirmed compiled replay and Haskell `ScriptContext` export; acceptance witnessed |
| aiken-total-rejection | 1 | generated acceptance expectation fails: universal rejection claim verified |
| plinth-total-rejection | 1 | Plinth-generated acceptance expectation fails: universal rejection claim verified |

The [Aiken total-rejection fixture](aiken-total-rejection/README.md) is a
separate cross-compiler example. Its Aiken-produced UPLC is preserved in an
extended blueprint, and the Plinth acceptance-template formula is supplied as
an explicit assurance property. It demonstrates detection of a compiled script
that can never accept a valid context; it does not exercise Haskell annotation
generation.

The [Plinth total-rejection fixture](plinth-total-rejection/README.md) is
generated directly from a Plinth validator and its one-line UAL template
annotation. It exercises the source-to-assurance generator as well as the
compiled script checker.

The two counterexample bundles preserve the compiled Auction blueprint. Only a
formal claim is deliberately changed: the helper comparison is reversed, or the
first-bid threshold is raised from 100 to 101. These are demonstrations of false
claims, not generated attacks or claims that the underlying Auction is secure.

The purpose-isolation counterexample differs: its claim is generated from the
short UAL annotation, and the compiled `uncheckedPurpose` script actually omits
the purpose guard. A wrong-purpose context is accepted by that UPLC program.
Each script also has a separate generated `accepts-some-context` claim. It
negates successful execution for every typed context (and, for parameterized
scripts, every parameter), with no allowed-purpose premise. All four claims
are expected to be falsified, and compiled replay confirms their acceptance
witnesses, including the one for `uncheckedPurpose`.
The positive bundle contains a spending-and-minting script whose blueprint lists
only a spending invocation. Its generated property still allows both purposes,
as explicitly declared by the template; blueprint purpose metadata is not used
to define or restrict that claim.

The original environment binds a particular build and solver. Pass
`--refresh-environment` when replaying these bundles on your installation. That
creates derived checking contexts and performs fresh verification; it does not
reuse the producer's successful verdicts. Exact generated model values may vary
with the solver, while compiled replay must still confirm falsification.
