import CardanoBlaster.Json

namespace CardanoBlaster.SourceValue
open Lean

private def registry : Json := (Json.parse (include_str "../data/ledger-source-types.json")).toOption.get!
private def descriptors : Array (String × Json) :=
  ((registry.getObjValAs? (Array (String × Json)) "types").toOption.getD #[])

private def get (j : Json) (key : String) := j.getObjVal? key
private def str (j : Json) (key : String) := j.getObjValAs? String key
private def arr (j : Json) (key : String) := j.getObjValAs? (Array Json) key

private def dataFields (j : Json) (ctor : String) (names : Array String) : Except String (Array Json) := do
  unless (← str j "kind") == "constructor" && (← str j "type") == "PlutusCore.Data" &&
      (← str j "constructor") == ctor do throw s!"expected Data.{ctor}"
  let fs ← arr j "fields"
  unless (← fs.mapM (str · "name")) == names do throw "unexpected Data fields"
  fs.mapM (get · "value")

private def dataList (j : Json) : Except String (Array Json) := do
  unless (← str j "kind") == "list" do throw "expected a portable list"
  arr j "values"

private def aliasFor (mod : String) : String :=
  if mod == "PlutusLedgerApi.V3.Contexts" then "V3"
  else if mod.endsWith ".Tx" then "Tx" ++ ((mod.splitOn ".").reverse[1]?.getD "")
  else (mod.splitOn ".").getLast!

private def qualified (mod name : String) : String :=
  if mod.startsWith "GHC." || mod == "Prelude" then name else aliasFor mod ++ "." ++ name

private def commaSep (xs : Array Format) : Format := Format.joinSep xs.toList ("," ++ Format.line)

private def brackets (xs : Array Format) : Format :=
  if xs.isEmpty then "[]" else Format.group ("[" ++ Format.nest 2 (commaSep xs) ++ "]")

private def record (ctor : String) (names : Array String) (xs : Array Format) : Format :=
  if xs.isEmpty then .text ctor
  else if names.all (!·.isEmpty) then
    let fs := (names.zip xs).map fun (n,x) =>
      Format.group (.text n ++ " =" ++ Format.nest 2 (Format.line ++ x))
    Format.group (.text ctor ++ " {" ++ Format.nest 2 (Format.line ++ commaSep fs) ++ Format.line ++ "}")
  else Format.group ("(" ++ .text ctor ++ Format.nest 2 (Format.line ++ Format.joinSep xs.toList Format.line) ++ ")")

/-- This is a source rendering, not an attempt to infer a type from a Data tag.
The graph was reflected from actual Haskell types and their ToData instances. -/
private partial def decode (renderData renderBytes : Json → Except String String)
    (ty : String) (wire : Json) : Except String Format := do
  let some (_, descriptor) := descriptors.find? (·.1 == ty) | throw s!"no Haskell source descriptor for {ty}"
  match ← str descriptor "kind" with
  | "integer" =>
    let v := (← dataFields wire "I" #["value"])[0]!
    let raw ← str v "value"
    let some n := raw.toInt? | throw "invalid source integer"
    unless toString n == raw do throw "noncanonical source integer"
    return .text (if n < 0 then "(" ++ raw ++ ")" else raw)
  | "bytes" =>
    let v := (← dataFields wire "B" #["value"])[0]!
    discard <| renderBytes v
    return .text s!"(Builtins.stringToBuiltinByteStringHex \"{← str v "hex"}\")"
  | "data" => return .text s!"(V3.dataToBuiltinData ({← renderData wire}))"
  | "list" =>
    let types ← descriptor.getObjValAs? (Array String) "args"
    let xs ← dataList (← dataFields wire "List" #["values"])[0]!
    return brackets (← xs.mapM (decode renderData renderBytes types[0]!))
  | "map" =>
    let types ← descriptor.getObjValAs? (Array String) "args"
    let xs ← dataList (← dataFields wire "Map" #["entries"])[0]!
    let entries ← xs.mapM fun pair => do
      unless (← str pair "type") == "Prod" && (← str pair "constructor") == "Prod.mk" do throw "invalid map pair"
      let fs ← arr pair "fields"
      unless (← fs.mapM (str · "name")) == #["fst", "snd"] do throw "invalid map fields"
      let a ← decode renderData renderBytes types[0]! (← get fs[0]! "value")
      let b ← decode renderData renderBytes types[1]! (← get fs[1]! "value")
      return Format.group ("(" ++ a ++ "," ++ Format.line ++ b ++ ")")
    return Format.group ("(AssocMap.unsafeFromList" ++ Format.nest 2 (Format.line ++ brackets entries) ++ ")")
  | "ratio" =>
    let layout ← get descriptor "layout"
    let parts ← dataFields wire "Constr" #["index", "fields"]
    unless (← str parts[0]! "value") == toString (← layout.getObjValAs? Int "index") do
      throw "invalid Rational constructor index"
    let xs ← dataList parts[1]!
    unless xs.size == 2 do throw "invalid Rational encoding"
    let numerator ← str (← dataFields xs[0]! "I" #["value"])[0]! "value"
    let denominator ← str (← dataFields xs[1]! "I" #["value"])[0]! "value"
    let some n := numerator.toInt? | throw "invalid Rational numerator"
    let some d := denominator.toInt? | throw "invalid Rational denominator"
    unless d > 0 && Nat.gcd n.natAbs d.natAbs == 1 do
      throw "Rational would normalize and change the replayed Data"
    let integerType := "GHC.Num.Integer.Integer"
    return Format.group ("(Ratio.unsafeRatio" ++ Format.nest 2 (Format.line ++
      (← decode renderData renderBytes integerType xs[0]!) ++ Format.line ++
      (← decode renderData renderBytes integerType xs[1]!)) ++ ")")
  | "variants" =>
    for ctor in (← arr descriptor "constructors") do
      let fs ← ctor.getObjValAs? (Array (String × String)) "fields"
      let layout ← get ctor "layout"
      let values ← match ← str layout "kind" with
        | "transparent" => pure #[wire]
        | "constructor" => do
          let parts ← dataFields wire "Constr" #["index", "fields"]
          if (← str parts[0]! "value") != toString (← layout.getObjValAs? Int "index") then continue
          dataList parts[1]!
        | "tuple-list" => dataList (← dataFields wire "List" #["values"])[0]!
        | _ => throw "unsupported source layout"
      unless fs.size == values.size do throw s!"wrong number of fields for {ty}"
      let values ← (fs.zip values).mapM fun ((_, t), v) => decode renderData renderBytes t v
      return record (qualified (← str ctor "module") (← str ctor "name")) (fs.map (·.1)) values
    throw s!"unknown constructor index for {ty}"
  | _ => throw "unsupported source descriptor"

def imports : String :=
  let modules := descriptors.foldl (init := #[]) fun acc (_, d) =>
    ((d.getObjValAs? (Array Json) "constructors").toOption.getD #[]).foldl (init := acc) fun acc c =>
      let m := (str c "module").toOption.getD ""
      if m.isEmpty || m.startsWith "GHC." || m == "PlutusLedgerApi.V3.Contexts" || acc.contains m then acc else acc.push m
  String.join (modules.toList.map fun m => s!"import qualified {m} as {aliasFor m}\n") ++
    "import qualified PlutusTx.AssocMap as AssocMap\nimport qualified PlutusTx.Ratio as Ratio\n" ++
    "import qualified PlutusTx.Builtins.HasOpaque as Builtins\n"

def render (renderData renderBytes : Json → Except String String) (ty : String) (wire : Json) : Except String String := do
  discard <| renderData wire
  let ty := ty.replace "PlutusLedgerApi.V3.ScriptContext" "PlutusLedgerApi.V3.Contexts.ScriptContext"
    |>.replace "PlutusLedgerApi.V3.TxInfo" "PlutusLedgerApi.V3.Contexts.TxInfo"
    |>.replace "PlutusLedgerApi.V3.ScriptInfo" "PlutusLedgerApi.V3.Contexts.ScriptInfo"
  return (← decode renderData renderBytes ty wire).pretty 100

/-- Type annotations used by the cross-language codec regression. -/
def typeName (ty : String) : String := Id.run do
  let mut result := ty
  for (_, d) in descriptors do
    for c in (d.getObjValAs? (Array Json) "constructors").toOption.getD #[] do
      let m := (str c "module").toOption.getD ""
      if m.startsWith "PlutusLedgerApi." then result := result.replace (m ++ ".") (aliasFor m ++ ".")
  return result.replace "GHC.Maybe.Maybe" "Maybe" |>.replace "GHC.Types.Bool" "Bool"
    |>.replace "PlutusLedgerApi.V3." "V3."
    |>.replace "GHC.Num.Integer.Integer" "Integer"
    |>.replace "PlutusTx.Builtins.Internal.BuiltinByteString" "V3.BuiltinByteString"
    |>.replace "PlutusTx.Builtins.Internal.BuiltinData" "V3.BuiltinData"
    |>.replace "PlutusTx.AssocMap.Map" "AssocMap.Map"
    |>.replace "PlutusTx.Ratio.Rational" "Ratio.Rational"

end CardanoBlaster.SourceValue
