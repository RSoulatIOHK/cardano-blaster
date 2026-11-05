import CardanoBlaster.Json
import CardanoBlaster.Counterexample.Legacy

namespace CardanoBlaster
open Lean System

inductive Outcome where
  | verified | witnessed | falsified | inconclusive | error
  deriving BEq, Repr

def Outcome.label : Outcome → String
  | .verified => "verified" | .witnessed => "witnessed" | .falsified => "falsified"
  | .inconclusive => "inconclusive" | .error => "error"
def Outcome.exitCode : Outcome → UInt32
  | .verified => 0 | .witnessed => 0 | .falsified => 1 | .inconclusive => 2 | .error => 3

inductive Profile where
  | core | cardanoV3 | cardanoV3Cex
  deriving BEq, Repr

def Profile.label : Profile → String
  | .core => "core" | .cardanoV3 => "cardano-v3" | .cardanoV3Cex => "cardano-v3-cex"
def Profile.parse : String → Except String Profile
  | "core" => .ok .core | "cardano-v3" => .ok .cardanoV3
  | "cardano-v3-cex" => .ok .cardanoV3Cex
  | x => .error s!"unknown import profile: {x}"
def Profile.header (p : Profile) : String :=
  "import PlutusCore.UPLC.BlueprintEncoding.Assurance\n" ++
  (if p == .core then "" else "import CardanoLedgerApi.V3\n") ++
  (if p == .cardanoV3Cex then
    "import CardanoLedgerApi.Counterexample.V3\nimport CardanoBlaster.Counterexample.Legacy\n" else "") ++
  (if p == .core then "" else
    "open PlutusCore.ByteString\nopen PlutusCore.Integer\nopen PlutusCore.Data (Data)\n" ++
    "open CardanoLedgerApi.IsData.Class\nopen CardanoLedgerApi.V3\n" ++
    "open CardanoLedgerApi.V3.Contexts\nopen CardanoLedgerApi.V3.Tx\n")

structure Options where
  blueprint : FilePath
  assurance : FilePath
  output : FilePath := "cardano-blaster-results"
  profile : Option Profile := none
  properties : Array String := #[]
  z3 : Option FilePath := none
  sourceTypes : Option FilePath := none
  refresh : Bool := false
  json : Bool := false
  timeout : Nat := 1800
  deriving Inhabited

def usage : String := "cardano-blaster check <plutus.json> <assurance.json> [options]\n\n" ++
  "  --property ID           Select a property (repeatable)\n" ++
  "  --refresh-environment   Create fresh checking contexts for this runtime\n" ++
  "  --profile PROFILE       auto | core | cardano-v3 | cardano-v3-cex\n" ++
  "  --z3 PATH               Use an explicit solver executable\n" ++
  "  --source-types PATH     Use a blueprint-bound Plinth Haskell type manifest\n" ++
  "  --output DIR            Store fresh reports and checking artifacts\n" ++
  "  --timeout SECONDS       Bound each embedded verification worker\n" ++
  "  --json                  Print the final JSON report\n\n" ++
  "cardano-blaster setup    Install the locked Z3 release for a source build\n" ++
  "cardano-blaster --version\n"

partial def parseOptions (args : List String) (opts : Options) : Except String Options := do
  match args with
  | [] => return opts
  | "--refresh-environment" :: rest => parseOptions rest { opts with refresh := true }
  | "--json" :: rest => parseOptions rest { opts with json := true }
  | "--output" :: path :: rest => parseOptions rest { opts with output := path }
  | "--property" :: id :: rest => parseOptions rest { opts with properties := opts.properties.push id }
  | "--z3" :: path :: rest => parseOptions rest { opts with z3 := some path }
  | "--source-types" :: path :: rest => parseOptions rest { opts with sourceTypes := some path }
  | "--profile" :: "auto" :: rest => parseOptions rest { opts with profile := none }
  | "--profile" :: value :: rest => parseOptions rest { opts with profile := some (← Profile.parse value) }
  | "--timeout" :: value :: rest =>
    let some timeout := value.toNat? | throw "--timeout must be a positive integer"
    if timeout == 0 then throw "--timeout must be positive"
    parseOptions rest { opts with timeout }
  | flag :: _ => throw s!"unknown or incomplete option: {flag}"

end CardanoBlaster
