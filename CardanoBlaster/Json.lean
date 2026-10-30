import Lean.Data.Json
import PlutusCore.UPLC.BlueprintEncoding.Assurance

namespace CardanoBlaster
open Lean System

abbrev Inputs := Array (String × String)

def field (j : Json) (key : String) : IO Json := IO.ofExcept (j.getObjVal? key)
def string (j : Json) : IO String := IO.ofExcept j.getStr?
def array (j : Json) : IO (Array Json) := IO.ofExcept j.getArr?
def text (j : Json) (key : String) : IO String := do string (← field j key)
def optText (j : Json) (key : String) : Option String := (j.getObjValAs? String key).toOption
def put (j : Json) (key : String) (value : Json) : Json := j.setObjVal! key value
def obj := Json.mkObj
def hashFile := PlutusCore.UPLC.BlueprintEncoding.Assurance.Internal.sha256File
def hashBytes := PlutusCore.UPLC.BlueprintEncoding.Assurance.Internal.sha256Hex

/-- Hash the bytes actually read, rather than reopening a possibly changed input.
Use a private snapshot so the native SHA utility also handles large artifacts. -/
def digestBytes (bytes : ByteArray) : IO String :=
  IO.FS.withTempFile fun handle path => do
    handle.write bytes
    handle.flush
    hashFile path

private partial def quoted (chars : List Char) (acc : List Char := ['"']) : Except String (String × List Char) := do
  match chars with
  | [] => throw "unterminated JSON string"
  | '\\' :: c :: rest => quoted rest (c :: '\\' :: acc)
  | '"' :: rest => return (String.mk ('"' :: acc).reverse, rest)
  | c :: rest => quoted rest (c :: acc)

-- Lean's JSON parser accepts repeated object keys. Audit the validated token
-- stream too, comparing decoded keys so escapes cannot hide a duplicate.
private partial def uniqueKeys (chars : List Char) (stack : List (Option (List String)) := []) : Except String Unit := do
  match chars with
  | [] => pure ()
  | '{' :: rest => uniqueKeys rest (some [] :: stack)
  | '[' :: rest => uniqueKeys rest (none :: stack)
  | '}' :: rest | ']' :: rest => uniqueKeys rest stack.tail
  | '"' :: rest =>
    let (token, rest) ← quoted rest
    let mut stack := stack
    if (rest.dropWhile Char.isWhitespace).head? == some ':' then
      if let some keys :: frames := stack then
        let key ← (← Json.parse token).getStr?
        if keys.contains key then throw s!"duplicate JSON key: {key}"
        stack := some (key :: keys) :: frames
    uniqueKeys rest stack
  | _ :: rest => uniqueKeys rest stack

def parseJson (content : String) : IO Json := do
  let value ← IO.ofExcept (Json.parse content)
  IO.ofExcept (uniqueKeys content.toList)
  return value

def readJson (path : FilePath) : IO Json := do parseJson (← IO.FS.readFile path)
def writeJson (path : FilePath) (j : Json) : IO Unit := IO.FS.writeFile path (j.pretty ++ "\n")
def digestRef (uri digest : String) : Json :=
  obj [("uri", toJson uri), ("hash", obj [("alg", toJson "sha256"), ("digest", toJson digest)])]

def localPath (parent : FilePath) (uri : String) : IO FilePath := do
  if (uri.splitOn "://").length > 1 then throw <| IO.userError "a local artifact path is required"
  IO.FS.realPath (parent / uri)

def checkedBytes (parent : FilePath) (ref : Json) : StateT Inputs IO (FilePath × ByteArray) := do
  let path ← localPath parent (← text ref "uri")
  let bytes ← IO.FS.readBinFile path
  let actual ← digestBytes bytes
  let hash ← field ref "hash"
  unless ["sha256", "sha-256"].contains (← text hash "alg").toLower &&
      (← text hash "digest") == actual do
    throw <| IO.userError s!"artifact digest mismatch: {path}"
  modify (·.push (path.toString, actual))
  return (path, bytes)

def checkedJson (parent : FilePath) (ref : Json) : StateT Inputs IO (FilePath × Json) := do
  let (path, bytes) ← checkedBytes parent ref
  let some source := String.fromUTF8? bytes | throw <| IO.userError "artifact is not UTF-8 JSON"
  return (path, ← parseJson source)

partial def absoluteUris (value : Json) (parent : FilePath) : IO Json := do
  match value with
  | .arr values => return .arr (← values.mapM (absoluteUris · parent))
  | .obj fields =>
    return obj (← fields.toList.mapM fun (k, v) => do
      if k == "uri" then
        if let .str uri := v then
          if (uri.splitOn "://").length == 1 then
            return (k, toJson (parent / uri).normalize.toString)
      return (k, ← absoluteUris v parent))
  | _ => return value

partial def snapshotAssets (value : Json) (parent run : FilePath) : StateT Inputs IO Json := do
  match value with
  | .arr values => return .arr (← values.mapM (snapshotAssets · parent run))
  | .obj fields =>
    if (value.getObjVal? "uri").isOk && (value.getObjVal? "hash").isOk then
      let (_, bytes) ← checkedBytes parent value
      let digest ← text (← field value "hash") "digest"
      IO.FS.createDirAll (run / "artifacts")
      IO.FS.writeBinFile (run / "artifacts" / digest) bytes
      return put value "uri" (toJson s!"artifacts/{digest}")
    return obj (← fields.toList.mapM fun (k, v) => do return (k, ← snapshotAssets v parent run))
  | _ => return value

def terminalText (s : String) : String := String.mk <| s.toList.map fun c =>
  if c.toNat < 32 || c.toNat == 127 then ' ' else c

end CardanoBlaster
