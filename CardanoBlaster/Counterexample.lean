import CardanoBlaster.Json

namespace CardanoBlaster.Counterexample
open Lean System

private def get (j : Json) (key : String) : Except String Json := j.getObjVal? key
private def str (j : Json) (key : String) : Except String String := j.getObjValAs? String key
private def arr (j : Json) (key : String) : Except String (Array Json) := j.getObjValAs? (Array Json) key

private def fields (j : Json) (names : Array String) : Except String (Array Json) := do
  let fs ← arr j "fields"
  unless (← fs.mapM (str · "name")) == names do throw "unexpected constructor fields"
  fs.mapM (get · "value")

private def integer (j : Json) : Except String String := do
  let kind ← str j "kind"
  unless kind == "integer" || kind == "natural" do throw "expected an integer"
  let raw ← str j "value"
  let some n := raw.toInt? | throw "invalid integer literal"
  unless toString n == raw && (kind != "natural" || n ≥ 0) do throw "noncanonical integer literal"
  return raw

private def hexDigit (n : Nat) : Char := Char.ofNat (if n < 10 then 48 + n else 87 + n)
private partial def hex (n : Nat) : String :=
  if n < 16 then String.singleton (hexDigit n) else hex (n / 16) ++ String.singleton (hexDigit (n % 16))

/-- Haskell numeric escapes need a terminator before a following hex digit. -/
def quote (s : String) : String := "\"" ++ String.join (s.toList.map fun c =>
  match c with
  | '"' => "\\\"" | '\\' => "\\\\" | '\n' => "\\n" | '\r' => "\\r" | '\t' => "\\t"
  | _ => if 32 ≤ c.toNat && c.toNat ≤ 126 then String.singleton c else "\\x" ++ hex c.toNat ++ "\\&") ++ "\""

private def bytes (j : Json) : Except String String := do
  unless (← str j "kind") == "bytes" do throw "expected bytes"
  let raw ← str j "hex"
  unless raw.length % 2 == 0 do throw "invalid byte encoding"
  let nibble (c : Char) : Except String Nat :=
    if '0' ≤ c && c ≤ '9' then pure (c.toNat - 48)
    else if 'a' ≤ c && c ≤ 'f' then pure (c.toNat - 87)
    else throw "invalid byte encoding"
  let mut values : Array String := #[]
  let cs := raw.toList.toArray
  for i in [:cs.size / 2] do
    values := values.push (toString (16 * (← nibble cs[2 * i]!) + (← nibble cs[2 * i + 1]!)))
  return "BS.pack [" ++ String.intercalate ", " values.toList ++ "]"

/-- Render only the canonical portable Plutus Data representation. -/
partial def plutusData (j : Json) : Except String String := do
  unless (← str j "kind") == "constructor" && (← str j "type") == "PlutusCore.Data" do
    throw "expected canonical Plutus Data"
  match ← str j "constructor" with
  | "I" => return "V3.I (" ++ (← integer (← fields j #["value"])[0]!) ++ ")"
  | "B" => return "V3.B (" ++ (← bytes (← fields j #["value"])[0]!) ++ ")"
  | "List" =>
    let xs := (← fields j #["values"])[0]!
    unless (← str xs "kind") == "list" do throw "expected Data list"
    return "V3.List [" ++ String.intercalate ", " (← (← arr xs "values").toList.mapM plutusData) ++ "]"
  | "Map" =>
    let xs := (← fields j #["entries"])[0]!
    unless (← str xs "kind") == "list" do throw "expected Data map entries"
    let entries ← (← arr xs "values").mapM fun pair => do
      unless (← str pair "kind") == "constructor" && (← str pair "type") == "Prod" &&
          (← str pair "constructor") == "Prod.mk" do throw "expected Data map pair"
      let fs ← fields pair #["fst", "snd"]
      return "(" ++ (← plutusData fs[0]!) ++ ", " ++ (← plutusData fs[1]!) ++ ")"
    return "V3.Map [" ++ String.intercalate ", " entries.toList ++ "]"
  | "Constr" =>
    let fs ← fields j #["index", "fields"]
    unless (← str fs[1]! "kind") == "list" do throw "expected Data constructor fields"
    return "V3.Constr (" ++ (← integer fs[0]!) ++ ") [" ++
      String.intercalate ", " (← (← arr fs[1]! "values").toList.mapM plutusData) ++ "]"
  | _ => throw "unsupported Plutus Data constructor"

-- Empty lists and Nothing are polymorphic. Track their shape to reject a
-- malformed codec that would otherwise emit an ill-typed heterogeneous list.
private inductive Shape where
  | unknown | atom (name : String) | list (element : Shape) | option (element : Shape) | pair (a b : Shape)
  deriving Inhabited, BEq

private partial def merge (a b : Shape) : Except String Shape := do
  match a, b with
  | .unknown, b => return b
  | a, .unknown => return a
  | .list a, .list b => return .list (← merge a b)
  | .option a, .option b => return .option (← merge a b)
  | .pair a b, .pair c d => return .pair (← merge a c) (← merge b d)
  | a, b => if a == b then return a else throw "inconsistent source types in list"

private structure Expression where
  source : String
  shape : Shape
  deriving Inhabited

private def sourceType (name : String) : Except String String :=
  match name with
  | "PlutusLedgerApi.V3.ScriptContext" => pure "V3.ScriptContext"
  | "PlutusLedgerApi.V3.TxInfo" => pure "V3.TxInfo"
  | "PlutusLedgerApi.V3.ScriptInfo" => pure "V3.ScriptInfo"
  | _ => throw s!"unsupported Haskell source type: {name}"

private partial def expression (j : Json) : Except String Expression := do
  match ← str j "kind" with
  | "integer" | "natural" => return ⟨"(" ++ (← integer j) ++ " :: Integer)", .atom "Integer"⟩
  | "boolean" =>
    let b ← j.getObjValAs? Bool "value"
    return ⟨if b then "True" else "False", .atom "Bool"⟩
  | "string" => return ⟨quote (← str j "value"), .atom "String"⟩
  | "bytes" => return ⟨(← bytes j), .atom "ByteString"⟩
  | "unit" => return ⟨"()", .atom "Unit"⟩
  | "list" =>
    let xs ← (← arr j "values").mapM expression
    let mut shape := Shape.unknown
    for x in xs do shape ← merge shape x.shape
    return ⟨"[" ++ String.intercalate ", " (xs.toList.map (·.source)) ++ "]", .list shape⟩
  | "encoded" =>
    unless (← str j "encoding") == "plutus-data" do throw "unsupported source encoding"
    let ty ← sourceType (← str j "type")
    return ⟨"(decodeData @" ++ ty ++ " (" ++ (← plutusData (← get j "value")) ++ "))", .atom ty⟩
  | "constructor" =>
    let ty ← str j "type"
    let ctor ← str j "constructor"
    if ty == "PlutusCore.Data" then return ⟨(← plutusData j), .atom "Data"⟩
    if ty == "Prod" && ctor == "Prod.mk" then
      let fs ← fields j #["fst", "snd"]
      let a ← expression fs[0]!
      let b ← expression fs[1]!
      return ⟨"(" ++ a.source ++ ", " ++ b.source ++ ")", .pair a.shape b.shape⟩
    if ty == "Option" then
      if ctor == "Option.none" then
        discard <| fields j #[]
        return ⟨"Nothing", .option .unknown⟩
      if ctor == "Option.some" then
        let v ← expression (← fields j #["value"])[0]!
        return ⟨"(Just " ++ v.source ++ ")", .option v.shape⟩
    throw s!"unsupported Haskell constructor: {ty}.{ctor}"
  | _ => throw "counterexample value is unavailable or unsupported"

def haskell (j : Json) : Except String String := return (← expression j).source

private def completeValue (binding : Json) : Except String Json := do
  unless (← get binding "error") == .null do throw "counterexample contains an incomplete value"
  get binding "value"

private partial def usesLedger (value : Json) : Bool :=
  optText value "kind" == some "encoded" || optText value "type" == some "PlutusCore.Data" ||
  ((value.getObjValAs? (Array Json) "values").toOption.getD #[]).any usesLedger ||
  ((value.getObjValAs? (Array Json) "fields").toOption.getD #[]).any (usesLedger ∘ (·.getObjValD "value"))

private partial def usesBytes (value : Json) : Bool :=
  optText value "kind" == some "bytes" ||
  ((value.getObjValAs? (Array Json) "values").toOption.getD #[]).any usesBytes ||
  ((value.getObjValAs? (Array Json) "fields").toOption.getD #[]).any (usesBytes ∘ (·.getObjValD "value")) ||
  (optText value "kind" == some "encoded" && usesBytes (value.getObjValD "value"))

/-- Construct source only from a confirmed replay and complete typed values.
Never infer a source type from the wire encoding or a Lean display name. -/
def prepare (result : Json) : Except String (String × Json) := do
  let cex ← get result "counterexample"
  let replay ← get cex "replay"
  unless (← str replay "status") == "confirmed" && !(← replay.getObjValAs? Bool "propertyHolds") do
    throw "source export requires a confirmed falsifying replay"
  let bindings ← arr (← get cex "model") "bindings"
  unless !bindings.isEmpty do throw "counterexample has no typed bindings"
  let mut declarations : Array String := #[]
  let mut inputs : Array Json := #[]
  let mut needsLedger := false
  let mut needsBytes := false
  for i in [:bindings.size] do
    let binding := bindings[i]!
    let typed ← completeValue binding
    let value ← haskell typed
    needsLedger := needsLedger || usesLedger typed
    needsBytes := needsBytes || usesBytes typed
    let name := s!"input{i}"
    declarations := declarations.push s!"{name} = {value}\n"
    inputs := inputs.push (obj [("name", toJson (← str binding "name")), ("identifier", toJson name),
      ("leanType", toJson (← str binding "leanType")), ("expression", toJson value)])
  let mut contexts : Array Json := #[]
  let mut checks : Array String := #[]
  let mut seen : Array (Nat × Json) := #[]
  let calls ← arr replay "calls"
  for callIndex in [:calls.size] do
    let call := calls[callIndex]!
    unless ["halted", "rejected"].contains (← str call "outcome") do throw "compiled replay is unfinished"
    let arguments ← arr call "arguments"
    for source in (← arr call "sourceArguments") do
      let binding ← get source "argument"
      let value ← completeValue binding
      if optText value "kind" != some "encoded" then continue
      let ty ← sourceType (← str value "type")
      unless (← str value "encoding") == "plutus-data" do throw "unsupported source encoding"
      let wire ← get value "value"
      let mut argumentIndices : Array Nat := #[]
      for i in [:arguments.size] do
        if (← completeValue arguments[i]!) == wire then argumentIndices := argumentIndices.push i
      if argumentIndices.isEmpty then throw "source value does not match any replayed wire argument"
      if seen.contains (callIndex, value) then continue
      seen := seen.push (callIndex, value)
      needsLedger := true
      needsBytes := needsBytes || usesBytes value
      let name := s!"context{contexts.size}"
      declarations := declarations.push s!"{name} :: {ty}\n{name} = {← haskell value}\n\n{name}Data :: V3.Data\n{name}Data = {← plutusData wire}\n"
      checks := checks.push s!"V3.toData {name} == {name}Data"
      contexts := contexts.push (obj [("identifier", toJson name), ("sourceType", toJson (← str value "type")),
        ("callIndex", toJson callIndex), ("target", toJson (← str call "target")),
        ("argumentIndices", toJson argumentIndices), ("wireArgumentEncoding", toJson "tocex-json-v1"),
        ("wireArgumentSha256", toJson (hashBytes wire.compress.toUTF8))])
  let body := String.intercalate "\n" declarations.toList
  let imports := (if needsBytes then "import qualified Data.ByteString as BS\n" else "") ++
    (if needsLedger then "import qualified PlutusLedgerApi.V3 as V3\n\ndecodeData :: V3.FromData a => V3.Data -> a\ndecodeData d = case V3.fromData d of\n  Just value -> value\n  Nothing -> error \"Counterexample source decode failed\"\n" else "")
  let inputStrings := inputs.toList.map fun input =>
    "(" ++ quote ((str input "name").toOption.get!) ++ ", " ++ quote ((str input "expression").toOption.get!) ++ ")"
  let display := contexts.toList.map fun ctx => "    print " ++ (str ctx "identifier").toOption.get! ++ "\n"
  let main := if checks.isEmpty then "main = mapM_ print inputs\n" else
    "main = if " ++ String.intercalate " && " checks.toList ++ "\n  then do\n" ++
      "    putStrLn \"PASS Haskell source decode and exact Data round trip\"\n" ++ String.join display ++
      "    mapM_ print inputs\n  else error \"Reconstructed source differs from the replayed argument\"\n"
  let source := "{-# LANGUAGE TypeApplications #-}\nmodule Main where\n" ++ imports ++
    "\nproperty :: String\nproperty = " ++ quote (← str result "property") ++ "\n\n" ++ body ++
    "\ninputs :: [(String, String)]\ninputs = [" ++ String.intercalate ", " inputStrings ++ "]\n\nmain :: IO ()\n" ++ main
  return (source, obj [("status", toJson "exported"), ("language", toJson "haskell"),
    ("compilation", toJson "not-run"), ("inputs", .arr inputs), ("contexts", .arr contexts)])

/-- Source export failure remains distinct from the SMT verdict and CEK replay. -/
def exportSources (run : FilePath) (results : Array Json) : IO (Array Json) := do
  results.mapIdxM fun i result => do
    if optText result "outcome" != some "falsified" then return result
    let info ← match prepare result with
      | .error reason => pure <| obj [("status", toJson "unavailable"), ("language", toJson "haskell"), ("reason", toJson reason)]
      | .ok (source, info) => do
        -- Neither property identifiers nor source binder names become paths or
        -- Haskell identifiers. Both can contain arbitrary producer text.
        IO.FS.createDirAll (run / "counterexamples")
        let relative := s!"counterexamples/Counterexample{i}.hs"
        IO.FS.writeFile (run / relative) source
        pure <| put info "file" (digestRef relative (← hashFile (run / relative)))
    return put result "counterexample" (put (result.getObjValD "counterexample") "source" info)

end CardanoBlaster.Counterexample
