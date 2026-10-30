# Compiled Plinth bridge examples

These are compiled bundles produced by the UAL blueprint generators in
[Plutus at f39439265c603d379bf5836596dccee8311b5189](https://github.com/IntersectMBO/plutus/tree/f39439265c603d379bf5836596dccee8311b5189/doc/docusaurus/static/code/Example/Ual).
The Auction uses its detached
[FormalSpec.hs](https://github.com/IntersectMBO/plutus/blob/f39439265c603d379bf5836596dccee8311b5189/doc/docusaurus/static/code/Example/Ual/Auction/FormalSpec.hs),
with compiled library helpers stored in assurance, rather than in the script
blueprint. Required fragments are included in the assurance document; checking
does not import a handwritten Auction proof module.

Compiled blueprints, helper programs, parameter artifacts and formal claims come
from the coordinated bridge run. Packaging compacts the generated environment
JSON, removes unused checking contexts from the two single-property counterexample
bundles, and updates affected SHA-256 references. Every referenced local artifact
is included. Producer revisions, original hashes and packaged hashes are recorded
in `provenance.json`.

| Bundle | Properties | Expected outcome |
| --- | --- | --- |
| game | 3 | verified |
| parameters | 6 | verified |
| recursive | 4 | verified |
| auction | 31 | verified |
| helper-counterexample | 1 | falsified, with confirmed compiled replay |
| auction-counterexample | 1 | falsified, with confirmed compiled replay |

The two counterexample bundles preserve the compiled Auction blueprint. Only a
formal claim is deliberately changed: the helper comparison is reversed, or the
first-bid threshold is raised from 100 to 101. These are demonstrations of false
claims, not generated attacks or claims that the underlying Auction is secure.

The original environment binds a particular build and solver. Pass
`--refresh-environment` when replaying these bundles on your installation. That
creates derived checking contexts and performs fresh verification; it does not
reuse the producer's successful verdicts. Exact generated model values may vary
with the solver, while compiled replay must still confirm falsification.
