import CardanoBlaster.Runtime

namespace CardanoBlaster
open Lean System

private partial def copyModules (source target : FilePath) : IO Unit := do
  for entry in (← source.readDir) do
    if entry.fileName == "Tests" || entry.fileName.startsWith "Tests." ||
        entry.fileName.startsWith "CardanoBlasterTests." then continue
    if ← entry.path.isDir then
      copyModules entry.path (target / entry.fileName)
    else if entry.fileName.endsWith ".olean" || entry.fileName.endsWith ".olean.private" ||
        entry.fileName.endsWith ".olean.server" || entry.fileName.endsWith ".ir" then
      IO.FS.createDirAll target
      let destination := target / entry.fileName
      if ← destination.pathExists then
        unless (← hashFile entry.path) == (← hashFile destination) do
          throw <| IO.userError s!"conflicting bundled module: {destination}"
      else IO.FS.writeBinFile destination (← IO.FS.readBinFile entry.path)

private partial def copyArtifacts (source target : FilePath) : IO Unit := do
  IO.FS.createDirAll target
  for entry in (← source.readDir) do
    if entry.fileName.startsWith "." then continue
    if ← entry.path.isDir then copyArtifacts entry.path (target / entry.fileName)
    else IO.FS.writeBinFile (target / entry.fileName) (← IO.FS.readBinFile entry.path)

def buildBundle (destination : FilePath) : IO Unit := do
  let home ← Runtime.root
  discard <| Runtime.validate home
  if ← destination.pathExists then throw <| IO.userError "bundle destination already exists"
  IO.FS.createDirAll (destination / "bin")
  let destination ← IO.FS.realPath destination
  IO.FS.writeFile (destination / "runtime-lock.json") Runtime.lockSource
  IO.FS.writeBinFile (destination / "bin/cardano-blaster") (← IO.FS.readBinFile (← IO.appPath))
  let solver ← Runtime.solver home none
  IO.FS.writeBinFile (destination / "bin/z3") (← IO.FS.readBinFile solver)
  discard <| IO.Process.run { cmd := "chmod", args := #["755", (destination / "bin/cardano-blaster").toString,
    (destination / "bin/z3").toString] }
  for path in (← Runtime.searchPaths home) do
    if ← path.isDir then copyModules path (destination / "lib/lean")
  IO.FS.writeFile (destination / "README.txt")
    "Run bin/cardano-blaster check plutus.json assurance.json.\nThis archive includes the native Lean CLI, its compiled modules and Z3.\nNo Python, Lean installation, Lake, Git or C/C++ compiler is needed to check bundles.\n"
  if ← (home / "LICENSE").pathExists then
    IO.FS.writeFile (destination / "LICENSE") (← IO.FS.readFile (home / "LICENSE"))
  if ← (home / "licenses").isDir then copyArtifacts (home / "licenses") (destination / "licenses")
  let files := (← destination.walkDir).filter fun p => p.fileName != some "runtime-files.sha256"
  let files ← files.filterM fun p => return !(← p.isDir)
  let hashes ← PlutusCore.UPLC.BlueprintEncoding.Assurance.Internal.sha256Files files
  let prefixLength := destination.toString.length + 1
  let inventory := String.join <| (files.zip hashes).toList.map fun (path, hash) =>
    s!"{hash}  {path.toString.drop prefixLength}\n"
  IO.FS.writeFile (destination / "runtime-files.sha256") inventory
  -- Inputs are intentionally outside the runtime inventory: users may edit a
  -- claim to obtain a counterexample without modifying the checking runtime.
  if ← (home / "examples").isDir then copyArtifacts (home / "examples") (destination / "examples")
  IO.println s!"Native bundle ready: {destination}"

end CardanoBlaster
