import CardanoBlaster.Frontend
import CardanoBlaster.Counterexample

namespace CardanoBlaster
open Lean System

def classify (native : Json) (expected : Array String) (assuranceHash blueprintHash : String)
    (code : UInt32) : Except String (Outcome × Array Json) := do
  unless (← native.getObjValAs? String "format") == "plinth-counterexample-report-v1" do
    throw "unsupported verifier report format"
  unless (← native.getObjValAs? String "assuranceSha256") == assuranceHash &&
      (← native.getObjValAs? String "blueprintSha256") == blueprintHash do
    throw "verifier report does not bind the checked inputs"
  let mut results ← (← native.getObjVal? "results").getArr?
  let mut seen : Array String := #[]
  let mut outcomes : Array String := #[]
  for result in results do
    let name ← result.getObjValAs? String "property"
    let outcome ← result.getObjValAs? String "outcome"
    unless expected.contains name && !seen.contains name &&
        ["verified", "falsified", "inconclusive", "not-checked"].contains outcome do
      throw "invalid or duplicate property result in verifier report"
    seen := seen.push name
    outcomes := outcomes.push outcome
  if code != 0 && !outcomes.contains "falsified" && !outcomes.contains "inconclusive" then
    return (.error, results)
  let outcome := if outcomes.contains "falsified" then Outcome.falsified
    else if outcomes.contains "inconclusive" || outcomes.contains "not-checked" || seen.size != expected.size
      then Outcome.inconclusive else Outcome.verified
  for name in expected do
    if !seen.contains name then
      results := results.push (obj [("property", toJson name), ("outcome", toJson "not-checked"), ("counterexample", .null)])
  return (outcome, results)

private def chooseProfile (environments : Array Json) : IO Profile := do
  let mut chosen : Option Profile := none
  for env in environments do
    let modules ← field env "modules"
    let profile := if (modules.getObjVal? "CardanoLedgerApi.Counterexample.V3").isOk then Profile.cardanoV3Cex
      else if (modules.getObjVal? "CardanoLedgerApi.V3").isOk then Profile.cardanoV3 else Profile.core
    if let some old := chosen then
      if old != profile then throw <| IO.userError "checking contexts need different import profiles; select properties separately"
    chosen := some profile
  return chosen.getD .core

private def progress (options : Options) (s : String) : IO Unit :=
  unless options.json do IO.eprintln s

private def record (report : IO.Ref Json) (key : String) (value : Json) : IO Unit :=
  report.modify (put · key value)

def check (options : Options) (run : FilePath) (report : IO.Ref Json) : IO Outcome := do
  let blueprint ← IO.FS.realPath options.blueprint
  let assurancePath ← IO.FS.realPath options.assurance
  let blueprintBytes ← IO.FS.readBinFile blueprint
  let assuranceBytes ← IO.FS.readBinFile assurancePath
  let some source := String.fromUTF8? assuranceBytes | throw <| IO.userError "assurance is not UTF-8"
  let mut assurance ← parseJson source
  let some bpSource := String.fromUTF8? blueprintBytes | throw <| IO.userError "blueprint is not UTF-8"
  discard <| parseJson bpSource
  let blueprintHash ← digestBytes blueprintBytes
  let assuranceHash ← digestBytes assuranceBytes
  let mut inputs : Inputs := #[(blueprint.toString, blueprintHash), (assurancePath.toString, assuranceHash)]
  record report "inputs" (obj (inputs.toList.map (fun (k, v) => (k, toJson v))))
  let blueprintRef ← field (← field assurance "blueprint") "hash"
  unless ["sha256", "sha-256"].contains (← text blueprintRef "alg").toLower &&
      (← text blueprintRef "digest") == blueprintHash do
    throw <| IO.userError "the supplied blueprint does not match the assurance blueprint digest"
  let properties ← array (← field assurance "properties")
  let ids ← properties.mapM (text · "id")
  unless !ids.isEmpty && ids.all (!·.isEmpty) && ids.toList.eraseDups.length == ids.size do
    throw <| IO.userError "assurance must contain nonempty, unique property identifiers"
  for id in options.properties do
    unless ids.contains id do throw <| IO.userError s!"unknown property: {id}"
  let properties := if options.properties.isEmpty then properties
    else properties.filter fun p => (optText p "id").any options.properties.contains
  let expected ← properties.mapM (text · "id")
  record report "selectedProperties" (toJson expected)
  let mut contexts : Array (String × FilePath × Json) := #[]
  let mut environments : Array Json := #[]
  for prop in properties do
    if let some key := optText prop "checkingContext" then
      unless contexts.any (fun (k, _, _) => k == key) do
        let ref ← field (← field assurance "checkingContexts") key
        let ((path, ctx), updated) ← (checkedJson assurancePath.parent.get! ref).run inputs
        inputs := updated
        let ((_, env), updated) ← (checkedJson path.parent.get! (← field ctx "environment")).run inputs
        inputs := updated
        contexts := contexts.push (key, path, ctx)
        environments := environments.push env
  let profile ← match options.profile with
    | some p => pure p | none => chooseProfile environments
  record report "profile" (toJson profile.label)
  let home ← Runtime.root
  record report "project" (toJson home.toString)
  record report "runtime" (← Runtime.validate home)
  let solver ← Runtime.solver home options.z3
  record report "solver" (← Runtime.solverInfo solver options.z3.isSome)
  -- The checker invokes `z3` by name. Preserve explicit solver selection even
  -- when the supplied executable has a different basename.
  IO.FS.createDirAll (run / "bin")
  discard <| IO.Process.run { cmd := "ln", args := #["-s", solver.toString, (run / "bin/z3").toString] }
  let selectedSolver := run / "bin/z3"
  let checkedBlueprint := run / "plutus.json"
  IO.FS.writeBinFile checkedBlueprint blueprintBytes
  assurance ← absoluteUris assurance assurancePath.parent.get!
  assurance := put assurance "properties" (.arr (← properties.mapM (absoluteUris · assurancePath.parent.get!)))
  assurance := put assurance "blueprint" (put (← field assurance "blueprint") "uri" (toJson "plutus.json"))
  if options.refresh then
    progress options "Capturing the checking environment…"
    let capture := run / "Environment.lean"
    let environmentPath := run / "environment.json"
    IO.FS.writeFile capture (profile.header ++ "#write_checking_environment " ++ (toJson environmentPath.toString).compress ++ "\n")
    let code ← runWorker home capture (run / "environment.log") selectedSolver options.timeout
    unless code == 0 do throw <| IO.userError "environment capture failed; see environment.log"
    let environmentHash ← hashFile environmentPath
    let mut references ← field assurance "checkingContexts"
    for i in [:contexts.size] do
      let (key, path, context) := contexts[i]!
      let fields ← IO.ofExcept context.getObj?
      let withoutEnvironment := obj (fields.toList.filter (·.1 != "environment"))
      let (ctx, updated) ← (snapshotAssets withoutEnvironment path.parent.get! run).run inputs
      inputs := updated
      let ctx := put ctx "environment" (digestRef "environment.json" environmentHash)
      let name := s!"checking-{i}.json"
      writeJson (run / name) ctx
      references := put references key (digestRef name (← hashFile (run / name)))
    assurance := put assurance "checkingContexts" references
    record report "environmentSha256" (toJson environmentHash)
  record report "inputs" (obj (inputs.toList.map (fun (k, v) => (k, toJson v))))
  record report "environmentRefreshed" (toJson options.refresh)
  let checkedPath := run / "assurance.json"
  writeJson checkedPath assurance
  let nativePath := run / "verifier-report.json"
  let driver := run / "Check.lean"
  IO.FS.writeFile driver (profile.header ++ "#verify_blueprint CardanoBlasterCheck " ++
    (toJson checkedPath.toString).compress ++ " " ++ (toJson checkedBlueprint.toString).compress ++
    " cex_report " ++ (toJson nativePath.toString).compress ++ "\n")
  progress options s!"Checking {expected.size} properties…"
  let code ← runWorker home driver (run / "verification.log") selectedSolver options.timeout
  record report "verifierExitCode" (toJson code.toNat)
  unless ← nativePath.pathExists do throw <| IO.userError "checker did not produce a complete report; see verification.log"
  discard <| Runtime.validate home
  for (path, originalHash) in inputs do
    unless (← hashFile path) == originalHash do throw <| IO.userError s!"input artifact changed during verification: {path}"
  let (outcome, results) ← IO.ofExcept (classify (← readJson nativePath) expected
    (← hashFile checkedPath) (← hashFile checkedBlueprint) code)
  record report "results" (.arr (← Counterexample.exportSources run results))
  record report "checkedAssuranceSha256" (toJson (← hashFile checkedPath))
  record report "verifierReportSha256" (toJson (← hashFile nativePath))
  record report "verificationLogSha256" (toJson (← hashFile (run / "verification.log")))
  return outcome

private def createRun (output : FilePath) : IO FilePath := do
  IO.FS.createDirAll output
  let output ← IO.FS.realPath output
  for _ in [:32] do
    let path := output / s!"run-{← IO.rand 0 18446744073709551615}"
    try
      IO.FS.createDir path
      return path
    catch error => if !(← path.pathExists) then throw error
  throw <| IO.userError "could not create a unique run directory"

def printResults (report : Json) : IO Unit := do
  for result in (← array (← field report "results")) do
    IO.println s!"{← text result "outcome"}  {terminalText (← text result "property")}"
    let cex := result.getObjValD "counterexample"
    let replay := cex.getObjValD "replay"
    if let some status := optText replay "status" then IO.println s!"  replay: {terminalText status}"
    let source := cex.getObjValD "source"
    if optText source "status" == some "exported" then
      IO.println s!"  Haskell: {← text report "artifacts"}/{← text (← field source "file") "uri"}"
      for input in (← array (← field source "inputs")) do
        if let some ty := optText input "sourceType" then
          IO.println s!"  {terminalText (← text input "identifier")} :: {terminalText ty} (decoded from replayed Data)"
        else
          IO.println s!"  {terminalText (← text input "name")} = {terminalText (← text input "expression")}"
      for context in (← array (← field source "contexts")) do
        IO.println s!"  {terminalText (← text context "identifier")} :: {terminalText (← text context "haskellType")}"
    else if let some reason := optText source "reason" then
      IO.println s!"  Haskell unavailable: {terminalText reason}"
    if optText source "status" != some "exported" then
      for input in (replay.getObjValAs? (Array Json) "inputs").toOption.getD #[] do
        let value := (input.getObjValD "value").compress
        IO.println s!"  {terminalText (← text input "name")} = {terminalText (value.take 180)}"
  if let some error := optText report "error" then IO.eprintln s!"error: {terminalText error}"
  IO.println s!"{← text report "status"}; report: {← text report "artifacts"}/report.json"

def runCheck (options : Options) : IO UInt32 := do
  let start ← IO.monoMsNow
  let run ← createRun options.output
  let report ← IO.mkRef <| obj [("format", toJson "cardano-blaster-check-v1"),
    ("created", toJson (toString (← Std.Time.Timestamp.now).toPlainDateTimeAssumingUTC)),
    ("inputs", obj []), ("results", .arr #[]), ("artifacts", toJson run.toString),
    ("tool", obj [("name", toJson "cardano-blaster"), ("version", toJson Runtime.version),
      ("implementation", toJson "Lean 4 native"), ("executableSha256", toJson (← hashFile (← IO.appPath)))]),
    ("method", toJson "Blaster SMT and declared execution bounds; no reconstructed Lean proof")]
  let outcome ← try check options run report catch error => do
    record report "error" (toJson error.toString)
    for name in ["verification.log", "environment.log"] do
      if ← (run / name).pathExists then
        let lines := (← IO.FS.readFile (run / name)).splitOn "\n"
        record report "diagnostics" (toJson (String.intercalate "\n" (lines.drop (lines.length - 20))))
        break
    pure .error
  record report "status" (toJson outcome.label)
  record report "exitCode" (toJson outcome.exitCode.toNat)
  let elapsed := (← IO.monoMsNow) - start
  record report "elapsedMilliseconds" (toJson elapsed)
  record report "elapsedSeconds" (.num ⟨Int.ofNat elapsed, 3⟩)
  let result ← report.get
  writeJson (run / "report.json") result
  if options.json then IO.println result.compress else printResults result
  return outcome.exitCode

end CardanoBlaster
