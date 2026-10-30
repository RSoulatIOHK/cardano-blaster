import CardanoBlaster.Check
import CardanoBlaster.Bundle

namespace CardanoBlaster

unsafe def dispatch (args : List String) : IO UInt32 := do
  try
    match args with
    | ["--version"] => IO.println s!"cardano-blaster {Runtime.version} (Lean {Lean.versionString}, native)"; return (0 : UInt32)
    | ["--help"] | ["-h"] | [] => IO.println usage; return (0 : UInt32)
    | ["--internal-frontend", home, driver] => frontend home driver
    | ["setup"] =>
      let home ← Runtime.root
      discard <| Runtime.validate home
      let solver ← Runtime.installSolver home
      discard <| Runtime.solverInfo solver false
      IO.println s!"Native runtime ready; Z3: {solver}"
      return (0 : UInt32)
    | ["bundle", destination] => buildBundle destination; return (0 : UInt32)
    | "check" :: blueprint :: assurance :: rest =>
      let options ← IO.ofExcept (parseOptions rest { blueprint, assurance })
      runCheck options
    | _ => IO.eprintln usage; return (3 : UInt32)
  catch error =>
    IO.eprintln s!"cardano-blaster: {terminalText error.toString}"
    return (3 : UInt32)

end CardanoBlaster
