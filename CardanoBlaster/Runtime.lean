import CardanoBlaster.Options
import Std.Internal.Async.System

namespace CardanoBlaster.Runtime
open Lean System

def version := "0.2.1"
-- Rebuild this module whenever the pinned runtime lock changes: the lock is
-- embedded in the native executable and checked against the on-disk file.
def lockSource : String := include_str "../runtime-lock.json"
def lock : Json := (Json.parse lockSource).toOption.get!

private partial def findRoot (path : FilePath) : IO FilePath := do
  if ← (path / "runtime-lock.json").pathExists then return path
  let some parent := path.parent | throw <| IO.userError "cannot find the cardano-blaster runtime"
  if parent == path then throw <| IO.userError "cannot find the cardano-blaster runtime"
  findRoot parent

def root : IO FilePath := do
  if let some path ← IO.getEnv "CARDANO_BLASTER_HOME" then return ← IO.FS.realPath path
  findRoot ((← IO.appPath).parent.getD ".")

def bundled (home : FilePath) : BaseIO Bool := (home / "lib/lean/Init.olean").pathExists

private def validateInventory (home : FilePath) : IO Unit := do
  let inventory := home / "runtime-files.sha256"
  unless ← inventory.pathExists do throw <| IO.userError "native bundle inventory is missing"
  for (cmd, args) in [("sha256sum", #["--status", "-c", inventory.toString]),
                      ("shasum", #["-a", "256", "-c", inventory.toString])] do
    let available? ← try pure (some (← IO.Process.output { cmd := "which", args := #[cmd] })) catch _ => pure none
    unless available?.any (·.exitCode == 0) do continue
    let result? ← try pure (some (← IO.Process.output { cmd, args, cwd := home })) catch _ => pure none
    if let some result := result? then
      unless result.exitCode == 0 do throw <| IO.userError "native bundle integrity check failed"
      return
  for line in (← IO.FS.readFile inventory).splitOn "\n" do
    unless line.isEmpty do
      let [expected, relative] := line.splitOn "  " | throw <| IO.userError "invalid bundle inventory"
      if relative.startsWith "/" || (relative.splitOn "/").contains ".." then
        throw <| IO.userError "invalid bundle inventory path"
      unless hashBytes (← IO.FS.readBinFile (home / relative)) == expected do
        throw <| IO.userError "native bundle integrity check failed"

def validate (home : FilePath) : IO Json := do
  unless (← IO.FS.readFile (home / "runtime-lock.json")) == lockSource do
    throw <| IO.userError "runtime lock differs from the lock compiled into this executable"
  let packages ← array (← field lock "packages")
  if ← bundled home then
    validateInventory home
  else
    let manifest ← readJson (home / "lake-manifest.json")
    let entries ← array (← field manifest "packages")
    unless entries.size == packages.size do throw <| IO.userError "unexpected Lake dependencies"
    for pin in packages do
      let name ← text pin "name"
      let revision ← text pin "rev"
      let some entry := entries.find? (fun e => optText e "name" == some name)
        | throw <| IO.userError s!"missing pinned dependency: {name}"
      unless optText entry "rev" == some revision && optText entry "url" == optText pin "url" do
        throw <| IO.userError s!"Lake manifest differs from the compiled pin: {name}"
      let checkout := home / ".lake/packages" / name
      let head ← IO.Process.run { cmd := "git", args := #["rev-parse", "HEAD"], cwd := checkout }
      let dirty ← IO.Process.run { cmd := "git", args := #["status", "--porcelain", "--untracked-files=normal"], cwd := checkout }
      unless head.trim == revision && dirty.trim.isEmpty do
        throw <| IO.userError s!"pinned dependency source or revision changed: {name}"
  return obj [("pinned", toJson true), ("lock", lock), ("packages", .arr packages),
    ("distribution", toJson (if ← bundled home then "native-bundle" else "source-build")),
    ("leanVersion", toJson Lean.versionString)]

def searchPaths (home : FilePath) : IO (List FilePath) := do
  if ← bundled home then return [home / "lib/lean"]
  let sysroot ← Lean.findSysroot
  return [home / ".lake/build/lib/lean", home / ".lake/packages/Blaster/.lake/build/lib/lean",
    home / ".lake/packages/PlutusCore/.lake/build/lib/lean",
    home / ".lake/packages/CardanoLedgerApi/.lake/build/lib/lean", sysroot / "lib/lean"]

def initializeSearch (home : FilePath) : IO Unit := do
  Lean.searchPathRef.set (← searchPaths home)
  -- The native executable contains the checker and interpreter symbols. The
  -- executable digest in captureCheckingEnvironment binds that native code.
  Std.Internal.IO.Async.System.unsetEnvVar "ASSURANCE_NATIVE_LIBRARY"

def solver (home : FilePath) (overridePath : Option FilePath) : IO FilePath := do
  if let some path := overridePath then return ← IO.FS.realPath path
  for path in [home / "bin/z3", home / ".lake/z3/bin/z3"] do
    if ← path.pathExists then return ← IO.FS.realPath path
  throw <| IO.userError "pinned Z3 is not installed; run 'cardano-blaster setup' or provide --z3"

def solverInfo (path : FilePath) (overrideSolver : Bool) : IO Json := do
  let version ← IO.Process.run { cmd := path.toString, args := #["--version"] }
  unless overrideSolver || version.startsWith "Z3 version 5.3.1 " do
    throw <| IO.userError "expected the locked Z3 5.3.1 release"
  return obj [("path", toJson path.toString), ("sha256", toJson (← hashFile path)),
    ("version", toJson version.trim), ("override", toJson overrideSolver)]

def installSolver (home : FilePath) : IO FilePath := do
  if ← (home / "bin/z3").pathExists then return home / "bin/z3"
  let destination := home / ".lake/z3/bin/z3"
  if ← destination.pathExists then
    discard <| solverInfo destination false
    return destination
  let os := (← IO.Process.run { cmd := "uname", args := #["-s"] }).trim
  let machine := (← IO.Process.run { cmd := "uname", args := #["-m"] }).trim
  let key := os ++ "-" ++ machine
  let assets ← field (← field lock "z3") "assets"
  let asset ← field assets key
  IO.FS.withTempDir fun temporary => do
    let archive := temporary / "z3.zip"
    let url ← text asset "url"
    discard <| IO.Process.run { cmd := "curl", args := #["-fLsS", "--connect-timeout", "15", "--max-time", "120", "-o", archive.toString, url] }
    unless (← hashFile archive) == (← text asset "sha256") do
      throw <| IO.userError "downloaded Z3 archive does not match its pinned SHA-256"
    discard <| IO.Process.run { cmd := "unzip", args := #["-q", archive.toString, "*/bin/z3", "-d", temporary.toString] }
    let executables := (← temporary.walkDir).filter (·.fileName == some "z3")
    unless executables.size == 1 do throw <| IO.userError "unexpected Z3 archive layout"
    IO.FS.createDirAll (home / ".lake/z3/bin")
    IO.FS.writeBinFile destination (← IO.FS.readBinFile executables[0]!)
    discard <| IO.Process.run { cmd := "chmod", args := #["755", destination.toString] }
    discard <| solverInfo destination false
    writeJson (home / ".lake/z3/receipt.json") (obj [("archive", asset), ("binarySha256", toJson (← hashFile destination))])
  return destination

end CardanoBlaster.Runtime
