import CardanoBlaster.Cli
import CardanoBlaster.SourceValue
import CardanoBlasterTests
import PlutusCore.UPLC.ScriptEncoding.Basic

open Lean System CardanoBlaster

private def ensure (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def plinthBudgetSanity (blueprint : FilePath) : IO Unit := do
  let validators ← array (← field (← readJson blueprint) "validators")
  let hex ← text validators[0]! "compiledCode"
  let program ← IO.ofExcept (PlutusCore.UPLC.ScriptEncoding.singleCborEncodedScriptFromHex? hex)
  -- The script inspects the purpose tag in this structurally shaped argument.
  -- It must reach its contradictory checks before the declared step bound;
  -- the dummy TxInfo is not claimed to be ledger-valid.
  let raw : PlutusCore.Data.Data := .Constr 0 [.I 0, .I 0, .Constr 1 []]
  let argument := PlutusCore.UPLC.Term.Term.Const (.Data raw)
  match PlutusCore.UPLC.CekMachine.cekExecuteProgram program [argument] 1000 with
  | .Error => pure ()
  | .Halt _ => throw <| IO.userError "total-rejection script unexpectedly succeeded"
  | _ => throw <| IO.userError "total-rejection script exhausted its CEK step bound"

private def nativeReport (results : Array Json) : Json := obj [
  ("format", toJson "plinth-counterexample-report-v1"), ("assuranceSha256", toJson "aa"),
  ("blueprintSha256", toJson "bb"), ("results", .arr results)]

private def result (outcome : String) : Json := obj [("property", toJson "p"), ("outcome", toJson outcome)]

private def unit : IO Unit := do
  Tests.Counterexample.run
  let classifyResults := fun results code => IO.ofExcept (classify (nativeReport results) #["p"] "aa" "bb" code)
  ensure ((← classifyResults #[] 0).1 == .inconclusive) "missing results cannot pass"
  ensure ((← classifyResults #[result "verified"] 1).1 == .error) "nonzero exit cannot pass"
  ensure ((← classifyResults #[result "inconclusive"] 1).1 == .inconclusive) "undetermined cannot pass"
  let cex := obj [("model", obj [("witness", toJson "exact value")]), ("replay", obj [("status", toJson "unavailable")])]
  let (outcome, results) ← classifyResults #[put (result "falsified") "counterexample" cex] 1
  ensure (outcome == .falsified && results[0]!.getObjValD "counterexample" == cex) "preserve CEX and replay separately"
  let expectation := obj [("id", toJson "p"), ("tags", toJson #["expect:falsified"])]
  let confirmed := put (result "falsified") "counterexample" (obj [
    ("replay", obj [("status", toJson "confirmed"), ("propertyHolds", toJson false)])])
  let (witnessOutcome, marked) ← IO.ofExcept (reconcileExpectations #[expectation] #[confirmed] .falsified)
  ensure (witnessOutcome == .witnessed && (marked[0]!.getObjValAs? Bool "expectationMet").toOption == some true)
    "confirmed expected falsification should count as a witness"
  let unconfirmed := put (result "falsified") "counterexample" (obj [
    ("replay", obj [("status", toJson "not-reproduced"), ("propertyHolds", toJson true)])])
  ensure ((← IO.ofExcept (reconcileExpectations #[expectation] #[unconfirmed] .falsified)).1 == .inconclusive)
    "unreplayed solver model counted as a witness"
  ensure ((← IO.ofExcept (reconcileExpectations #[expectation] #[result "verified"] .verified)).1 == .falsified)
    "always-rejecting script counted as accepted"
  for report in [nativeReport #[result "verified", result "verified"],
      nativeReport #[put (result "verified") "property" (toJson "other")], nativeReport #[result "maybe"],
      put (nativeReport #[result "verified"]) "blueprintSha256" (toJson "wrong")] do
    ensure (!(classify report #["p"] "aa" "bb" 0).isOk) "reject invalid or unbound native report"
  for source in ["{\"x\":1,\"x\":2}", "{\"x\":1,\"\\u0078\":2}", "{\"x\":NaN}", "{\"x\":Infinity}"] do
    let mut failed := false
    try discard <| parseJson source catch _ => failed := true
    ensure failed "ambiguous or invalid JSON accepted"
  discard <| parseJson "{\"x\":1,\"nested\":{\"x\":2},\"string\":\"{\\\"x\\\":4}\"}"
  ensure (!(parseOptions ["--timeout", "0"] { blueprint := "a", assurance := "b" }).isOk) "invalid deadline"
  IO.FS.withTempDir fun folder => do
    let path := folder / "term.flat"
    let bytes := "a flat value".toUTF8
    IO.FS.writeBinFile path bytes
    let ref := digestRef "term.flat" (hashBytes bytes)
    let run := folder / "run"
    IO.FS.createDir run
    let (copied, inputs) ← (snapshotAssets ref folder run).run #[]
    ensure (inputs.size == 1) "snapshot input digest missing"
    ensure ((← IO.FS.readBinFile (run / (← text copied "uri"))) == bytes) "parameter bytes changed"
    IO.FS.writeFile path "tampered"
    let mut failed := false
    try discard <| (checkedBytes folder ref).run #[] catch _ => failed := true
    ensure failed "tampered parameter accepted"
  let home ← Runtime.root
  plinthBudgetSanity (home / "examples/plinth-total-rejection/plutus.json")
  let manifest ← readJson (home / "lake-manifest.json")
  let pins ← array (← field Runtime.lock "packages")
  let entries ← array (← field manifest "packages")
  ensure (pins.size == 3 && entries.size == 3) "all dependencies must be direct pins"
  let lakefile ← IO.FS.readFile (home / "lakefile.lean")
  for pin in pins do
    let revision ← text pin "rev"
    let name ← text pin "name"
    ensure (revision.length == 40) "pin is not an exact SHA"
    ensure (entries.any fun entry => optText entry "name" == some name && optText entry "rev" == some revision) "manifest drift"
    ensure ((lakefile.splitOn revision).length > 1) "Lake requirement drift"
  IO.println "Native unit checks passed."

private def invoke (cli bp assurance output : FilePath) (refresh : Bool) (expected : UInt32)
    (extra : Array String := #[]) : IO Json := do
  let args := #["check", bp.toString, assurance.toString, "--json", "--output", output.toString, "--timeout", "900"] ++
    (if refresh then #["--refresh-environment"] else #[]) ++ extra
  let response ← IO.Process.output {
    cmd := cli.toString
    args := args
    cwd := some "/tmp"
    env := #[("CARDANO_BLASTER_HOME", none), ("LEAN_PATH", none), ("LEAN_SYSROOT", none),
      ("PATH", some ((output / "forbidden-tools").toString ++ ":/usr/bin:/bin"))]
    inheritEnv := true }
  let report ← parseJson response.stdout
  unless response.exitCode == expected && (report.getObjValAs? Nat "exitCode").toOption == some expected.toNat do
    throw <| IO.userError (report.pretty ++ "\n" ++ response.stderr)
  IO.println s!"{assurance.parent.get!.fileName.getD "case"}: {← text report "status"}"
  return report

private def deadline (home : FilePath) : IO Unit :=
  IO.FS.withTempDir fun folder => do
    let driver := folder / "Delay.lean"
    IO.FS.writeFile driver "import Lean\n#eval IO.sleep 10000\n"
    let outcome ← try
      let code ← runWorker home driver (folder / "delay.log") (home / "bin/z3") 1
      pure s!"worker exited with code {code}: {← IO.FS.readFile (folder / "delay.log")}"
    catch error => pure error.toString
    ensure ((outcome.splitOn "timed out").length > 1) s!"controlled worker deadline not enforced: {outcome}"

private def integration (cli examples output : FilePath) : IO Unit := do
  IO.FS.createDirAll output
  let guards := output / "forbidden-tools"
  IO.FS.createDirAll guards
  for name in ["python", "python3", "lean", "lake", "git", "cc", "c++", "gcc", "g++", "clang", "clang++",
      "ghc", "runghc", "runhaskell", "cabal", "stack", "nix", "nix-shell"] do
    let path := guards / name
    IO.FS.writeFile path "#!/bin/sh\nexit 97\n"
    discard <| IO.Process.run { cmd := "chmod", args := #["755", path.toString] }
  let mut reports : Array Json := #[]
  for (name, code, count) in [("game", 0, 3), ("parameters", 0, 6), ("recursive", 0, 4),
      ("auction", 0, 31), ("purpose-isolation", 0, 6),
      ("aiken-total-rejection", 1, 1),
      ("plinth-total-rejection", 1, 1),
      ("helper-counterexample", 1, 1), ("auction-counterexample", 1, 1),
      ("purpose-isolation-counterexample", 1, 2)] do
    let report ← invoke cli (examples / name / "plutus.json") (examples / name / "assurance.json") output true code
    let results ← array (← field report "results")
    ensure (results.size == count) "missing property outcomes"
    let runtime ← field report "runtime"
    ensure ((runtime.getObjValAs? Bool "pinned").toOption == some true) "unbound runtime"
    ensure (optText runtime "distribution" == some "native-bundle") "test must use the standalone bundle"
    ensure (optText report "plutusVersion" == some (if name == "game" || name == "parameters" then "v2" else "v3"))
      "blueprint version not recorded"
    if code == 0 then
      if name == "purpose-isolation" then
        ensure (optText report "status" == some "witnessed" &&
          (results.filter fun r => (r.getObjValAs? Bool "expectationMet").toOption == some true).size == 3 &&
          (results.filter fun r => optText r "outcome" == some "verified").size == 3)
          "purpose isolation and acceptance witness results are not independent"
      else
        ensure (results.all fun r => optText r "outcome" == some "verified") "true claim not verified"
    else
      if name == "aiken-total-rejection" || name == "plinth-total-rejection" then
        ensure (optText results[0]! "outcome" == some "verified" &&
          (results[0]!.getObjValAs? Bool "expectationMet").toOption == some false &&
          results[0]!.getObjValD "counterexample" == Json.null)
          "total rejection must defeat the generated acceptance expectation"
      else
        if name == "purpose-isolation-counterexample" then
          ensure (optText results[1]! "outcome" == some "falsified" &&
            (results[1]!.getObjValAs? Bool "expectationMet").toOption == some true)
            "independent acceptance witness was not confirmed"
        let cex ← field results[0]! "counterexample"
        let model ← field cex "model"
        ensure (!(← array (← field model "bindings")).isEmpty) "typed witness missing"
        let replay ← field cex "replay"
        ensure (optText replay "status" == some "confirmed") "compiled replay not confirmed"
        ensure ((replay.getObjValAs? Bool "propertyHolds").toOption == some false) "mutant holds"
        ensure (!(← array (← field replay "calls")).isEmpty) "replay did not reach compiled UPLC"
        let source ← field cex "source"
        ensure (optText source "status" == some "exported") s!"Haskell source missing: {source.compress}"
        ensure (optText source "compilation" == some "not-run") "export claims unperformed compilation"
        let file ← field source "file"
        let hs ← IO.FS.readFile ((← string (← field report "artifacts")) / (← text file "uri") : System.FilePath)
        let contexts ← array (← field source "contexts")
        if contexts.isEmpty then
          ensure ((hs.splitOn "decodeData").length == 1) "scalar witness unexpectedly uses Haskell FromData"
        else
          ensure ((hs.splitOn "decodeData").length > 1) "encoded witness does not use Haskell FromData"
        let folder : FilePath := ← text report "artifacts"
        ensure ((← hashFile (folder / (← text file "uri"))) == (← text (← field file "hash") "digest")) "Haskell file digest differs"
        if name == "auction-counterexample" then
          ensure (!(← array (← field source "contexts")).isEmpty) "typed ScriptContext source missing"
          for token in ["proposed =", "locked =", "ctx :: V3.ScriptContext", "ctxData :: V3.Data"] do
            ensure ((hs.splitOn token).length > 1) s!"source witness lost {token}"
        if name == "purpose-isolation-counterexample" then
          ensure (!(← array (← field source "contexts")).isEmpty) "typed purpose-isolation context missing"
          for token in [":: V3.ScriptContext", ":: V3.Data", "decodeData"] do
            ensure ((hs.splitOn token).length > 1) s!"source witness lost {token}"
    reports := reports.push report
  let derived : FilePath := ← text reports[0]! "artifacts"
  reports := reports.push (← invoke cli (derived / "plutus.json") (derived / "assurance.json") output false 0)
  reports := reports.push (← invoke cli (examples / "game/plutus.json") (examples / "auction/assurance.json") output true 3)
  let additional ← IO.FS.withTempDir fun folder => do
    let game ← readJson (examples / "game/assurance.json")
    let note := obj [("id", toJson "notes"), ("scope", obj [("validators", toJson #["gameValidator"])]),
      ("statement", obj [("text", toJson "Documentation only")])]
    let notes := put (put game "properties" (.arr #[note])) "checkingContexts" (obj [])
    writeJson (folder / "notes.json") notes
    let report ← invoke cli (examples / "game/plutus.json") (folder / "notes.json") output true 2
    ensure (optText (← array (← field report "results"))[0]! "outcome" == some "not-checked") "unchecked claim passed"
    deadline cli.parent.get!.parent.get!
    return #[report]
  reports := reports ++ additional
  let readme := cli.parent.get!.parent.get! / "README.txt"
  let original ← IO.FS.readFile readme
  try
    IO.FS.writeFile readme (original ++ "\ntampered\n")
    let report ← invoke cli (examples / "game/plutus.json") (examples / "game/assurance.json") output true 3
    ensure ((optText report "error").any fun e => (e.splitOn "integrity").length > 1) "modified runtime accepted"
    reports := reports.push report
  finally IO.FS.writeFile readme original
  writeJson (output / "summary.json") (.arr reports)
  IO.println "48 verified properties, 4 acceptance witnesses, 3 unexpected falsifications and strict replay checks passed with native Lean."

unsafe def main (args : List String) : IO UInt32 := do
  try
    match args with
    | "--internal-frontend" :: _ => CardanoBlaster.dispatch args
    | ["unit"] => unit; return (0 : UInt32)
    | ["codecs", fixtures, output] =>
      let fixtures ← array (← readJson fixtures)
      let mut declarations := ""
      let mut checks : Array String := #[]
      for i in [:fixtures.size] do
        let f := fixtures[i]!
        let ty ← text f "type"
        let wire ← field f "wire"
        let value ← IO.ofExcept <| (SourceValue.render Counterexample.plutusData
          (fun b => Counterexample.haskell b) ty wire).mapError (fun e => s!"codec {i} ({ty}): {e}")
        let indented := String.intercalate "\n" (value.splitOn "\n" |>.map ("  " ++ ·))
        declarations := declarations ++ s!"value{i} :: {SourceValue.typeName ty}\nvalue{i} =\n{indented}\n\n"
        checks := checks.push s!"V3.toData value{i} == {← IO.ofExcept (Counterexample.plutusData wire)}"
      IO.FS.writeFile output <| "{-# LANGUAGE DisambiguateRecordFields #-}\nmodule Main where\n" ++
        "import qualified Data.ByteString as BS\nimport qualified PlutusLedgerApi.V3 as V3\n" ++
        SourceValue.imports ++ "\n" ++ declarations ++ "main :: IO ()\nmain = if " ++
        String.intercalate " &&\n  " checks.toList ++ s!"\n  then putStrLn \"PASS {fixtures.size} Haskell codec round trips\"\n  else error \"Haskell codec mismatch\"\n"
      return (0 : UInt32)
    | ["deadline", home] => deadline home; return (0 : UInt32)
    | ["sources", summary, output] =>
      let reports ← array (← readJson summary)
      for i in [:reports.size] do
        let report := reports[i]!
        if optText report "status" == some "falsified" then
          let folder := System.FilePath.mk output / s!"case-{i}"
          IO.FS.createDirAll folder
          let results ← Counterexample.exportSources folder (← array (← field report "results"))
          let exported := results[0]!.getObjValD "counterexample" |>.getObjValD "source"
          ensure (optText exported "status" == some "exported") exported.pretty
      return (0 : UInt32)
    | ["integration", cli, examples, output] => integration cli examples output; return (0 : UInt32)
    | _ => IO.eprintln "native-tests unit | deadline <home> | integration <cli> <examples> <output> | sources <summary> <output> | codecs <fixtures.json> <output.hs>"; return (3 : UInt32)
  catch error => IO.eprintln error.toString; return (1 : UInt32)
