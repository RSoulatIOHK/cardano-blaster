import CardanoBlaster.Runtime
import Lean.Elab.Frontend
import CardanoLedgerApi.Counterexample.V3

namespace CardanoBlaster
open Lean System

-- This runs in a copy of the native executable, isolating elaboration and
-- allowing the CLI to enforce a wall-clock deadline around the whole check.
unsafe def frontend (home driver : FilePath) : IO UInt32 := do
  Runtime.initializeSearch home
  let result ← Lean.Elab.runFrontend (← IO.FS.readFile driver) {} driver.toString `CardanoBlasterInput
  return if result.isSome then 0 else 1

private def descendants (pid : UInt32) : IO (Array String) := do
  let output ← IO.Process.run { cmd := "ps", args := #["-axo", "pid=,ppid="] }
  let rows := output.splitOn "\n" |>.filterMap fun row =>
    match (row.splitOn " ").filter (!·.isEmpty) with
    | [child, parent] => some (child, parent)
    | _ => none
  let mut found := #[toString pid]
  for _ in [:rows.length] do
    let next := rows.filterMap fun (child, parent) =>
      if found.contains parent && !found.contains child then some child else none
    if next.isEmpty then break
    found := found ++ next.toArray
  return found

def runWorker (home driver log solver : FilePath) (timeout : Nat) : IO UInt32 := do
  let oldPath := (← IO.getEnv "PATH").getD ""
  let config : IO.Process.SpawnArgs := {
    cmd := (← IO.appPath).toString
    args := #["--internal-frontend", home.toString, driver.toString]
    env := #[("PATH", some (solver.parent.get!.toString ++ ":" ++ oldPath)),
      ("LEAN_PATH", none), ("ASSURANCE_NATIVE_LIBRARY", none)]
    stdout := .piped, stderr := .piped
  }
  let child ← IO.Process.spawn config
  let stdout ← IO.asTask child.stdout.readToEnd .dedicated
  let stderr ← IO.asTask child.stderr.readToEnd .dedicated
  let start ← IO.monoMsNow
  let mut expired := false
  let mut result ← child.tryWait
  while result.isNone do
    if (← IO.monoMsNow) - start > timeout * 1000 then
      -- Workers share the terminal process group, so Ctrl-C also reaches the
      -- solver. Kill the worker's descendants explicitly on a CLI timeout.
      let pids ← descendants child.pid
      discard <| IO.Process.output { cmd := "kill", args := #["-TERM"] ++ pids }
      expired := true
      for _ in [:40] do
        if (← child.tryWait).isSome then break
        IO.sleep 50
      if (← child.tryWait).isNone then
        discard <| IO.Process.output { cmd := "kill", args := #["-KILL"] ++ pids }
      result := some (← child.wait)
      break
    IO.sleep 25
    result ← child.tryWait
  let out ← IO.ofExcept stdout.get
  let err ← IO.ofExcept stderr.get
  IO.FS.writeFile log (out ++ err)
  if expired then throw <| IO.userError s!"verification timed out after {timeout}s"
  return result.get!

end CardanoBlaster
