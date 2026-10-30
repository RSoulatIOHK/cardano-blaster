import CardanoBlaster.Cli

open Lean System CardanoBlaster

private def ensure (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def nativeReport (results : Array Json) : Json := obj [
  ("format", toJson "plinth-counterexample-report-v1"), ("assuranceSha256", toJson "aa"),
  ("blueprintSha256", toJson "bb"), ("results", .arr results)]

private def result (outcome : String) : Json := obj [("property", toJson "p"), ("outcome", toJson outcome)]

private def unit : IO Unit := do
  let classifyResults := fun results code => IO.ofExcept (classify (nativeReport results) #["p"] "aa" "bb" code)
  ensure ((← classifyResults #[] 0).1 == .inconclusive) "missing results cannot pass"
  ensure ((← classifyResults #[result "verified"] 1).1 == .error) "nonzero exit cannot pass"
  ensure ((← classifyResults #[result "inconclusive"] 1).1 == .inconclusive) "undetermined cannot pass"
  let cex := obj [("model", obj [("witness", toJson "exact value")]), ("replay", obj [("status", toJson "unavailable")])]
  let (outcome, results) ← classifyResults #[put (result "falsified") "counterexample" cex] 1
  ensure (outcome == .falsified && results[0]!.getObjValD "counterexample" == cex) "preserve CEX and replay separately"
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

private def integration (cli examples output : FilePath) : IO Unit := do
  IO.FS.createDirAll output
  let guards := output / "forbidden-tools"
  IO.FS.createDirAll guards
  for name in ["python", "python3", "lean", "lake", "git", "cc", "c++", "gcc", "g++", "clang", "clang++"] do
    let path := guards / name
    IO.FS.writeFile path "#!/bin/sh\nexit 97\n"
    discard <| IO.Process.run { cmd := "chmod", args := #["755", path.toString] }
  let mut reports : Array Json := #[]
  for (name, code, count) in [("game", 0, 3), ("parameters", 0, 6), ("recursive", 0, 4),
      ("auction", 0, 31), ("helper-counterexample", 1, 1), ("auction-counterexample", 1, 1)] do
    let report ← invoke cli (examples / name / "plutus.json") (examples / name / "assurance.json") output true code
    let results ← array (← field report "results")
    ensure (results.size == count) "missing property outcomes"
    let runtime ← field report "runtime"
    ensure ((runtime.getObjValAs? Bool "pinned").toOption == some true) "unbound runtime"
    ensure (optText runtime "distribution" == some "native-bundle") "test must use the standalone bundle"
    if code == 0 then
      ensure (results.all fun r => optText r "outcome" == some "verified") "true claim not verified"
    else
      let cex ← field results[0]! "counterexample"
      let model ← field cex "model"
      ensure (!(← array (← field model "bindings")).isEmpty) "typed witness missing"
      let replay ← field cex "replay"
      ensure (optText replay "status" == some "confirmed") "compiled replay not confirmed"
      ensure ((replay.getObjValAs? Bool "propertyHolds").toOption == some false) "mutant holds"
      ensure (!(← array (← field replay "calls")).isEmpty) "replay did not reach compiled UPLC"
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
    let driver := folder / "Delay.lean"
    IO.FS.writeFile driver "import Lean\n#eval IO.sleep 10000\n"
    let home := cli.parent.get!.parent.get!
    let mut expired := false
    try
      discard <| runWorker home driver (folder / "delay.log") (home / "bin/z3") 1
    catch error => expired := (error.toString.splitOn "timed out").length > 1
    ensure expired "controlled worker deadline not enforced"
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
  IO.println "44 true properties, 2 typed/replayed CEX, strict replay and failure cases passed with native Lean."

unsafe def main (args : List String) : IO UInt32 := do
  try
    match args with
    | "--internal-frontend" :: _ => CardanoBlaster.dispatch args
    | ["unit"] => unit; return (0 : UInt32)
    | ["integration", cli, examples, output] => integration cli examples output; return (0 : UInt32)
    | _ => IO.eprintln "native-tests unit | integration <cli> <examples> <output>"; return (3 : UInt32)
  catch error => IO.eprintln error.toString; return (1 : UInt32)
