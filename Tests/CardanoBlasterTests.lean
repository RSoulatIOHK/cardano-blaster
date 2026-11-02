import CardanoBlaster.Counterexample
import CardanoBlaster.SourceValue

namespace Tests.Counterexample
open Lean System CardanoBlaster
open CardanoBlaster.Counterexample
private abbrev Value := Blaster.Counterexample.Value
private def json (v : Value) := v.toJson

private def ensure (b : Bool) (s : String) : IO Unit :=
  unless b do throw <| IO.userError s

private def binding (name : String) (v : Json) : Json := obj [("name", toJson name),
  ("leanType", toJson "test type"), ("error", .null), ("value", v)]

private def wire : Json := json <| .constructor "PlutusCore.Data" "Constr" [
  ("index", .integer 0), ("fields", .list [.constructor "PlutusCore.Data" "I" [("value", .integer 7)]])]

private def sourceWire := json <| .constructor "PlutusCore.Data" "Constr" [
  ("index", .integer 0), ("fields", .list [.constructor "PlutusCore.Data" "B" [("value", .bytes "00ff")]])]

private def context := obj [("kind", toJson "encoded"), ("encoding", toJson "plutus-data"),
  ("type", toJson "PlutusLedgerApi.V3.ScriptInfo"), ("value", sourceWire)]

private def call := obj [("target", toJson "compiled.script"), ("outcome", toJson "halted"),
  ("arguments", toJson #[binding "wire" sourceWire]), ("sourceArguments", toJson #[
    obj [("argument", binding "ctx" context)], obj [("argument", binding "ctx again" context)]])]

private def fixture (calls : Array Json := #[call]) : Json := obj [("property", toJson "../unsafe\nmodule Evil where"),
  ("outcome", toJson "falsified"), ("counterexample", obj [
    ("model", obj [("bindings", toJson #[binding "x\nmain=undefined" (json (.integer (-7)))])]),
    ("replay", obj [("status", toJson "confirmed"), ("propertyHolds", toJson false), ("calls", .arr calls)])])]

private def withReplay (r : Json) : Json := put fixture "counterexample" (put (fixture.getObjValD "counterexample") "replay" r)

def run : IO Unit := do
  let fixtures ← IO.ofExcept <| Json.parse (include_str "Fixtures/ledger-source-values.json")
  let fixtures ← array fixtures
  ensure (fixtures.size == 111) "missing Haskell codec fixtures"
  for f in fixtures do
    discard <| IO.ofExcept <| SourceValue.render plutusData haskell (← text f "type") (← field f "wire")
  for (v, expected) in [
      (Blaster.Counterexample.Value.integer (-123456789012345678901234567890), "(-123456789012345678901234567890 :: Integer)"),
      (.natural 7, "(7 :: Integer)"), (.boolean true, "True"), (.boolean false, "False"),
      (.unit, "()"), (.bytes "00ff80", "BS.pack [0, 255, 128]"),
      (.list [.integer 1, .integer (-2)], "[(1 :: Integer), (-2 :: Integer)]"),
      (.constructor "Prod" "Prod.mk" [("fst", .integer 3), ("snd", .boolean true)], "((3 :: Integer), True)"),
      (.constructor "Option" "Option.some" [("value", .integer 3)], "(Just (3 :: Integer))"),
      (.constructor "Option" "Option.none" [], "Nothing")] do
    ensure ((← IO.ofExcept (haskell (json v))) == expected) s!"incorrect Haskell value: {expected}"
  ensure (CardanoBlaster.Counterexample.quote "éA\n\"\\" == "\"\\xe9\\&A\\n\\\"\\\\\"") "Haskell string escaping"
  ensure ((← IO.ofExcept (plutusData wire)) == "V3.Constr (0) [V3.I (7)]") "Data fields changed"
  let mapValue : Value := .constructor "PlutusCore.Data" "Map" [("entries", .list [
    .constructor "Prod" "Prod.mk" [("fst", .constructor "PlutusCore.Data" "B" [("value", .bytes "00ff")]),
      ("snd", .constructor "PlutusCore.Data" "List" [("values", .list [])])]])]
  ensure ((← IO.ofExcept (plutusData (json mapValue))) == "V3.Map [(V3.B (BS.pack [0, 255]), V3.List [])]") "Data map changed"
  for invalid in [json (.unavailable "missing"), json (.bytes "0"), json (.bytes "GG"),
      json (.constructor "Unknown" "Anything" []), json (.list [.integer 1, .boolean true]),
      json (.list [.integer 1, .unavailable "missing"]),
      obj [("kind", toJson "natural"), ("value", toJson "-1")],
      obj [("kind", toJson "integer"), ("value", toJson "01")],
      put context "type" (toJson "Malicious.Type"), put context "encoding" (toJson "unknown")] do
    ensure (!(haskell invalid).isOk) "invalid value acquired Haskell source"
  let (source, info) ← IO.ofExcept (prepare fixture)
  ensure ((← array (← field info "contexts")).size == 1) "duplicate source contexts"
  ensure ((source.splitOn "property = \"../unsafe\\nmodule Evil where\"").length > 1) "property text became source code"
  ensure ((source.splitOn "input0 = (-7 :: Integer)").length > 1) "input identifier derived from producer name"
  ensure ((source.splitOn "ctx :: V3.ScriptInfo").length > 1) "source argument name was lost"
  ensure ((source.splitOn "ctxData :: V3.Data").length > 1) "wire Data was not exported"
  ensure ((source.splitOn "ctx = decodeData ctxData").length > 1) "Haskell FromData is not used"
  ensure ((source.splitOn "V3.toData value == wire").length > 1) "decoded context is not checked against the replayed wire"
  let matched := put fixture "counterexample" (put (fixture.getObjValD "counterexample") "model"
    (obj [("bindings", toJson #[binding "ctx" context])]))
  let (matchedSource, _) ← IO.ofExcept (prepare matched)
  ensure ((matchedSource.splitOn "ctx_1Data = ctxData").length > 1 &&
    (matchedSource.splitOn "ctx_1 = ctx").length > 1) "model and replay duplicated the Data argument"
  ensure ((matchedSource.splitOn (← IO.ofExcept (plutusData sourceWire))).length == 2)
    "wire Data was emitted more than once"
  let wrongSource := put context "value" wire
  ensure ((haskell wrongSource).isOk) "well-formed wire Data should remain exportable"
  let ratioWire (n d : Int) := json <| .constructor "PlutusCore.Data" "Constr" [
    ("index", .integer 0), ("fields", .list [
      .constructor "PlutusCore.Data" "I" [("value", .integer n)],
      .constructor "PlutusCore.Data" "I" [("value", .integer d)]])]
  for (n,d) in [(0,0), (1,-2), (2,4)] do
    ensure (!(SourceValue.render plutusData haskell "PlutusTx.Ratio.Rational" (ratioWire n d)).isOk)
      "Haskell Rational would change the wire value"
  let named := put (fixture #[]) "counterexample" (put ((fixture #[]).getObjValD "counterexample") "model"
    (obj [("bindings", toJson #[binding "proposed" (json (.integer 100)),
      binding "proposed" (json (.integer 101)), binding "where" (json (.integer 0))])]))
  let (namedSource, _) ← IO.ofExcept (prepare named)
  for expected in ["proposed = (100 :: Integer)", "proposed_1 = (101 :: Integer)", "input2 = (0 :: Integer)"] do
    ensure ((namedSource.splitOn expected).length > 1) "valid source name lost, or duplicate/reserved identifier emitted"
  ensure (optText info "compilation" == some "not-run") "export claims a Haskell compilation"
  let replay := fixture.getObjValD "counterexample" |>.getObjValD "replay"
  let mismatch := put call "arguments" (toJson #[binding "wire" (json (.integer 99))])
  let incomplete := put call "arguments" (toJson #[put (binding "wire" wire) "error" (toJson "missing")])
  for invalid in [fixture #[mismatch], fixture #[incomplete], fixture #[put call "outcome" (toJson "unfinished")],
      withReplay (put replay "status" (toJson "unavailable")), withReplay (put replay "propertyHolds" (toJson true))] do
    ensure (!(prepare invalid).isOk) "unconfirmed or mismatched source witness accepted"
  let scalar := put (fixture #[]) "counterexample" (put ((fixture #[]).getObjValD "counterexample") "model"
    (obj [("bindings", toJson #[binding "string" (json (.string "V3. BS. \"\nλa"))])]))
  let (scalarSource, _) ← IO.ofExcept (prepare scalar)
  ensure ((scalarSource.splitOn "import qualified PlutusLedgerApi").length == 1) "imports inferred from user string contents"
  IO.FS.withTempDir fun folder => do
    let results ← exportSources folder #[fixture, fixture #[mismatch]]
    let exported := results[0]!.getObjValD "counterexample" |>.getObjValD "source"
    let unavailable := results[1]!.getObjValD "counterexample" |>.getObjValD "source"
    let file ← field exported "file"
    ensure ((← text file "uri") == "counterexamples/Counterexample0.hs") "unsafe output path"
    ensure ((← hashFile (folder / (← text file "uri"))) == (← text (← field file "hash") "digest")) "unbound Haskell file"
    ensure (optText unavailable "status" == some "unavailable" && optText results[1]! "outcome" == some "falsified") "source export changed the SMT verdict"
  IO.println "Haskell source export and negative checks passed."

end Tests.Counterexample
