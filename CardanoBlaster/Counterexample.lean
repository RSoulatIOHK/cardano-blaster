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
  | "PlutusLedgerApi.V1.ScriptContext" => pure "V1.ScriptContext"
  | "PlutusLedgerApi.V2.ScriptContext" => pure "V2.ScriptContext"
  | "PlutusLedgerApi.V3.ScriptContext" => pure "V3.ScriptContext"
  | "PlutusLedgerApi.V3.TxInfo" => pure "V3.TxInfo"
  | "PlutusLedgerApi.V3.ScriptInfo" => pure "V3.ScriptInfo"
  | _ => throw s!"unsupported Haskell source type: {name}"

private def validModule (name : String) : Bool :=
  !name.isEmpty && (name.splitOn ".").all fun part =>
    part.toList.head?.any Char.isUpper &&
    part.toList.all (fun c => c.isAlphanum || c == '_' || c == '\'')

private def validTypeName (name : String) : Bool :=
  name.toList.head?.any Char.isUpper &&
  name.toList.all (fun c => c.isAlphanum || c == '_' || c == '\'')

/-- Render only ground, importable Haskell types from the blueprint-bound
Plinth manifest. Reject syntax that could inject declarations into source. -/
private partial def declaredType (j : Json) : Except String (String × Array String) := do
  let moduleName ← str j "module"
  let name ← str j "name"
  let arguments ← arr j "arguments"
  let rendered ← arguments.mapM declaredType
  let modules := rendered.foldl (fun acc (_, xs) => acc ++ xs) #[]
  if name == "[]" && rendered.size == 1 then
    return ("[" ++ rendered[0]!.1 ++ "]", modules)
  if name == "(,)" && rendered.size == 2 then
    return ("(" ++ rendered[0]!.1 ++ ", " ++ rendered[1]!.1 ++ ")", modules)
  if name == "()" && rendered.isEmpty then return ("()", modules)
  unless validModule moduleName && validTypeName name do
    throw "source type is not an importable Haskell type constructor"
  let base := moduleName ++ "." ++ name
  let ty := if rendered.isEmpty then base else
    "(" ++ base ++ " " ++ String.intercalate " " (rendered.toList.map (·.1)) ++ ")"
  return (ty, modules.push moduleName)

private def declaredRole (manifest property : Json) (role : String) : Except String (Option (String × Array String)) := do
  let scope ← get property "scope"
  let validators ← arr scope "validators"
  let [validator] := validators.toList | return none
  let id ← validator.getStr?
  let entries := (← arr manifest "validators").filter (fun v => optText v "id" == some id)
  let [entry] := entries.toList | return none
  let roleValue ← get entry role
  if roleValue == .null then return none
  let descriptor ← get roleValue "type"
  if (← str descriptor "name") == "BuiltinData" then return none
  return some (← declaredType descriptor)

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
    return ⟨"(decodeData (" ++ (← plutusData (← get j "value")) ++ "))", .atom ty⟩
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

private def identifier (raw fallback : String) (used : Array String) : String := Id.run do
  let keywords := ["case", "class", "data", "default", "deriving", "do", "else", "foreign", "if", "import",
    "in", "infix", "infixl", "infixr", "instance", "let", "module", "newtype", "of", "then", "type", "where",
    "main", "inputs", "property", "_", "qualified", "as", "hiding", "forall", "family", "pattern"]
  let valid := raw.toList.head?.any (fun c => 'a' ≤ c && c ≤ 'z' || c == '_') &&
    raw.toList.all (fun c => c.isAlphanum || c == '_' || c == '\'') && !keywords.contains raw
  let base := if valid then raw else fallback
  let mut name := base
  let mut index := 1
  while used.contains name do
    name := s!"{base}_{index}"
    index := index + 1
  return name

/-- Construct source only from a confirmed replay and complete typed values.
Never infer a source type from the wire encoding or a Lean display name. -/
def prepare (result : Json) (sourceTypes : Option Json := none) (property : Option Json := none)
    (moduleName : String := "Main") : Except String (String × Json) := do
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
  let mut used : Array String := #[]
  let mut encodedBindings : Array (Json × String × String) := #[]
  for i in [:bindings.size] do
    let binding := bindings[i]!
    let typed ← completeValue binding
    needsLedger := needsLedger || usesLedger typed
    needsBytes := needsBytes || usesBytes typed
    let name := identifier (← str binding "name") s!"input{i}" used
    used := used.push name
    let mut sourceTy := Json.null
    let mut dataName := Json.null
    let mut dataExpression := Json.null
    let mut value := ""
    if optText typed "kind" == some "encoded" then
      let ty ← sourceType (← str typed "type")
      let wire ← get typed "value"
      let rawName := identifier (name ++ "Data") s!"input{i}Data" used
      used := used.push rawName
      let raw ← plutusData wire
      dataExpression := toJson raw
      value := s!"decodeData {rawName}"
      declarations := declarations.push s!"{rawName} :: V3.Data\n{rawName} = {raw}\n\n{name} :: {ty}\n{name} = {value}\n"
      encodedBindings := encodedBindings.push (typed, name, rawName)
      sourceTy := toJson ty
      dataName := toJson rawName
    else
      value ← haskell typed
      declarations := declarations.push s!"{name} = {value}\n"
    inputs := inputs.push (obj [("name", toJson (← str binding "name")), ("identifier", toJson name),
      ("leanType", toJson (← str binding "leanType")), ("sourceType", sourceTy),
      ("dataIdentifier", dataName), ("dataExpression", dataExpression), ("expression", toJson value)])
  let mut contexts : Array Json := #[]
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
      let name := identifier (← str binding "name") s!"context{contexts.size}" used
      let dataName := identifier (name ++ "Data") s!"context{contexts.size}Data" (used.push name)
      used := used.push name |>.push dataName
      let mut dataExpression ← plutusData wire
      let mut expression := s!"decodeData {dataName}"
      for (saved, sourceName, sourceDataName) in encodedBindings do
        if saved == value then
          dataExpression := sourceDataName
          expression := sourceName
          break
      declarations := declarations.push s!"{dataName} :: V3.Data\n{dataName} = {dataExpression}\n\n{name} :: {ty}\n{name} = {expression}\n"
      contexts := contexts.push (obj [("identifier", toJson name), ("sourceType", toJson (← str value "type")),
        ("haskellType", toJson ty),
        ("name", toJson (← str binding "name")), ("expression", toJson expression),
        ("dataIdentifier", toJson dataName), ("dataExpression", toJson dataExpression),
        ("wireData", wire),
        ("callIndex", toJson callIndex), ("target", toJson (← str call "target")),
        ("argumentIndices", toJson argumentIndices), ("wireArgumentEncoding", toJson "tocex-json-v1"),
        ("wireArgumentSha256", toJson (hashBytes wire.compress.toUTF8))])
  let mut sourceImports : Array String := #[]
  let mut sourceDisplays : Array String := #[]
  let mut decodedRoles : Array Json := #[]
  if let (some manifest, some prop) := (sourceTypes, property) then
    let validatorIds ← arr (← get prop "scope") "validators"
    if let [validator] := validatorIds.toList then
      let validatorId ← validator.getStr?
      if let some ctx := contexts.toList.find? (fun c =>
          optText c "haskellType" == some "V3.ScriptContext" &&
          (optText c "target").any (·.endsWith ("." ++ validatorId))) then
        let ctxName ← str ctx "identifier"
        for role in ["redeemer", "datum"] do
          if let some (ty, imports) ← declaredRole manifest prop role then
            sourceImports := sourceImports ++ imports
            let roleName := if role == "redeemer" then "Redeemer" else "Datum"
            let dataName := identifier ("source" ++ roleName ++ "Data") s!"sourceData{decodedRoles.size}" used
            used := used.push dataName
            let valueName := identifier ("source" ++ roleName) s!"sourceValue{decodedRoles.size}" used
            used := used.push valueName
            if role == "redeemer" then
              declarations := declarations.push s!"{dataName} :: V3.Data\n{dataName} = case V3.scriptContextRedeemer {ctxName} of\n  V3.Redeemer raw -> V3.builtinDataToData raw\n\n{valueName} :: {ty}\n{valueName} = decodeData {dataName}\n"
            else
              declarations := declarations.push s!"{dataName} :: P.Maybe V3.Data\n{dataName} = case V3.scriptContextScriptInfo {ctxName} of\n  V3.SpendingScript _ (P.Just (V3.Datum raw)) -> P.Just (V3.builtinDataToData raw)\n  _ -> P.Nothing\n\n{valueName} :: P.Maybe {ty}\n{valueName} = P.fmap decodeData {dataName}\n"
            sourceDisplays := sourceDisplays.push s!"    P.putStrLn ({quote (role ++ " = ")} P.++ P.show {valueName})\n"
            decodedRoles := decodedRoles.push (obj [("role", toJson role), ("haskellType", toJson ty),
              ("identifier", toJson valueName), ("dataIdentifier", toJson dataName)])
  let body := String.intercalate "\n" declarations.toList
  let imports := "import Prelude\nimport qualified Prelude as P\n" ++
    (if needsBytes then "import qualified Data.ByteString as BS\n" else "") ++
    (if needsLedger then "import qualified PlutusLedgerApi.V1 as V1\n" ++
      "import qualified PlutusLedgerApi.V2 as V2\n" ++
      "import qualified PlutusLedgerApi.V3 as V3\n" else "") ++
    String.join ((sourceImports.toList.eraseDups).map (fun name => "import qualified " ++ name ++ "\n"))
  let decoder := if needsLedger then
    "-- Attempt to decode the exact replayed argument using Plinth's FromData instance.\n" ++
    "-- The Lean ledger model can contain raw Data fields that Haskell rejects.\n" ++
    "decodeData :: (V3.FromData a, V3.ToData a) => V3.Data -> a\n" ++
    "decodeData wire = case V3.fromData wire of\n" ++
    "  Just value | V3.toData value == wire -> value\n" ++
    "  Just _ -> P.error \"Haskell value does not round-trip to the replayed Data\"\n" ++
    "  Nothing -> P.error \"Haskell FromData rejected the replayed Data\"\n\n"
    else ""
  let inputStrings := inputs.toList.map fun input =>
    "(" ++ quote ((str input "name").toOption.get!) ++ ", " ++ quote ((str input "expression").toOption.get!) ++ ")"
  let display := contexts.toList.map fun ctx => "    P.print " ++ (str ctx "identifier").toOption.get! ++ "\n"
  let main := if contexts.isEmpty then "main = P.mapM_ P.print inputs\n" else
    "main = do\n" ++ String.join display ++ String.join sourceDisplays.toList ++ "    P.mapM_ P.print inputs\n"
  let source := "-- Source values for a confirmed UPLC counterexample.\n-- Exact wire arguments and replay evidence are in verifier-report.json.\nmodule " ++ moduleName ++ " where\n" ++ imports ++
    "\n" ++ decoder ++ "property :: String\nproperty = " ++ quote (← str result "property") ++ "\n\n" ++ body ++
    "\ninputs :: [(String, String)]\ninputs = [" ++ String.intercalate ", " inputStrings ++ "]\n\nmain :: IO ()\n" ++ main
  return (source, obj [("status", toJson "exported"), ("language", toJson "haskell"),
    ("compilation", toJson "not-run"), ("inputs", .arr inputs), ("contexts", .arr contexts),
    ("decodedRoles", .arr decodedRoles)])

/-- Source export failure remains distinct from the SMT verdict and CEK replay. -/
def exportSources (run : FilePath) (results : Array Json) (sourceTypes : Option Json := none)
    (properties : Array Json := #[]) : IO (Array Json) := do
  results.mapIdxM fun i result => do
    if optText result "outcome" != some "falsified" then return result
    let prop := properties.find? (fun p => optText p "id" == optText result "property")
    let moduleName := if sourceTypes.isSome then s!"Counterexample{i}" else "Main"
    let info ← match prepare result sourceTypes prop moduleName with
      | .error reason => pure <| obj [("status", toJson "unavailable"), ("language", toJson "haskell"), ("reason", toJson reason)]
      | .ok (source, info) => do
        -- Property identifiers never become paths. Source binder names are
        -- preserved when valid and disambiguated before becoming identifiers.
        IO.FS.createDirAll (run / "counterexamples")
        let relative := s!"counterexamples/Counterexample{i}.hs"
        IO.FS.writeFile (run / relative) source
        pure <| put info "file" (digestRef relative (← hashFile (run / relative)))
    return put result "counterexample" (put (result.getObjValD "counterexample") "source" info)

end CardanoBlaster.Counterexample
